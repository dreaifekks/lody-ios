import Foundation
import Network

// swiftc -swift-version 6 ../../ios/LanTerminal/LanTerminalLink.swift main.swift -o /tmp/lan-terminal && /tmp/lan-terminal
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

  init() throws {
    listener = try NWListener(using: NWParameters(tls: tlsOptions()), on: .any)
    listener.newConnectionHandler = { [unowned self] connection in
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
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [unowned self] content, _, complete, _ in
      for line in (try? buffer.value.append(content ?? Data())) ?? [] {
        let message = try! JSONSerialization.jsonObject(with: line) as! [String: Any]
        self.answer(connection, message)
      }
      if !complete { self.read(connection, buffer: buffer.value) }
    }
  }

  func answer(_ connection: NWConnection, _ message: [String: Any]) {
    let requestId = message["requestId"] as? String
    switch message["type"] as? String {
    case "hello":
      hello = message
      if let refuse {
        write(connection, ["type": "error", "code": refuse["code"]!, "message": refuse["message"]!], end: true)
        return
      }
      write(connection, ["type": "hello", "version": 1, "machineId": machineId, "service": "terminal"])
    case "open":
      write(connection, ["type": "opened", "requestId": requestId!, "terminalId": "t1", "cwd": "/work"])
    case "attach":
      write(connection, ["type": "data", "requestId": requestId!, "terminalId": "t1", "data": "replayed", "replay": true])
      write(connection, ["type": "title", "requestId": requestId!, "terminalId": "t1", "title": "zsh"])
    case "list":
      write(connection, ["type": "error", "requestId": requestId!, "code": "terminal_not_found", "message": "no such session"])
    case "input":
      received.append(message)
      write(connection, ["type": "data", "terminalId": "t1", "data": "echo:\(message["data"] as! String)"])
    case "close":
      received.append(message)
      write(connection, ["type": "exit", "terminalId": "t1", "exitCode": 0])
    case "silent":
      break
    default:
      received.append(message)
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

print("PASS: LAN terminal key, framing, events, commands; loopback hello, open/attach replay, input, close, refusal, machine and key checks")
