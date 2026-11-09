import LodyCore
import UIKit

@MainActor
final class SubagentTaskController: UIViewController {
  let entryId: String
  let itemId: String
  private let store: SubagentRunStore
  private var item: [String: Any] { store.displayedItem }
  private let runMeta = UILabel()
  private let incomplete = UILabel()
  private let runHeader = UIStackView()
  private let chat = LodyChatView(frame: .zero)
  private lazy var copyItem: UIBarButtonItem = {
    let copy = UIBarButtonItem(image: UIImage(systemName: "doc.on.doc"), primaryAction: UIAction { [weak self] _ in self?.copyResult() })
    copy.accessibilityIdentifier = "subagent-detail-copy"
    copy.accessibilityLabel = String(localized: "subagent.detail.copy", bundle: .lody)
    return copy
  }()
  var onActivity: ((String, String) -> Void)?
  var onFile: ((String, Int) -> Void)?
  var onLink: ((String) -> Void)?

  init(sessionId: String, entryId: String, item: [String: Any], generation: Int, service: ItemDetailService) {
    self.entryId = entryId; itemId = item["itemId"] as! String
    store = SubagentRunStore(sessionId: sessionId, entryId: entryId, item: item, generation: generation, service: service)
    super.init(nibName: nil, bundle: nil)
    chat.setProcessEntryID(entryId); chat.setProcessStartID("__subagent__"); chat.setComposerState("{}")
    chat.setEmptyText(String(localized: "process.empty", bundle: .lody))
    chat.onActivityPress = { [weak self] body in
      guard let entry = body["entryId"] as? String, let item = body["itemId"] as? String else { return }
      self?.onActivity?(entry, item)
    }
    chat.onLinkPress = { [weak self] href in self?.onLink?(href) }
    chat.onFilePress = { [weak self] body in
      guard let path = body["path"] as? String else { return }
      self?.onFile?(path, body["line"] as? Int ?? 0)
    }
  }
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  isolated deinit { store.finish() }

  var pageTitle: String {
    (item["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? actor
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    runHeader.axis = .vertical; runHeader.spacing = 4
    for label in [runMeta, incomplete] {
      label.font = .preferredFont(forTextStyle: .footnote)
      label.textColor = .secondaryLabel; label.numberOfLines = 0
      label.adjustsFontForContentSizeCategory = true
      runHeader.addArrangedSubview(label)
    }
    runMeta.accessibilityIdentifier = "subagent-run-meta"
    incomplete.accessibilityIdentifier = "subagent-run-incomplete"
    incomplete.text = String(localized: "subagent.run.incomplete", bundle: .lody)
    for child in [runHeader, chat] as [UIView] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
    NSLayoutConstraint.activate([
      runHeader.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      runHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      runHeader.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      chat.topAnchor.constraint(equalTo: runHeader.bottomAnchor), chat.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      chat.leadingAnchor.constraint(equalTo: view.leadingAnchor), chat.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    store.changed = { [weak self] in self?.render() }
    store.start()
    render()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    applyHeader()
  }

  func update(_ json: String, generation: Int) {
    if let next = SessionController.item(in: json, entryId: entryId, itemId: itemId) { store.update(next, generation: generation) }
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if SettingsPage.leaving(self) { store.finish() }
  }

  func runItem(_ id: String) -> [String: Any]? {
    ((item["run"] as? [String: Any])?["items"] as? [[String: Any]])?.first { $0["itemId"] as? String == id }
  }

  private var actor: String {
    (item["actor"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "native.chat.transcript.subtask", bundle: .lody)
  }

  private var status: String {
    if let run = item["run"] as? [String: Any] { return ChatSubagentCard.runStatuses[run["state"] as? String ?? ""] ?? "unknown" }
    return item["status"] as? String ?? "pending"
  }

  private var result: String {
    (item[status == "failed" ? "error" : "summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var caption: String {
    let key = ["pending": "pending", "in_progress": "running", "completed": "completed", "failed": "failed", "cancelled": "cancelled", "unknown": "unknown"][status]
    var labels = [actor]
    if let key { labels.append(String(localized: String.LocalizationValue("native.chat.subagent." + key), bundle: .lody)) }
    if item["isBackgrounded"] as? Bool == true { labels.append(String(localized: "native.chat.subagent.background", bundle: .lody)) }
    if item["run"] == nil, let tool = item["lastToolName"] as? String, !tool.isEmpty {
      labels.append(String.localizedStringWithFormat(String(localized: "subagent.detail.lastToolInline", bundle: .lody), tool))
    }
    return labels.joined(separator: " · ")
  }

  private func applyHeader() {
    let host = parent ?? self
    let header = LodyNavigationHeader.of(host.navigationItem)
    header.title = pageTitle
    host.navigationItem.subtitle = caption
    let items = result.isEmpty ? [] : [copyItem]
    if header.rightItems != items { header.rightItems = items }
  }

  private func copyResult() {
    UIPasteboard.general.string = result
    LodyToastOverlay.shared.show(
      message: String(localized: "subagent.detail.copied", bundle: .lody), kind: "info",
      below: navigationController?.navigationBar
    )
  }

  private func render() {
    guard isViewLoaded else { return }
    let run = item["run"] as? [String: Any]
    var metadata: [String] = []
    if let model = run?["modelId"] as? String { metadata.append(model) }
    if let tokens = run?["totalTokens"] as? Double {
      let value = tokens >= 1000 ? String(format: "%.1fk", tokens / 1000) : String(format: "%g", tokens)
      metadata.append(String.localizedStringWithFormat(String(localized: "subagent.run.tokens", bundle: .lody), value))
    }
    if let tools = run?["toolCallCount"] as? Int {
      metadata.append(String.localizedStringWithFormat(String(localized: "subagent.run.tools", bundle: .lody), tools))
    }
    if let percent = run?["contextUsagePercent"] as? Double {
      metadata.append(String.localizedStringWithFormat(String(localized: "subagent.run.context", bundle: .lody), String(format: "%g", percent)))
    }
    runMeta.text = metadata.joined(separator: " · "); runMeta.isHidden = metadata.isEmpty
    incomplete.isHidden = run?["outputIncomplete"] as? Bool != true
    var items: [[String: Any]]
    var state: String
    if let run = item["run"] as? [String: Any] {
      items = run["items"] as? [[String: Any]] ?? []
      state = run["state"] as? String ?? ""
    } else {
      items = []
      state = status == "in_progress" ? "running" : status
    }
    let resultItem = items.first { $0["type"] as? String == "text" && ($0["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == result }
    if !result.isEmpty, resultItem == nil {
      items.append(["itemId": itemId + ":result", "type": "text", "text": result])
    }
    let resultID = resultItem?["itemId"] as? String ?? itemId + ":result"
    chat.itemAccessibilityIDs = result.isEmpty ? [:] : [resultID: "subagent-detail-result"]
    let entry: [String: Any] = ["id": entryId, "role": "assistant", "status": state,
      "finished": ["completed", "failed", "cancelled"].contains(state), "items": items]
    let data = try! JSONSerialization.data(withJSONObject: [entry])
    if run != nil {
      let empty = ["pending", "running"].contains(state) ? String(localized: "subagent.run.silent", bundle: .lody) : ""
      chat.setEmptyText(empty)
    }
    chat.setEntries(String(decoding: data, as: UTF8.self)); chat.scheduleUpdate()
    if isViewLoaded, view.window != nil { applyHeader() }
  }
}
