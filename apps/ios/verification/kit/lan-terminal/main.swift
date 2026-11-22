import Foundation
import Network

// Compile only via the caller-owned native verification batch; see README.md.
// Source migrated from df8d9343; this file is not run by the static Node check.
// The key vector comes from Lody's `deriveLanTerminalKey` (Node sha256). A local
// TLS-PSK listener with the same suite stands in for a LAN member.

func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "", line: Int = #line) {
  if !condition() {
    FileHandle.standardError.write(Data("FAIL line \(line): \(message())\n".utf8))
    exit(1)
  }
}

let key = LanTerminalProtocol.key(token: "test-token")
check(key.map { String(format: "%02x", $0) }.joined() == "8e4b7e3db4777d2f72d036c7b68a30f482c673f14507c4f71c790662391d1f59")

// Lines split on the byte; blank lines vanish; a partial line waits.
var buffer = LanTerminalLineBuffer()
let split = "{\"a\":\"é".data(using: .utf8)!
let first = try buffer.append(split.prefix(split.count - 1))
check(first.isEmpty)
let rest = try buffer.append(split.suffix(1) + Data("\"}\n\n  \r\n{\"b\":1}\n{\"c\"".utf8))
check(rest.map { String(decoding: $0, as: UTF8.self) } == ["{\"a\":\"é\"}", "{\"b\":1}"], "\(rest)")
var completeHuge = LanTerminalLineBuffer()
do {
  _ = try completeHuge.append(Data(repeating: 0x20, count: LanTerminalLineBuffer.maxLine + 1) + Data([0x0A]))
  check(false, "an oversized complete line must fail too")
} catch {}
var huge = LanTerminalLineBuffer()
do {
  _ = try huge.append(Data(count: LanTerminalLineBuffer.maxLine + 1))
  check(false, "an oversized line must fail")
} catch {}

// Server events decode per their schema; anything else is invalid.
func event(_ json: String) -> LanTerminalEvent? { LanTerminalEvent.decode(Data(json.utf8)) }
check(event(#"{"type":"opened","requestId":"2","terminalId":"t","cwd":"/w"}"#) == .opened(requestId: "2", terminalId: "t", cwd: "/w"))
check(event(#"{"type":"data","terminalId":"t","data":"hi","replay":true}"#) == .data(requestId: nil, terminalId: "t", data: "hi", replay: true))
check(event(#"{"type":"exit","terminalId":"t","exitCode":0}"#) == .exit(requestId: nil, terminalId: "t", exitCode: 0, signal: nil))
check(event(#"{"type":"terminals","requestId":"1","sessionId":"s","terminals":[{"terminalId":"t","title":"zsh"}]}"#)
  == .terminals(requestId: "1", sessionId: "s", terminals: [LanTerminalSnapshot(terminalId: "t", title: "zsh", cwd: nil)]))
check(event(#"{"type":"error","code":"remote_unreachable","message":"gone"}"#) == .error(requestId: nil, terminalId: nil, code: "remote_unreachable", message: "gone"))
check(event(#"{"type":"opened","terminalId":""}"#) == nil)
check(event(#"{"type":"data","terminalId":"t"}"#) == nil)
check(event(#"{"type":"nope"}"#) == nil)
check(event("not json") == nil)

// Client messages carry only their own fields.
let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(LanTerminalCommand.resize(terminalId: "t", cols: 90, rows: 30))) as! [String: Any]
check(Set(encoded.keys) == ["type", "terminalId", "cols", "rows"], "\(encoded)")

// Native saved-catalog projection keeps valid endpoints and drops malformed
// entries independently, including old snapshots without terminal metadata.
let savedCatalog = Data(#"{"catalog":{"projects":[],"sessions":[],"machineIds":[],"machineTerminals":{"good":{"host":"127.0.0.1","port":8789},"bad":{"host":"","port":0}}}}"#.utf8)
let catalog = SessionCatalog.decode(saved: savedCatalog)
check(catalog?.machineTerminals == ["good": LanTerminalEndpoint(host: "127.0.0.1", port: 8789)])
check(SessionCatalog.decode(saved: Data(#"{"catalog":{"projects":[],"sessions":[],"machineIds":[]}}"#.utf8))?.machineTerminals.isEmpty == true)

// MARK: Loopback member

let lanId = "13be09de9d11c08582ccb5d76d588f0b"
let machineId = "machine-under-test"

func tlsOptions() -> NWProtocolTLS.Options {
  let tls = NWProtocolTLS.Options()
  let security = tls.securityProtocolOptions
  sec_protocol_options_add_pre_shared_key(
    security,
    key.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData,
    Data(lanId.utf8).withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
  )
  sec_protocol_options_append_tls_ciphersuite(security, tls_ciphersuite_t(rawValue: LanTerminalProtocol.cipherSuite)!)
  sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
  sec_protocol_options_set_max_tls_protocol_version(security, .TLSv12)
  sec_protocol_options_set_tls_resumption_enabled(security, false)
  return tls
}

final class Box<T>: @unchecked Sendable { var value: T; init(_ value: T) { self.value = value } }

/// Answers like `createLanTerminalServer` + `serveTerminalConnection`.
final class Member: @unchecked Sendable {
  let listener: NWListener
  let queue = DispatchQueue(label: "member")
  var hello: [String: Any]?
  var refuse: [String: String]?
  var received: [[String: Any]] = []
  var connections: [NWConnection] = []
  var shells: [String: String] = [:]
  var openedCount = 0
  var attached: [ObjectIdentifier: Set<String>] = [:]
  var admitted: [ObjectIdentifier: Set<String>] = [:]
  var ending = Set<String>()
  var helloVersion = 1
  var delayOpen = false
  var lateOpen: (() -> Void)?

  init() throws {
    let parameters = NWParameters(tls: tlsOptions())
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters)
    listener.newConnectionHandler = { [unowned self] connection in
      self.connections.append(connection)
      connection.start(queue: self.queue)
      self.read(connection, buffer: LanTerminalLineBuffer())
    }
  }

  func start() -> UInt16 {
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    listener.start(queue: queue)
    _ = ready.wait(timeout: .now() + 5)
    return listener.port!.rawValue
  }

  /// `end` flushes before closing, like Node's `socket.end()`.
  func write(_ connection: NWConnection, _ value: [String: Any], end: Bool = false) {
    var data = try! JSONSerialization.data(withJSONObject: value)
    data.append(0x0A)
    connection.send(content: data, completion: .contentProcessed { _ in if end { connection.cancel() } })
  }

  func read(_ connection: NWConnection, buffer: LanTerminalLineBuffer) {
    let buffer = Box(buffer)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [unowned self] content, _, complete, error in
      for line in (try? buffer.value.append(content ?? Data())) ?? [] {
        let message = try! JSONSerialization.jsonObject(with: line) as! [String: Any]
        self.answer(connection, message)
      }
      if !complete, error == nil { self.read(connection, buffer: buffer.value) }
      else {
        self.attached.removeValue(forKey: ObjectIdentifier(connection))
        self.admitted.removeValue(forKey: ObjectIdentifier(connection))
      }
    }
  }

  /// Model node-pty: close requests hang up first; the record disappears only
  /// in the asynchronous exit callback, published to subscribed connections.
  func end(_ id: String) {
    guard ending.insert(id).inserted else { return }
    queue.asyncAfter(deadline: .now() + .milliseconds(150)) { [self] in
      shells.removeValue(forKey: id)
      ending.remove(id)
      for connection in connections {
        let key = ObjectIdentifier(connection)
        if attached[key]?.remove(id) != nil {
          write(connection, ["type": "exit", "terminalId": id, "exitCode": 0])
        }
      }
    }
  }

  func reject(_ connection: NWConnection, _ message: [String: Any]) {
    var answer: [String: Any] = ["type": "error", "code": "terminal_not_found", "message": "terminal_not_found: not admitted or exited"]
    answer["requestId"] = message["requestId"]
    answer["terminalId"] = message["terminalId"]
    write(connection, answer)
  }

  func answer(_ connection: NWConnection, _ message: [String: Any]) {
    received.append(message)
    let scope = ObjectIdentifier(connection)
    let requestId = message["requestId"] as? String
    switch message["type"] as? String {
    case "hello":
      hello = message
      if let refuse {
        write(connection, ["type": "error", "code": refuse["code"]!, "message": refuse["message"]!], end: true)
        return
      }
      write(connection, ["type": "hello", "version": helloVersion, "machineId": machineId, "service": "terminal"])
    case "open":
      openedCount += 1
      let id = "t\(openedCount)"
      shells[id] = message["sessionId"] as? String
      admitted[scope, default: []].insert(id)
      let answer = { [self] in write(connection, ["type": "opened", "requestId": requestId!, "terminalId": id, "cwd": "/work"]) }
      if delayOpen { lateOpen = answer } else { answer() }
    case "attach":
      let id = message["terminalId"] as! String
      guard shells[id] != nil else { reject(connection, message); return }
      admitted[scope, default: []].insert(id)
      attached[ObjectIdentifier(connection), default: []].insert(id)
      write(connection, ["type": "data", "requestId": requestId!, "terminalId": id, "data": "replayed", "replay": true])
      write(connection, ["type": "title", "requestId": requestId!, "terminalId": id, "title": "zsh"])
    case "resize":
      let id = message["terminalId"] as! String
      guard admitted[scope]?.contains(id) == true, shells[id] != nil else { reject(connection, message); return }
    case "list" where message["sessionId"] as? String != "missing":
      let session = message["sessionId"] as! String
      for (id, owner) in shells where owner == session { admitted[scope, default: []].insert(id) }
      let values = shells.filter { $0.value == session }.map { ["terminalId": $0.key, "title": "zsh"] }
      write(connection, ["type": "terminals", "requestId": requestId!, "sessionId": session, "terminals": values])
    case "list":
      write(connection, ["type": "error", "requestId": requestId!, "code": "terminal_not_found", "message": "no such session"])
    case "input":
      let id = message["terminalId"] as! String
      guard admitted[scope]?.contains(id) == true, shells[id] != nil else { reject(connection, message); return }
      if message["data"] as? String == "exit\r" {
        end(id)
      } else {
        write(connection, ["type": "data", "terminalId": id, "data": "echo:\(message["data"] as! String)"])
      }
    case "close":
      let id = message["terminalId"] as! String
      guard admitted[scope]?.contains(id) == true, shells[id] != nil else { reject(connection, message); return }
      end(id)
    case "silent":
      break
    default:
      break
    }
  }
}

func wait<T>(_ timeout: TimeInterval = 12, _ body: (@escaping @Sendable (T) -> Void) -> Void) -> T? {
  let done = DispatchSemaphore(value: 0)
  let result = Box<T?>(nil)
  body { value in
    result.value = value
    done.signal()
  }
  return done.wait(timeout: .now() + timeout) == .success ? result.value : nil
}

let member = try Member()
let port = member.start()
let callbacks = DispatchQueue(label: "callbacks")
let endpoint = LanTerminalEndpoint(host: "127.0.0.1", port: port)

// A full session: hello, open, attach with its replay, input, live output, close.
let link = LanTerminalLink(endpoint: endpoint, lanId: lanId, key: key, machineId: machineId, callbackQueue: callbacks)
let events = Box<[LanTerminalEvent]>([])
link.onEvent = { events.value.append($0) }
let hello: Result<Void, LanTerminalLink.Failure>? = wait { done in link.start(completion: done) }
check({ if case .success = hello { true } else { false } }(), "\(String(describing: hello))")
check(member.hello?["machineId"] as? String == machineId && member.hello?["service"] as? String == "terminal")
let opened = wait { done in link.request(.open(sessionId: "s1", cols: 80, rows: 24), completion: done) }
check({ if case .success(.opened(_, "t1", "/work")) = opened { true } else { false } }(), "\(String(describing: opened))")
let attached = wait { done in link.request(.attach(terminalId: "t1", cols: 80, rows: 24), completion: done) }
check({ if case .success(.title(_, "t1", "zsh")) = attached { true } else { false } }(), "\(String(describing: attached))")
let refused = wait { done in link.request(.list(sessionId: "missing"), completion: done) }
check({ if case .failure(.refused("terminal_not_found", "no such session")) = refused { true } else { false } }(), "\(String(describing: refused))")
link.send(.resize(terminalId: "t1", cols: 100, rows: 32))
link.send(.input(terminalId: "t1", data: "ls\r"))
Thread.sleep(forTimeInterval: 0.5)
callbacks.sync {}
check(events.value.contains(.data(requestId: "2", terminalId: "t1", data: "replayed", replay: true)), "\(events.value)")
check(events.value.contains(.data(requestId: nil, terminalId: "t1", data: "echo:ls\r", replay: false)), "\(events.value)")
let closed = Box(false)
link.onClose = { _ in closed.value = true }
link.close(terminal: "t1")
Thread.sleep(forTimeInterval: 0.5)
check(member.received.contains { $0["type"] as? String == "close" && $0["terminalId"] as? String == "t1" }, "\(member.received)")

check(member.queue.sync { member.received.contains { $0["type"] as? String == "resize" && $0["cols"] as? Int == 100 } })

// Leaving while open is in flight closes its late shell; no UI callback adopts it.
member.queue.sync { member.delayOpen = true }
let delayed = LanTerminalLink(endpoint: endpoint, lanId: lanId, key: key, machineId: machineId, callbackQueue: callbacks)
let connected: Result<Void, LanTerminalLink.Failure>? = wait { delayed.start(completion: $0) }
check({ if case .success = connected { true } else { false } }())
let listed: Result<LanTerminalEvent, LanTerminalLink.Failure>? = wait { delayed.request(.list(sessionId: "s1"), completion: $0) }
check({ if case let .success(.terminals(_, id, terminals)) = listed { id == "s1" && terminals.isEmpty } else { false } }())
let adopted = Box(false)
delayed.request(.open(sessionId: "s1", cols: 80, rows: 24)) { value in
  if case .success = value { adopted.value = true }
}
let deadline = Date().addingTimeInterval(3)
while member.queue.sync(execute: { member.lateOpen == nil }), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
check(member.queue.sync { member.lateOpen != nil }, "member never received open")
let beforeClose = member.queue.sync { member.received.filter { $0["type"] as? String == "close" }.count }
delayed.cancel()
member.queue.sync { member.lateOpen?(); member.lateOpen = nil; member.delayOpen = false }
Thread.sleep(forTimeInterval: 0.5)
callbacks.sync {}
check(!adopted.value, "late open reached the departed page")
check(member.queue.sync { member.received.filter { $0["type"] as? String == "close" }.count } == beforeClose + 1, "late shell was orphaned")

// Live exit is forwarded as an event.
let exiting = LanTerminalLink(endpoint: endpoint, lanId: lanId, key: key, machineId: machineId, callbackQueue: callbacks)
let exitEvents = Box<[LanTerminalEvent]>([])
exiting.onEvent = { exitEvents.value.append($0) }
let exitHello: Result<Void, LanTerminalLink.Failure>? = wait { exiting.start(completion: $0) }
check({ if case .success = exitHello { true } else { false } }())
let exitOpen: Result<LanTerminalEvent, LanTerminalLink.Failure>? = wait { exiting.request(.open(sessionId: "s1", cols: 80, rows: 24), completion: $0) }
check({ if case .success(.opened(_, _, _)) = exitOpen { true } else { false } }())
guard case let .success(.opened(_, exitedID, _)) = exitOpen else { fatalError("no exit shell") }
let exitAttached: Result<LanTerminalEvent, LanTerminalLink.Failure>? = wait { exiting.request(.attach(terminalId: exitedID, cols: 80, rows: 24), completion: $0) }
check({ if case .success(.title(_, _, _)) = exitAttached { true } else { false } }())
exiting.send(.input(terminalId: exitedID, data: "exit\r"))
Thread.sleep(forTimeInterval: 0.5)
callbacks.sync {}
check(exitEvents.value.contains(.exit(requestId: nil, terminalId: exitedID, exitCode: 0, signal: nil)))
exiting.cancel()

// A fresh connection must not be able to close a known but unadmitted ID.
member.queue.sync { member.shells["scope-owned"] = "scope-test" }
let scopeLink = LanTerminalLink(endpoint: endpoint, lanId: lanId, key: key, machineId: machineId, callbackQueue: callbacks)
let scopeHello: Result<Void, LanTerminalLink.Failure>? = wait { scopeLink.start(completion: $0) }
check({ if case .success = scopeHello { true } else { false } }())
let unadmittedClose: Result<LanTerminalEvent, LanTerminalLink.Failure>? = wait { scopeLink.request(.close(terminalId: "scope-owned"), completion: $0) }
check({ if case .failure(.refused("terminal_not_found", _)) = unadmittedClose { true } else { false } }())
check(member.queue.sync { member.shells["scope-owned"] == "scope-test" }, "unadmitted close killed a shell")
let scopeList: Result<LanTerminalEvent, LanTerminalLink.Failure>? = wait { scopeLink.request(.list(sessionId: "scope-test"), completion: $0) }
check({ if case let .success(.terminals(_, _, values)) = scopeList { values.contains { $0.terminalId == "scope-owned" } } else { false } }())
scopeLink.adopt(terminalId: "scope-owned")
let scopeAttach: Result<LanTerminalEvent, LanTerminalLink.Failure>? = wait { scopeLink.request(.attach(terminalId: "scope-owned", cols: 80, rows: 24), completion: $0) }
check({ if case .success(.title(_, "scope-owned", _)) = scopeAttach { true } else { false } }())
let scopeClosed: Bool? = wait { scopeLink.cancel(completion: $0) }
check(scopeClosed == true, "list/attach then close must wait for asynchronous exit")
check(member.queue.sync { member.shells["scope-owned"] == nil })

// Explicit local rejection means no command was submitted, so UI can retry.
let notStarted = LanTerminalLink(endpoint: endpoint, lanId: lanId, key: key, machineId: machineId, callbackQueue: callbacks)
let opensBeforeLocalReject = member.queue.sync { member.openedCount }
let notSent: Result<LanTerminalEvent, LanTerminalLink.Failure>? = wait { notStarted.request(.open(sessionId: "not-sent", cols: 80, rows: 24), completion: $0) }
check({ if case .failure(.notSent(_)) = notSent { true } else { false } }())
check(member.queue.sync { member.openedCount } == opensBeforeLocalReject)
notStarted.cancel()
let rejectedAfterStop: Result<LanTerminalEvent, LanTerminalLink.Failure>? = wait { notStarted.request(.open(sessionId: "not-sent", cols: 80, rows: 24), completion: $0) }
check({ if case .failure(.notSent(_)) = rejectedAfterStop { true } else { false } }())
check(member.queue.sync { member.openedCount } == opensBeforeLocalReject)

// A dropped socket retains its PTY. Reconnection lists/adopts/attaches the
// same ID; it never opens another shell or claims a desktop-owned terminal.
let recover = LanTerminalLink(endpoint: endpoint, lanId: lanId, key: key, machineId: machineId, callbackQueue: callbacks)
let recoverHello: Result<Void, LanTerminalLink.Failure>? = wait { recover.start(completion: $0) }
check({ if case .success = recoverHello { true } else { false } }())
let recoverOpen: Result<LanTerminalEvent, LanTerminalLink.Failure>? = wait { recover.request(.open(sessionId: "recovery", cols: 80, rows: 24), completion: $0) }
guard case let .success(.opened(_, recoveredID, _)) = recoverOpen else { fatalError("no recovery shell") }
member.queue.sync { member.shells["desktop-owned"] = "recovery" }
let opensBeforeReconnect = member.queue.sync { member.openedCount }
let lost: Bool? = wait { done in
  recover.onClose = { _ in done(true) }
  member.queue.sync { member.connections.forEach { $0.cancel() } }
}
check(lost == true)
let resumed = LanTerminalLink(endpoint: endpoint, lanId: lanId, key: key, machineId: machineId, callbackQueue: callbacks)
let resumedHello: Result<Void, LanTerminalLink.Failure>? = wait { resumed.start(completion: $0) }
check({ if case .success = resumedHello { true } else { false } }())
let resumedList: Result<LanTerminalEvent, LanTerminalLink.Failure>? = wait { resumed.request(.list(sessionId: "recovery"), completion: $0) }
check({ if case let .success(.terminals(_, _, terminals)) = resumedList { terminals.contains { $0.terminalId == recoveredID } && terminals.count == 2 } else { false } }())
resumed.adopt(terminalId: recoveredID)
let restored: Result<LanTerminalEvent, LanTerminalLink.Failure>? = wait { resumed.request(.attach(terminalId: recoveredID, cols: 90, rows: 30), completion: $0) }
check({ if case let .success(.title(_, id, _)) = restored { id == recoveredID } else { false } }())
check(member.queue.sync { member.openedCount } == opensBeforeReconnect)
let lostAgain: Bool? = wait { done in
  resumed.onClose = { _ in done(true) }
  member.queue.sync { member.connections.forEach { $0.cancel() } }
}
check(lostAgain == true)
// End with an already-dead link: cleanup is independent of the new-open gate.
let cleaned: Bool? = wait { done in
  LanTerminalLink.cleanup(endpoint: endpoint, lanId: lanId, key: key, machineId: machineId,
    sessionId: "recovery", terminalId: recoveredID, completion: done)
}
check(cleaned == true)
check(member.queue.sync { member.shells[recoveredID] == nil && member.shells["desktop-owned"] == "recovery" })
check(member.queue.sync { !member.received.contains { $0["type"] as? String == "close_session" } })

let closesBeforeAbsent = member.queue.sync { member.received.filter { $0["type"] as? String == "close" }.count }
let alreadyGone: Bool? = wait { done in
  LanTerminalLink.cleanup(endpoint: endpoint, lanId: lanId, key: key, machineId: machineId,
    sessionId: "recovery", terminalId: recoveredID, completion: done)
}
check(alreadyGone == true)
check(member.queue.sync { member.received.filter { $0["type"] as? String == "close" }.count } == closesBeforeAbsent)

// cancel on an adopted link is scoped to its one known page-owned ID.
member.queue.sync { member.shells["page-owned"] = "recovery" }
let adopter = LanTerminalLink(endpoint: endpoint, lanId: lanId, key: key, machineId: machineId, callbackQueue: callbacks)
let adopterHello: Result<Void, LanTerminalLink.Failure>? = wait { adopter.start(completion: $0) }
check({ if case .success = adopterHello { true } else { false } }())
adopter.adopt(terminalId: "page-owned")
let adopterAttach: Result<LanTerminalEvent, LanTerminalLink.Failure>? = wait { adopter.request(.attach(terminalId: "page-owned", cols: 80, rows: 24), completion: $0) }
check({ if case .success(.title(_, "page-owned", _)) = adopterAttach { true } else { false } }())
let adoptedClose: Bool? = wait { adopter.cancel(completion: $0) }
check(adoptedClose == true)
check(member.queue.sync { member.shells["page-owned"] == nil && member.shells["desktop-owned"] != nil })

// A still-alive peer can leave open unanswered. Stopping must expire within
// one requestTimeout grace. With no ID the client cannot safely guess a PTY.
member.queue.sync { member.delayOpen = true }
let stalled = LanTerminalLink(endpoint: endpoint, lanId: lanId, key: key, machineId: machineId, callbackQueue: callbacks)
let stalledHello: Result<Void, LanTerminalLink.Failure>? = wait { stalled.start(completion: $0) }
check({ if case .success = stalledHello { true } else { false } }())
stalled.request(.open(sessionId: "unknown", cols: 80, rows: 24)) { _ in }
let openDeadline = Date().addingTimeInterval(3)
while member.queue.sync(execute: { member.lateOpen == nil }), Date() < openDeadline { Thread.sleep(forTimeInterval: 0.01) }
check(member.queue.sync { member.lateOpen != nil })
let closesBeforeTimeout = member.queue.sync { member.received.filter { $0["type"] as? String == "close" }.count }
let timedOut: Bool? = wait { done in
  stalled.onClose = { failure in done(failure == .timedOut) }
  stalled.cancel()
}
check(timedOut == true, "stopping open retained the connection forever")
check(member.queue.sync { member.received.filter { $0["type"] as? String == "close" }.count } == closesBeforeTimeout, "guessed an unknown shell ID")
member.queue.sync {
  member.lateOpen = nil; member.delayOpen = false
  member.shells = member.shells.filter { $0.value != "unknown" } // test harness teardown only
}

// A protocol version mismatch must not become ready.
member.queue.sync { member.helloVersion = 2 }
let future = LanTerminalLink(endpoint: endpoint, lanId: lanId, key: key, machineId: machineId, callbackQueue: callbacks)
let futureHello: Result<Void, LanTerminalLink.Failure>? = wait { future.start(completion: $0) }
check({ if case .failure(.anotherMachine) = futureHello { true } else { false } }())
member.queue.sync { member.helloVersion = 1 }

// A member refuses a hello it cannot serve.
member.refuse = ["code": "machine_mismatch", "message": "Another machine of this LAN answers at this address"]
let mismatched = LanTerminalLink(endpoint: endpoint, lanId: lanId, key: key, machineId: machineId, callbackQueue: callbacks)
let refusal: Result<Void, LanTerminalLink.Failure>? = wait { done in mismatched.start(completion: done) }
check({ if case .failure(.refused("machine_mismatch", _)) = refusal { true } else { false } }(), "\(String(describing: refusal))")
member.refuse = nil

// A different machine at the address is not trusted.
let other = LanTerminalLink(endpoint: endpoint, lanId: lanId, key: key, machineId: "someone-else", callbackQueue: callbacks)
let wrong: Result<Void, LanTerminalLink.Failure>? = wait { done in other.start(completion: done) }
check({ if case .failure(.anotherMachine) = wrong { true } else { false } }(), "\(String(describing: wrong))")

// Without the LAN's key the handshake never completes.
let stranger = LanTerminalLink(endpoint: endpoint, lanId: lanId, key: LanTerminalProtocol.key(token: "other"), machineId: machineId, callbackQueue: callbacks)
let denied: Result<Void, LanTerminalLink.Failure>? = wait { done in stranger.start(completion: done) }
check({ if case .success = denied { false } else { denied != nil } }(), "\(String(describing: denied))")

// Nothing listens: the link fails instead of waiting.
member.listener.cancel()
Thread.sleep(forTimeInterval: 0.3)
let gone = LanTerminalLink(endpoint: endpoint, lanId: lanId, key: key, machineId: machineId, callbackQueue: callbacks)
let unreachable: Result<Void, LanTerminalLink.Failure>? = wait { done in gone.start(completion: done) }
check({ if case .success = unreachable { false } else { unreachable != nil } }(), "\(String(describing: unreachable))")

let failedCleanup: Bool? = wait { done in
  LanTerminalLink.cleanup(endpoint: endpoint, lanId: lanId, key: key, machineId: machineId,
    sessionId: "recovery", terminalId: "page-owned", completion: done)
}
check(failedCleanup == false, "unreachable cleanup did not terminate")

print("PASS: reconnect preserves shell ID, adopted cancel and dead-link cleanup are scoped, unknown open drains within deadline; LAN terminal key, framing, events, commands; loopback hello, open/attach replay, input, close, refusal, machine and key checks")
