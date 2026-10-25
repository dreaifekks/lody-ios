import Foundation
import Network

// swiftc -swift-version 6 ../../ios/LodyStrings.swift ../../ios/Auth/LanInvite.swift \
//   ../../ios/LanTerminal/LanTerminalLink.swift ../../ios/LanTerminal/LanFileChannel.swift \
//   ../../ios/LanTerminal/LanSimulator.swift main.swift -o /tmp/lan-simulator && /tmp/lan-simulator
// A local TLS-PSK member answers like Lody's `serveLanControlConnection`
// (`lan/ios-simulator`) and `serveTunnelRequest` (`lan-tunnel.ts`); a plain
// HTTP server stands in for the viewer the member serves on its loopback.

func check(_ condition: Bool, _ message: @autoclosure () -> String = "", line: Int = #line) {
  if !condition {
    FileHandle.standardError.write(Data("FAIL line \(line): \(message())\n".utf8))
    exit(1)
  }
}

let invite = try LanInvite.parse("lody-lan://test-Token_0@127.0.0.1:8788/Home")
let key = LanTerminalProtocol.key(token: invite.token)
let machineId = "member-under-test"

final class Locked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { stored = value }
  var value: Value {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
}

/// A loopback socket bound to a port the system picks; listening keeps the port taken.
func bound(listening: Bool) -> (fd: Int32, port: UInt16) {
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  var address = sockaddr_in()
  address.sin_family = sa_family_t(AF_INET)
  address.sin_addr.s_addr = inet_addr("127.0.0.1")
  var length = socklen_t(MemoryLayout<sockaddr_in>.size)
  _ = withUnsafeMutablePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
  }
  if listening { listen(fd, 1) }
  return (fd, UInt16(bigEndian: address.sin_port))
}

func freePort() -> UInt16 {
  let (fd, port) = bound(listening: false)
  close(fd)
  return port
}

/// The viewer of the member: answers each request with the Host it saw, then closes.
final class Viewer: @unchecked Sendable {
  let listener: NWListener
  let requests = Locked<[String]>([])

  init() throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters)
    listener.newConnectionHandler = { [unowned self] connection in
      connection.start(queue: .global())
      self.read(connection, Data())
    }
  }

  func start() -> UInt16 {
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    listener.start(queue: .global())
    _ = ready.wait(timeout: .now() + 5)
    return listener.port!.rawValue
  }

  func read(_ connection: NWConnection, _ received: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [unowned self] content, _, _, _ in
      let all = received + (content ?? Data())
      guard let end = all.range(of: Data("\r\n\r\n".utf8)) else { return self.read(connection, all) }
      let head = String(decoding: all[..<end.lowerBound], as: UTF8.self)
      self.requests.value.append(head)
      let host = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("host:") } ?? ""
      let body = "viewer saw \(host)"
      let response = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
      connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
                      completion: .contentProcessed { _ in })
    }
  }
}

final class Member: @unchecked Sendable {
  let listener: NWListener
  let queue = DispatchQueue(label: "member")
  let requests = Locked<[[String: Any]]>([])
  let tunnels = Locked<[[String: Any]]>([])
  /// Answers every hello as a build from before services did.
  let terminalOnly = Locked(false)
  /// What each session's `status` reports, by session.
  let viewers = Locked<[String: String]>([:])
  /// The member's viewer ports and where the fixture actually serves them.
  let carried = Locked<[Int: UInt16]>([:])

  init() throws {
    let tls = NWProtocolTLS.Options()
    let security = tls.securityProtocolOptions
    sec_protocol_options_add_pre_shared_key(
      security,
      key.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData,
      Data(invite.id.utf8).withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
    )
    sec_protocol_options_append_tls_ciphersuite(security, tls_ciphersuite_t(rawValue: LanTerminalProtocol.cipherSuite)!)
    sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
    sec_protocol_options_set_max_tls_protocol_version(security, .TLSv12)
    listener = try NWListener(using: NWParameters(tls: tls), on: .any)
    listener.newConnectionHandler = { [unowned self] connection in
      connection.start(queue: self.queue)
      self.lines(connection, Data(), service: nil)
    }
  }

  func start() -> UInt16 {
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    listener.start(queue: queue)
    _ = ready.wait(timeout: .now() + 5)
    return listener.port!.rawValue
  }

  func write(_ connection: NWConnection, _ value: [String: Any], end: Bool = false) {
    var data = try! JSONSerialization.data(withJSONObject: value)
    data.append(0x0A)
    connection.send(content: data, completion: .contentProcessed { _ in if end { connection.cancel() } })
  }

  func lines(_ connection: NWConnection, _ buffer: Data, service: String?) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [unowned self] content, _, complete, _ in
      var buffer = buffer + (content ?? Data())
      var service = service
      while let newline = buffer.firstIndex(of: 0x0A) {
        let line = Data(buffer[buffer.startIndex..<newline])
        buffer = Data(buffer[buffer.index(after: newline)...])
        let message = try! JSONSerialization.jsonObject(with: line) as! [String: Any]
        if service == nil {
          service = message["service"] as? String ?? "terminal"
          write(connection, ["type": "hello", "version": 1, "machineId": machineId,
                             "service": terminalOnly.value ? "terminal" : service!])
        } else if service == "control" {
          return control(connection, message)
        } else if service == "tunnel" {
          return tunnel(connection, message, rest: buffer)
        }
      }
      if !complete { lines(connection, buffer, service: service) }
    }
  }

  func control(_ connection: NWConnection, _ request: [String: Any]) {
    requests.value.append(request)
    let sessionId = request["sessionId"] as! String
    let command = request["command"] as! [String: Any]
    guard request["workspaceId"] as? String == invite.workspaceId, sessionId != "foreign" else {
      return write(connection, ["ok": false, "type": "lan/ios-simulator", "error": "workspace_not_found",
                                "message": "This connection belongs to another LAN"], end: true)
    }
    var result: [String: Any] = ["type": "ios-simulator/control_response", "sessionId": sessionId, "success": true]
    func preview(_ phase: String, viewer: String? = nil) -> [String: Any] {
      var value: [String: Any] = ["operationId": "op-\(sessionId)", "udid": "4C4B5E0B-6A1E-4C69-9D3E-2B1B3D1C0A11",
                                  "phase": phase, "transport": "local"]
      value["viewerUrl"] = viewer
      return value
    }
    switch (sessionId, command["action"] as? String) {
    case ("archived", _):
      result = ["type": "ios-simulator/control_response", "sessionId": sessionId, "success": false,
                "error": "denied", "message": "This session cannot control the simulator."]
    case (_, "list"):
      // Exterior art makes an answer far longer than a files answer.
      result["devices"] = [["udid": "4C4B5E0B-6A1E-4C69-9D3E-2B1B3D1C0A11", "name": "iPhone 18 Pro",
                            "runtime": "iOS 27.0", "deviceType": "iPhone 18 Pro", "state": "Shutdown",
                            "available": true, "occupancy": "available"]]
      result["exterior"] = ["pngBase64": String(repeating: "A", count: 300_000)]
    case (_, "start"):
      result["preview"] = preview("preparing")
    case (_, "status"):
      if let viewer = viewers.value[sessionId] {
        result["preview"] = preview("ready", viewer: viewer)
      } else {
        result["preview"] = preview("closed")
      }
    case (_, "stop"):
      viewers.value[sessionId] = nil
      result["preview"] = preview("closed")
    default:
      result["success"] = false
    }
    write(connection, ["ok": true, "type": "lan/ios-simulator", "result": result], end: true)
  }

  func tunnel(_ connection: NWConnection, _ request: [String: Any], rest: Data) {
    tunnels.value.append(request)
    guard let port = request["port"] as? Int, let actual = carried.value[port] else {
      return write(connection, ["type": "error", "message": "nothing listens on port \(request["port"] ?? "")"], end: true)
    }
    let upstream = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: actual)!, using: .tcp)
    upstream.stateUpdateHandler = { [unowned self] state in
      guard case .ready = state else { return }
      self.write(connection, ["type": "connected"])
      if !rest.isEmpty { upstream.send(content: rest, completion: .contentProcessed { _ in }) }
      self.pipe(connection, upstream)
      self.pipe(upstream, connection)
    }
    upstream.start(queue: queue)
  }

  func pipe(_ from: NWConnection, _ to: NWConnection) {
    from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [unowned self] content, _, complete, error in
      if let content, !content.isEmpty { to.send(content: content, completion: .contentProcessed { _ in }) }
      if complete || error != nil {
        to.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
      } else {
        self.pipe(from, to)
      }
    }
  }
}

func get(_ port: UInt16, origin: Bool = true) async -> String? {
  var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/simulator/abc/?__lody_preview_token=t")!, timeoutInterval: 8)
  if origin { request.setValue("http://127.0.0.1:\(port)", forHTTPHeaderField: "Origin") }
  guard let (data, response) = try? await URLSession(configuration: .ephemeral).data(for: request),
        (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
  return String(decoding: data, as: UTF8.self)
}

let viewer = try Viewer()
let viewerPort = viewer.start()
let member = try Member()
let target = LanSimulator.Target(endpoint: LanTerminalEndpoint(host: "127.0.0.1", port: member.start()), machineId: machineId)
let ports = LanSimulatorPorts()

func control(_ session: String, _ command: [String: Any]) async -> [String: Any] {
  await LanSimulator.control(invite: invite, target: target, sessionId: session, command: command, ports: ports)
}

// The request names the member, the LAN's workspace and user; a long answer arrives whole.
let listed = await control("s1", ["action": "list"])
check(listed["success"] as? Bool == true && (listed["devices"] as? [Any])?.count == 1, "\(listed.keys)")
let sent = member.requests.value.last!
check(sent["type"] as? String == "lan/ios-simulator" && sent["machineId"] as? String == machineId
      && sent["workspaceId"] as? String == invite.workspaceId && sent["requestedByUserId"] as? String == invite.userId
      && sent["sessionId"] as? String == "s1" && (sent["command"] as? [String: Any])?["action"] as? String == "list", "\(sent)")

// Starting carries nothing yet; a ready viewer is carried to the same port of this device.
let started = await control("s1", ["action": "start", "udid": "4C4B5E0B-6A1E-4C69-9D3E-2B1B3D1C0A11"])
check((started["preview"] as? [String: Any])?["phase"] as? String == "preparing", "\(started)")
check(await ports.port(of: "s1") == nil)
let carried = freePort()
member.carried.value[Int(carried)] = viewerPort
member.viewers.value["s1"] = "http://127.0.0.1:\(carried)/simulator/abc/?__lody_preview_token=t"
let ready = await control("s1", ["action": "status", "operationId": "op-s1"])
check((ready["preview"] as? [String: Any])?["viewerUrl"] as? String == member.viewers.value["s1"], "\(ready)")
check(await ports.port(of: "s1") == carried)
// Each connection opens its own tunnel and the viewer sees the address it serves.
async let first = get(carried)
async let second = get(carried)
let pages = await [first, second]
check(pages.allSatisfy { $0 == "viewer saw Host: 127.0.0.1:\(carried)" }, "\(pages)")
check(member.tunnels.value.count == 2 && member.tunnels.value.allSatisfy {
  $0["type"] as? String == "connect" && $0["port"] as? Int == Int(carried) && $0["host"] as? String == "127.0.0.1"
}, "\(member.tunnels.value)")
// Polling the same viewer keeps the port.
_ = await control("s1", ["action": "status", "operationId": "op-s1"])
check(await ports.port(of: "s1") == carried)
check(await get(carried) != nil)

// A port the member cannot carry ends the connection instead of hanging it.
let unknown = freePort()
member.viewers.value["s2"] = "http://127.0.0.1:\(unknown)/simulator/abc/?__lody_preview_token=t"
_ = await control("s2", ["action": "status"])
check(await ports.port(of: "s2") == unknown)
let started2 = Date()
check(await get(unknown) == nil)
check(Date().timeIntervalSince(started2) < 6)

// A viewer port taken on this device stops the operation and asks for a new start.
let taken = bound(listening: true)
let takenPort = taken.port
member.viewers.value["s3"] = "http://127.0.0.1:\(takenPort)/simulator/abc/?__lody_preview_token=t"
let busy = await control("s3", ["action": "status"])
check(busy["success"] as? Bool == false && busy["message"] as? String == "native.simulator.lan.portBusy", "\(busy)")
check(await ports.port(of: "s3") == nil)
let stopCommand = member.requests.value.last!["command"] as? [String: Any]
check(stopCommand?["action"] as? String == "stop" && stopCommand?["operationId"] as? String == "op-s3", "\(String(describing: stopCommand))")
close(taken.fd)

// An operation that ended releases its port; a stop does too.
member.viewers.value["s2"] = nil
let closed = await control("s2", ["action": "status"])
check((closed["preview"] as? [String: Any])?["phase"] as? String == "closed")
check(await ports.port(of: "s2") == nil)
let stopped = await control("s1", ["action": "stop", "operationId": "op-s1"])
check(stopped["success"] as? Bool == true, "\(stopped)")
check(await ports.port(of: "s1") == nil)
check(await get(carried) == nil)

// The member's refusals come back as failures; an archived session's denial passes through.
let denied = await control("archived", ["action": "list"])
check(denied["success"] as? Bool == false && denied["error"] as? String == "denied", "\(denied)")
let foreign = await control("foreign", ["action": "list"])
check(foreign["success"] as? Bool == false && foreign["message"] as? String == "This connection belongs to another LAN", "\(foreign)")
member.terminalOnly.value = true
let old = await control("s1", ["action": "list"])
check(old["success"] as? Bool == false && (old["message"] as? String ?? "").contains("serves no control"), "\(old)")
member.terminalOnly.value = false

// Logging out ends every carried port.
member.viewers.value["s4"] = "http://127.0.0.1:\(carried)/simulator/abc/?__lody_preview_token=t"
_ = await control("s4", ["action": "status"])
check(await ports.port(of: "s4") == carried)
check(await get(carried) != nil)
await ports.closeAll()
check(await ports.port(of: "s4") == nil)
check(await get(carried) == nil)

// Nothing listens at the endpoint: the command fails instead of waiting.
member.listener.cancel()
try await Task.sleep(for: .milliseconds(300))
let unreachable = await control("s1", ["action": "list"])
check(unreachable["success"] as? Bool == false, "\(unreachable)")

print("PASS: LAN simulator control request and long answer, same-port viewer tunnels, unknown and taken ports, release on stop/closed/logout, refusals")
