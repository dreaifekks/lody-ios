import Foundation

public struct OutboxServices: Sendable {
  public var createSession: @MainActor (String) async throws -> String
  public var ensureSession: @MainActor (String) async throws -> Void
  public var sendSessionTurn: @MainActor (String) async throws -> String
  public var confirmSessionCreation: (@MainActor (String) async throws -> String)?
  public var confirmSessionTurn: (@MainActor (String) async throws -> String)?
  public var releaseReserve: @MainActor (String) -> Void
  public var alert: @MainActor (_ title: String, _ message: String) -> Void

  public init(createSession: @escaping @MainActor (String) async throws -> String, ensureSession: @escaping @MainActor (String) async throws -> Void, sendSessionTurn: @escaping @MainActor (String) async throws -> String, releaseReserve: @escaping @MainActor (String) -> Void, alert: @escaping @MainActor (_ title: String, _ message: String) -> Void, confirmSessionCreation: (@MainActor (String) async throws -> String)? = nil, confirmSessionTurn: (@MainActor (String) async throws -> String)? = nil) {
    self.createSession = createSession
    self.ensureSession = ensureSession
    self.sendSessionTurn = sendSessionTurn
    self.releaseReserve = releaseReserve
    self.alert = alert
    self.confirmSessionCreation = confirmSessionCreation
    self.confirmSessionTurn = confirmSessionTurn
  }
}

public final class OutboxInflight: @unchecked Sendable {
  private let lock = NSLock()
  private var ids: [String: UUID] = [:]

  public init() {}

  public func contains(_ id: String) -> Bool { lock.withLock { ids[id] != nil } }
  public func set(_ id: String, _ active: Bool) {
    lock.withLock {
      if active { ids[id] = UUID() } else { ids.removeValue(forKey: id) }
    }
  }
  public func begin(_ id: String) -> UUID? {
    lock.withLock {
      guard ids[id] == nil else { return nil }
      let token = UUID(); ids[id] = token; return token
    }
  }
  public func end(_ id: String, token: UUID) {
    lock.withLock { if ids[id] == token { ids.removeValue(forKey: id) } }
  }

}

@MainActor
public final class OutboxDispatcher {
  public struct Inputs: Equatable, Sendable {
    public var userId = ""
    public var connected = false
    public var foregroundSessionId = ""
    public var latestUserMessages: [String: String] = [:]
    public var catalogRevision = 0
    public var context = OutboxForeground()

    public init(userId: String = "", connected: Bool = false, foregroundSessionId: String = "", latestUserMessages: [String: String] = [:], catalogRevision: Int = 0, context: OutboxForeground = OutboxForeground()) {
      self.userId = userId
      self.connected = connected
      self.foregroundSessionId = foregroundSessionId
      self.latestUserMessages = latestUserMessages
      self.catalogRevision = catalogRevision
      self.context = context
    }
  }

  private typealias Plan = (queue: Bool, guide: Bool)

  private struct Trigger: Equatable {
    public let store: ObjectIdentifier?
    public let revision: Int
    public let inputs: Inputs
  }

  public static let maxSessionReserves = 8
  private static let occupying: Set<String> = ["creating", "sending", "unknown", "uploaded"]
  private static let settled: Set<String> = ["accepted", "queued", "failed"]
  public nonisolated static let busy: Set<String> = ["running", "initializing", "processing", "in_progress", "queued", "requestPermission", "waiting"]

  public let inflight: OutboxInflight
  public var settled: (() -> Void)?
  private let services: OutboxServices
  private let text: (String) -> String
  private let foreground: String?
  private var store: OutboxStore?
  private var inputs = Inputs()
  private var released: [String: String] = [:]
  private var trigger: Trigger?
  private var scheduled = false
  private var paused = Set<String>()
  private var pointed = Set<String>()
  private var openFailures: [String: Int] = [:]
  private var wakeup: Task<Void, Never>?

  public var retryPause: Duration = .milliseconds(1500)
  public var confirmationPause: Duration = .seconds(5)

  private func wake(after delay: Duration) {
    guard wakeup == nil else { return }
    wakeup = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard let self, !Task.isCancelled else { return }
      self.wakeup = nil; self.paused.removeAll(); self.trigger = nil; self.schedule()
    }
  }

  public init(services: OutboxServices, inflight: OutboxInflight, foreground: String? = nil, text: @escaping (String) -> String) {
    self.services = services
    self.inflight = inflight
    self.foreground = foreground
    self.text = text
  }

  public func update(store: OutboxStore?, inputs: Inputs) {
    if self.store !== store || self.inputs.userId != inputs.userId {
      wakeup?.cancel(); wakeup = nil; paused.removeAll(); pointed.removeAll(); openFailures.removeAll()
    }
    self.store = store
    self.inputs = inputs
    schedule()
  }

  public func schedule() {
    guard !scheduled else { return }
    scheduled = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.scheduled = false
      self.run()
    }
  }

  private func run() {
    let next = Trigger(store: store.map(ObjectIdentifier.init), revision: store?.revision ?? 0, inputs: inputs)
    guard next != trigger else { return }
    trigger = next
    guard let store, store.snapshot.ready else { return }
    let records = store.snapshot.records
    if let foreground {
      if let record = records.first(where: { $0.sessionId == foreground }) { considerForeground(record, store: store) }
      return
    }
    guard !inputs.userId.isEmpty else { return }
    var slots = records.filter { $0.sessionId != inputs.foregroundSessionId && Self.occupying.contains($0.phase) }.count
    for record in records { consider(record, store: store, slots: &slots) }
  }

  private func consider(_ record: OutboxRecord, store: OutboxStore, slots: inout Int) {
    let id = record.sessionId, phase = record.phase
    if Self.settled.contains(phase) {
      let key = "\(id):\(record.sendId):\(phase)"
      guard released[id] != key else { return }
      released[id] = key
      services.releaseReserve(id)
      return
    }
    released[id] = nil
    guard id != inputs.foregroundSessionId else { return }
    if confirm(record, store: store) { return }
    let latest = inputs.latestUserMessages[id]
    if phase == "unknown" || phase == "uploaded", latest == record.sendId {
      let removal = store.remove(id)
      let services = services
      Task { @MainActor in
        _ = await removal.result
        services.releaseReserve(id)
      }
      return
    }
    if services.confirmSessionCreation == nil, record.creation != nil, latest != nil, phase == "unknown" {
      store.put(record.with(phase: "waiting", dropCreation: true))
      return
    }
    guard id != inputs.foregroundSessionId, phase == "waiting", !paused.contains(record.sendId), !inflight.contains(id),
          inputs.connected, slots < Self.maxSessionReserves else { return }
    slots += 1
    start(record, store: store, plan: nil)
  }

  private func considerForeground(_ record: OutboxRecord, store: OutboxStore) {
    let id = record.sessionId, phase = record.phase, context = inputs.context
    guard !inflight.contains(id) else { return }
    if confirm(record, store: store) { return }
    if record.creation == nil, context.transcript.replied.contains(record.sendId) {
      store.remove(id)
      return
    }
    if services.confirmSessionCreation == nil, record.creation != nil, context.serverCreated, phase == "unknown" {
      store.put(record.with(phase: "waiting", dropCreation: true))
      return
    }
    guard phase == "waiting", !paused.contains(record.sendId), !context.overflow, !inputs.userId.isEmpty,
          record.creation != nil || !context.transcript.entryIds.contains(record.sendId),
          record.creation == nil ? context.live : inputs.connected else { return }
    start(record, store: store, plan: context.plan(record.send))
  }

  private func start(_ record: OutboxRecord, store: OutboxStore, plan: Plan?) {
    let id = record.sessionId
    guard let lease = inflight.begin(id) else { return }
    let marked = record.with(phase: record.creation == nil ? "sending" : "creating")
    let marking = store.put(marked)
    let userId = inputs.userId
    Task { @MainActor in
      await self.dispatch(record, marked: marked, marking: marking, store: store, userId: userId, plan: plan, lease: lease)
      self.inflight.end(id, token: lease)
      self.trigger = nil
      self.schedule()
      self.settled?()
    }
  }

  private func dispatch(_ record: OutboxRecord, marked: OutboxRecord, marking: Task<Void, Error>,
                        store: OutboxStore, userId: String, plan: Plan?, lease: UUID) async {
    let id = record.sessionId
    var started = false
    do {
      try await marking.value
      guard self.store === store, self.inputs.userId == userId else { return }
      let latest = store.snapshot.records.first { $0.sessionId == id }
      guard latest?.sendId == record.sendId, latest?.phase == marked.phase else { return }
      if let creation = record.creation {
        started = true
        let result = try Self.parse(await services.createSession(creation))
        guard current(record, store: store, userId: userId) else { return }
        switch result["state"]?.string {
        case "created":
          guard let session = result["session"]?.object else { throw OutboxError.invalidRecord }
          inflight.end(id, token: lease)
          var created = record.with(phase: "waiting", dropCreation: true)
          created.session = session
          try await store.put(created).value
        case "rejected":
          if Self.notReady(result) { await wait(record, store: store, lease: lease); return }
          await fail(record, store: store, reason: quotaError(result["reason"]?.string, fallback: "send.error.sessionNotCreated"))
        default:
          try await store.put(record.with(phase: "unknown")).value
        }
        return
      }
      do { try await services.ensureSession(id); openFailures[record.sendId] = nil } catch {
        guard current(record, store: store, userId: userId) else { return }
        let failures = (openFailures[record.sendId] ?? 0) + 1
        if failures < 3 {
          openFailures[record.sendId] = failures
          await wait(record, store: store, lease: lease); return
        }
        openFailures[record.sendId] = nil
        await fail(record, store: store, reason: text("native.runtime.sessionNotSyncedRetry"))
        return
      }
      guard current(record, store: store, userId: userId) else { return }
      started = true
      let result = try Self.parse(await services.sendSessionTurn(Self.turn(record, userId: userId, plan: plan)))
      guard current(record, store: store, userId: userId) else { return }
      let state = result["state"]?.string ?? ""
      if state == "not_sent" {
        if Self.notReady(result) {
          await wait(record, store: store, lease: lease)
          return
        }
        await fail(record, store: store, reason: quotaError(result["reason"]?.string, fallback: "send.error.notSent"))
        return
      }
      var next = record.with(phase: ["accepted", "uploaded", "queued"].contains(state) ? state : "unknown")
      if let plan { next.send["guide"] = .bool(plan.guide) }
      try await store.put(next).value
    } catch {
      guard current(record, store: store, userId: userId) else { return }
      if started { _ = await store.put(record.with(phase: "unknown")).result }
      else { await fail(record, store: store, reason: text("send.error.draftSaveFailed")) }
    }
  }

  private func current(_ record: OutboxRecord, store: OutboxStore, userId: String) -> Bool {
    self.store === store && inputs.userId == userId &&
      store.snapshot.records.first(where: { $0.sessionId == record.sessionId })?.sendId == record.sendId
  }

  private static func notReady(_ result: [String: OutboxValue]) -> Bool {
    result["retryable"] == .bool(true) || ["session_not_ready", "metadata_not_ready"].contains(result["reason"]?.string ?? "")
  }

  private func wait(_ record: OutboxRecord, store: OutboxStore, lease: UUID) async {
    guard self.store === store, inputs.userId != "",
      store.snapshot.records.first(where: { $0.sessionId == record.sessionId })?.sendId == record.sendId else { return }
    paused.insert(record.sendId)
    inflight.end(record.sessionId, token: lease)
    // Release ownership before the store notification wakes either dispatcher.
    _ = await store.put(record.with(phase: "waiting")).result
    wake(after: retryPause)
  }

  /// Confirm an ended attempt from a fresh replica; never replay an unknown write.
  private func confirm(_ record: OutboxRecord, store: OutboxStore) -> Bool {
    guard record.phase == "unknown" || (record.phase == "uploaded" && !pointed.contains(record.sendId)),
      let creation = services.confirmSessionCreation, let turn = services.confirmSessionTurn else { return false }
    guard inputs.connected || inputs.context.live else { return true }
    guard !paused.contains(record.sendId), let lease = inflight.begin(record.sessionId) else { return true }
    paused.insert(record.sendId)
    let user = inputs.userId
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        self.inflight.end(record.sessionId, token: lease)
        if self.store === store, self.inputs.userId == user { self.wake(after: self.confirmationPause) }
      }
      do {
        guard self.current(record, store: store, userId: user) else { return }
        let reply: String
        if let payload = record.creation { reply = try await creation(payload) }
        else {
          try await self.services.ensureSession(record.sessionId)
          guard self.current(record, store: store, userId: user) else { return }
          let payload = OutboxValue.object(["sessionId": .string(record.sessionId), "id": .string(record.sendId)])
          let data = try JSONEncoder().encode(payload)
          reply = try await turn(String(decoding: data, as: UTF8.self))
        }
        let verdict = try Self.parse(reply)
        guard self.store === store, self.inputs.userId == user,
          let latest = store.snapshot.records.first(where: { $0.sessionId == record.sessionId }),
          latest.sendId == record.sendId, latest.phase == record.phase else { return }
        var state = verdict["state"]?.string ?? ""
        if state == "seen" {
          if record.creation != nil { state = "created" }
          else { state = verdict["delivery"]?.string ?? "uploaded" }
        }
        if record.phase == "uploaded" {
          if ["uploaded", "queued", "seen"].contains(state) { self.pointed.insert(record.sendId) }
          return
        }
        switch state {
        case "created":
          self.inflight.end(record.sessionId, token: lease)
          self.paused.remove(record.sendId)
          var next = latest.with(phase: "waiting", dropCreation: true)
          if let session = verdict["session"]?.object { next.session = session }
          _ = await store.put(next).result
        case "uploaded", "queued":
          self.pointed.insert(record.sendId)
          _ = await store.put(latest.with(phase: state)).result
        case "absent":
          var next = latest.with(phase: "failed", reason: self.text("send.error.notDelivered"))
          next.send["id"] = .string(verdict["retryId"]?.string ?? UUID().uuidString)
          guard case .success = await store.put(next).result, self.store === store, self.inputs.userId == user else { return }
          self.services.alert(self.text("send.alert.title"), self.text("send.error.notDelivered"))
        default: break
        }
      } catch { /* Still unknown; ask again after the bounded pause. */ }
    }
    return true
  }

  private func fail(_ record: OutboxRecord, store: OutboxStore, reason: String) async {
    let reason = reason == "mention_expansion_failed" ? text("send.error.mentions") : reason
    guard case .success = await store.put(record.with(phase: "failed", reason: reason)).result, self.store === store else { return }
    services.alert(text("send.alert.title"), reason)
  }

  public func quotaError(_ reason: String?, fallback: String) -> String {
    let keys = [
      "shortcut_unavailable": "send.error.shortcut",
      "mcp_catalog_unavailable": "send.error.mcpCatalog",
      "mcp_connection_missing": "send.error.mcpConnection",
      "workspace_payment_required": "send.error.workspacePaymentRequired",
      "free_session_limit_reached": "send.error.freeSessionLimit",
      "free_session_turn_limit_reached": "send.error.freeTurnLimit",
    ]
    if let reason, let key = keys[reason] { return text(key) }
    if let reason, !reason.isEmpty { return reason }
    return text(fallback)
  }

  private static func parse(_ json: String) throws -> [String: OutboxValue] {
    guard let value = try JSONDecoder().decode(OutboxValue.self, from: Data(json.utf8)).object else {
      throw OutboxError.invalidRecord
    }
    return value
  }

  public static func turn(_ record: OutboxRecord, userId: String, plan: (queue: Bool, guide: Bool)? = nil) -> String {
    let session = record.session, send = record.send
    let busy = send["queue"] == .bool(true) || Self.busy.contains(session["status"]?.string ?? "")
    let plan = plan ?? (send["guide"]?.truthy != true && busy, send["guide"] == .bool(true))
    var payload: [String: OutboxValue] = [
      "userId": .string(userId),
      "guide": .bool(plan.guide),
      "queue": .bool(plan.queue),
    ]
    payload["sessionId"] = session["id"]
    for key in ["machineId", "cliType", "agentType", "resume"] { payload[key] = session[key] }
    for key in ["id", "text", "attachments"] { payload[key] = send[key] }
    let choice = send["choice"]?.object ?? [:]
    for (from, to) in [("modelId", "modelId"), ("modeId", "modeId"), ("effort", "reasoningEffort"),
                       ("reasoningEffortConfigId", "reasoningEffortConfigId"), ("configOptionValues", "configOptionValues")] {
      payload[to] = choice[from]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    return (try? encoder.encode(OutboxValue.object(payload))).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
  }
}
