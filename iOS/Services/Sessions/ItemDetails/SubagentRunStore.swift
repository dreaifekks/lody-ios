import Foundation
import LodyCore

/// A task's envelope carries its last step; the open page reads full runs, one at a time.
@MainActor
final class SubagentRunStore {
  private(set) var item: [String: Any]
  var changed: (() -> Void)?
  private let sessionId: String
  private let entryId: String
  private let itemId: String
  private let service: ItemDetailService
  private var generation: Int
  private var revision: Int
  private var requestedRevision: Int?
  private var read: (rev: Int, items: [[String: Any]])?
  private var task: Task<Void, Never>?
  private var request: UUID?
  private var again = false
  private var active = false
  private var waiting = false
  private var unobserve: (() -> Void)?

  init(sessionId: String, entryId: String, item: [String: Any], generation: Int, service: ItemDetailService) {
    self.sessionId = sessionId; self.entryId = entryId; self.item = item
    itemId = item["itemId"] as! String
    revision = item["rev"] as? Int ?? 0
    self.generation = generation; self.service = service
  }

  private var complete: Bool {
    guard let run = item["run"] as? [String: Any], let count = run["itemCount"] as? Int else { return true }
    return (run["items"] as? [[String: Any]] ?? []).count >= count
  }

  var displayedItem: [String: Any] {
    guard !complete, var run = item["run"] as? [String: Any], let read else { return item }
    var steps = read.items
    if revision >= read.rev, let last = (run["items"] as? [[String: Any]])?.last {
      if let index = steps.firstIndex(where: { $0["itemId"] as? String == last["itemId"] as? String }) { steps[index] = last }
      else { steps.append(last) }
    }
    run["items"] = steps; run["itemCount"] = nil
    var result = item; result["run"] = run
    return result
  }

  func start() {
    guard !active else { return }
    active = true
    unobserve = service.observe { [weak self] generation, json in self?.receive(generation: generation, json: json) }
    load()
  }

  func finish() {
    active = false
    unobserve?(); unobserve = nil
    task?.cancel(); task = nil; request = nil
    again = false
  }

  func update(_ item: [String: Any], generation incoming: Int) {
    guard incoming == generation, !waiting else { return }
    let next = item["rev"] as? Int ?? 0
    guard next >= revision else { return }
    self.item = item; revision = next
    changed?()
    load()
  }

  private func receive(generation incoming: Int, json: String?) {
    guard active, incoming >= generation else { return }
    if incoming > generation {
      task?.cancel(); task = nil; request = nil
      read = nil; again = false; requestedRevision = nil
      generation = incoming; revision = -1; waiting = true
      changed?()
    }
    guard let json, let envelope = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
      envelope["status"] as? String == "live",
      let entries = envelope["entries"] as? [[String: Any]],
      let items = entries.first(where: { $0["id"] as? String == entryId })?["items"] as? [[String: Any]],
      let item = items.first(where: { $0["itemId"] as? String == itemId }) else { return }
    waiting = false
    update(item, generation: incoming)
  }

  private func load() {
    guard active, !waiting, !complete, requestedRevision != revision else { return }
    if task != nil { again = true; return }
    requestedRevision = revision
    let token = UUID(); request = token
    let params = RuntimeContract.ItemDetailParams(sessionId: sessionId, entryId: entryId, itemId: itemId, run: true)
    let load = service.load
    task = Task { [weak self] in
      let detail = try? await load(params)
      guard let self, active, request == token else { return }
      if let detail, let value = detail.run?.value, case .object = value,
         let run = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any],
         let items = run["items"] as? [[String: Any]], detail.rev >= (read?.rev ?? -1) {
        read = (detail.rev, items)
        changed?()
      }
      task = nil; request = nil
      let repeatRead = again; again = false
      if repeatRead { self.load() }
    }
  }
}
