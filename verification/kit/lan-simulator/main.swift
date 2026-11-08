import Foundation
import Network
import Darwin
import LodyCore

// Live routing dependencies only. Transport and session store below are production sources.
@MainActor final class DataRuntime {
  static var current: DataRuntime?
  var workspace: String?
  var userId = ""
  var generation = 1
  var lan: LanInvite?
  var simulatorClients: [WeakLanSimulator] = []
  var cloudCalls = 0
  func perform(_ call: RuntimeContract.Calls.IosSimulatorControl.Type,
               _ params: RuntimeContract.IosSimulatorControlParams) async throws -> SimulatorService.Reply {
    cloudCalls += 1
    return .init(success: true, devices: [])
  }
}
enum OutboxError: Error { case scopeExpired }
@MainActor final class AuthSession {
  static let shared = AuthSession()
  struct User { var id: String }
  struct LAN { var id: String }
  struct Account { var user: User; var lan: LAN? }
  struct Snapshot { var account: Account? }
  var snapshot = Snapshot()
}


func check(_ value: @autoclosure () -> Bool, _ message: String = "check failed", line: Int = #line) {
  precondition(value(), "line \(line): \(message)")
}

let invite = LanInvite(url: "http://127.0.0.1:8788", token: "simulator-loopback-test-token", name: nil)
let machineId = "member-mac"

final class Member: @unchecked Sendable {
  let queue = DispatchQueue(label: "sim-member")
  let listener: NWListener
  var commands: [String] = []
  var tunnelPorts: [Int] = []
  var hosts: [String] = []
  var viewerPort = 0
  var phase = "ready"
  var delay = false
  var pending: [(NWConnection, [String: Any])] = []
  var connections: [NWConnection] = []

  final class Peer: @unchecked Sendable {
    var buffer = Data()
    var tunnel = false
  }

  init() throws {
    let tls = NWProtocolTLS.Options()
    let security = tls.securityProtocolOptions
    let key = LanTerminalProtocol.key(token: invite.token)
    sec_protocol_options_add_pre_shared_key(security,
      key.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData,
      Data(invite.id.utf8).withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData)
    sec_protocol_options_append_tls_ciphersuite(security, tls_ciphersuite_t(rawValue: LanTerminalProtocol.cipherSuite)!)
    sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
    sec_protocol_options_set_max_tls_protocol_version(security, .TLSv12)
    sec_protocol_options_set_tls_resumption_enabled(security, false)
    let parameters = NWParameters(tls: tls)
    parameters.requiredInterfaceType = .loopback
    listener = try NWListener(using: parameters, on: .any)
    listener.newConnectionHandler = { [unowned self] connection in
      connections.append(connection)
      connection.start(queue: queue)
      read(connection, Peer())
    }
  }

  func start() -> UInt16 {
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    listener.start(queue: queue)
    check(ready.wait(timeout: .now() + 5) == .success)
    return listener.port!.rawValue
  }

  func line(_ c: NWConnection, _ value: [String: Any]) {
    var data = try! JSONSerialization.data(withJSONObject: value); data.append(10)
    c.send(content: data, completion: .contentProcessed { _ in })
  }

  func read(_ c: NWConnection, _ peer: Peer) {
    c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] bytes, _, complete, error in
      peer.buffer.append(bytes ?? Data())
      if peer.tunnel {
        if let text = String(data: peer.buffer, encoding: .utf8), text.contains("\r\n\r\n") {
          check(text.contains("Host: 127.0.0.1:\(viewerPort)"), text)
          check(text.contains("Origin: http://127.0.0.1:\(viewerPort)"), text)
          hosts.append(text)
          // Keep a large response flowing after the request half-closes.
          let body = String(repeating: "viewer-byte-", count: 30000)
          c.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8),
            contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
          peer.buffer = Data()
        }
      } else {
        while let newline = peer.buffer.firstIndex(of: 10) {
          let data = Data(peer.buffer.prefix(upTo: newline)); peer.buffer.removeSubrange(...newline)
          let value = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
          switch value["type"] as? String {
          case "hello":
            check(value["machineId"] as? String == machineId)
            line(c, ["type": "hello", "version": 1, "machineId": machineId, "service": value["service"]!])
          case "lan/ios-simulator":
            check(value["workspaceId"] as? String == invite.workspaceId)
            check(value["requestedByUserId"] as? String == invite.userId)
            check(value["machineId"] as? String == machineId && value["sessionId"] as? String == "session")
            let action = (value["command"] as! [String: Any])["action"] as! String
            commands.append(action)
            if delay { pending.append((c, value)) } else { answer(c, value) }
          case "connect":
            check(value["host"] as? String == "127.0.0.1")
            tunnelPorts.append(value["port"] as! Int)
            line(c, ["type": "connected"]); peer.tunnel = true
          default: preconditionFailure("unexpected \(value)")
          }
        }
      }
      if error == nil && !complete { read(c, peer) }
    }
  }

  func answer(_ c: NWConnection, _ value: [String: Any]) {
    let action = (value["command"] as! [String: Any])["action"] as! String
    var result: [String: Any] = ["success": true]
    if action == "list" { result["devices"] = [["udid": "phone", "name": "Phone", "runtime": "iOS", "deviceType": "iPhone", "state": "Booted", "available": true, "occupancy": "available"]] }
    else if action != "stop" {
      result["preview"] = ["operationId": "operation", "udid": "phone", "phase": phase,
        "transport": "local", "viewerUrl": "http://127.0.0.1:\(viewerPort)/?token=fixture"]
    }
    line(c, ["ok": true, "type": "lan/ios-simulator", "result": result])
  }

  func flush() {
    queue.sync {
      delay = false
      for (c, value) in pending { answer(c, value) }
      pending.removeAll()
    }
  }

  func count() -> Int { queue.sync { commands.count } }
  func close() { queue.sync { connections.forEach { $0.cancel() }; listener.cancel() } }
}

// Reserve and release an available loopback port, without a second Simulator.
func freePort() throws -> UInt16 {
  let l = try NWListener(using: .tcp, on: .any)
  let ready = DispatchSemaphore(value: 0)
  l.newConnectionHandler = { $0.cancel() }
  l.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
  l.start(queue: DispatchQueue(label: "free-port"))
  check(ready.wait(timeout: .now() + 5) == .success)
  let port = l.port!.rawValue; l.cancel(); return port
}

func http(_ port: UInt16) async throws -> Data {
  try await Task.detached {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.init(rawValue: errno)!) }
    defer { Darwin.close(fd) }
    var timeout = timeval(tv_sec: 8, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var noSignal: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard connected == 0 else { throw POSIXError(.init(rawValue: errno)!) }
    let request = Data("GET /?token=fixture HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nOrigin: http://127.0.0.1:\(port)\r\n\r\n".utf8)
    let sent = request.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
    check(sent == request.count)
    Darwin.shutdown(fd, SHUT_WR)
    var result = Data(), buffer = [UInt8](repeating: 0, count: 65536)
    while true {
      let count = Darwin.recv(fd, &buffer, buffer.count, 0)
      if count == 0 { return result }
      guard count > 0 else { throw POSIXError(.init(rawValue: errno)!) }
      result.append(contentsOf: buffer.prefix(count))
    }
  }.value
}

let member = try Member()
let memberPort = member.start()
let target = LanSimulator.Target(endpoint: .init(host: "127.0.0.1", port: memberPort), machineId: machineId)
let viewerPort = try freePort()
member.viewerPort = Int(viewerPort)
let client = LanSimulator()
let runtime = DataRuntime()
runtime.workspace = invite.workspaceId; runtime.userId = invite.userId; runtime.lan = invite
DataRuntime.current = runtime
AuthSession.shared.snapshot.account = .init(user: .init(id: invite.userId), lan: .init(id: invite.id))
var routedTarget = target
let live = SimulatorService.live(workspaceId: invite.workspaceId, userId: invite.userId, sessionId: "session", target: { (routedTarget.endpoint, routedTarget.machineId) })
_ = try await live.call(.list(.init()))
check(runtime.cloudCalls == 0)
runtime.lan = nil
do { _ = try await live.call(.list(.init())); preconditionFailure("missing LAN credential used Cloud") } catch {}
check(runtime.cloudCalls == 0)
runtime.lan = invite
let routedStore = SessionSimulator(sessionId: "session", service: live)
let adopted = try await routedStore.resume()
check(adopted && !routedStore.sourceJSON.isEmpty)
let beforeReuse = member.count()
check(live.canReuse())
check(member.count() == beforeReuse, "ready reuse sent a control RPC")
let movedMember = try Member()
let movedPort = movedMember.start()
movedMember.viewerPort = Int(viewerPort)
let movedTarget = LanSimulator.Target(endpoint: .init(host: "127.0.0.1", port: movedPort), machineId: machineId)
routedTarget = movedTarget
check(live.canReuse())
let movedReply = try await http(viewerPort)
check(movedReply.count == 360043)
check(movedMember.tunnelPorts == [Int(viewerPort)] && movedMember.commands.isEmpty, "ready address update rebound or called control")
routedTarget = target
check(live.canReuse())
// DataRuntime disposal releases this registered client, clearing the visible projection too.
runtime.simulatorClients.forEach { $0.value?.release() }; runtime.simulatorClients.removeAll()
check(routedStore.sourceJSON.isEmpty && routedStore.phase == "closed")
check(!live.canReuse())
member.queue.sync { member.delay = true }
let accountBefore = member.count()
let accountLate = Task { try await live.call(.status(.init())) }
while member.count() == accountBefore { await Task.yield() }
AuthSession.shared.snapshot.account = nil
member.flush()
do { _ = try await accountLate.value; preconditionFailure("expired account accepted a preview") } catch {}
try await Task.sleep(for: .milliseconds(100))
do { _ = try await http(viewerPort); preconditionFailure("expired account retained tunnel") } catch {}

let cloud = DataRuntime(); cloud.workspace = "cloud-workspace"; cloud.userId = "cloud-user"
DataRuntime.current = cloud
AuthSession.shared.snapshot.account = .init(user: .init(id: "cloud-user"), lan: nil)
_ = try await SimulatorService.live(workspaceId: "cloud-workspace", userId: "cloud-user", sessionId: "session").call(.list(.init()))
check(cloud.cloudCalls == 1)
DataRuntime.current = runtime
AuthSession.shared.snapshot.account = .init(user: .init(id: invite.userId), lan: .init(id: invite.id))
let listed = try await client.control(invite: invite, target: target, sessionId: "session", command: .list(.init()))
check(listed.devices?.first?.udid == "phone")
let started = try await client.control(invite: invite, target: target, sessionId: "session", command: .start(.init(udid: "phone")))
check(started.preview?.viewerUrl == "http://127.0.0.1:\(viewerPort)/?token=fixture")
let bytes = try await http(viewerPort)
let expectedBody = String(repeating: "viewer-byte-", count: 30000)
let expected = Data("HTTP/1.1 200 OK\r\nContent-Length: \(expectedBody.utf8.count)\r\n\r\n\(expectedBody)".utf8)
check(bytes == expected, "half-close changed response: \(bytes.count)")
check(member.tunnelPorts == [Int(viewerPort)])
_ = try await client.control(invite: invite, target: movedTarget, sessionId: "session", command: .status(.init()))
let relocated = try await http(viewerPort)
check(relocated == expected && movedMember.commands == ["status"] && movedMember.tunnelPorts == [Int(viewerPort), Int(viewerPort)], "control reused the old member address or stopped the operation")
_ = try await client.control(invite: invite, target: target, sessionId: "session", command: .status(.init()))
_ = try await client.control(invite: invite, target: target, sessionId: "session", command: .stop(.init(operationId: "operation")))
try await Task.sleep(for: .milliseconds(100))
do { _ = try await http(viewerPort); preconditionFailure("stop retained port") } catch {}

// Late control result after page/runtime/account release must never bind.
member.queue.sync { member.delay = true }
let before = member.count()
let late = Task { try await client.control(invite: invite, target: target, sessionId: "session", command: .status(.init())) }
while member.count() == before { await Task.yield() }
client.release(); member.flush()
do { _ = try await late.value; preconditionFailure("stale reply accepted") } catch {}
do { _ = try await http(viewerPort); preconditionFailure("stale reply opened port") } catch {}

// Failed operation closes its port even when the response still carries a URL.
_ = try await client.control(invite: invite, target: target, sessionId: "session", command: .status(.init()))
member.queue.sync { member.phase = "failed" }
_ = try await client.control(invite: invite, target: target, sessionId: "session", command: .status(.init()))
try await Task.sleep(for: .milliseconds(100))
do { _ = try await http(viewerPort); preconditionFailure("failed operation retained port") } catch {}

// A release racing a listener that has not started cancels its continuation.
let pendingForward = LanPortForward(machineId: machineId, port: try freePort()) {
  LanTerminalProtocol.connection(to: target.endpoint, lanId: invite.id, key: LanTerminalProtocol.key(token: invite.token))
}
pendingForward.close()
do { try await pendingForward.start(); preconditionFailure("released listener restarted") } catch {}

// Occupied local same-number port stops the member operation, never boots/shuts down a simulator here.
member.queue.sync { member.phase = "ready" }
let blocker = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: viewerPort)!)
let ready = DispatchSemaphore(value: 0)
blocker.newConnectionHandler = { $0.cancel() }
blocker.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
blocker.start(queue: DispatchQueue(label: "occupied"))
check(ready.wait(timeout: .now() + 5) == .success)
do { _ = try await client.control(invite: invite, target: target, sessionId: "session", command: .status(.init())); preconditionFailure("occupied port accepted") } catch {}
check(member.commands.last == "stop")
do { _ = try await client.control(invite: invite, target: target, sessionId: "session", command: .status(.init())); preconditionFailure("repeated occupied port accepted") } catch {}
check(member.commands.suffix(2) == ["status", "stop"])
blocker.cancel()
try await Task.sleep(for: .milliseconds(150))
_ = try await client.control(invite: invite, target: target, sessionId: "session", command: .status(.init()))
let recoveredBytes = try await http(viewerPort)
check(recoveredBytes == expected, "repeated bind failure left stale forward")
client.release(); member.close(); movedMember.close()

let json = Data(#"{"catalog":{"projects":[],"sessions":[{"id":"s","machineId":"mac"}],"machineIds":["mac"],"machineSimulators":{"mac":"available"},"machineLanSimulators":{"mac":"upgrade-required"},"machineTerminals":{"mac":{"host":"127.0.0.1","port":8789}}}}"#.utf8)
var catalog = SessionCatalog.decode(saved: json)!
var session = catalog.sessions[0]
check(catalog.simulatorAvailability(for: session, lan: true) == "upgrade-required")
catalog.machineLanSimulators["mac"] = "available"
check(catalog.simulatorAvailability(for: session, lan: true) == "available")
check(catalog.simulatorAvailability(for: session, lan: false) == "available")
session.archived = true
check(catalog.simulatorAvailability(for: session, lan: true) == nil)
session.archived = false; catalog.machineTerminals = [:]
check(catalog.simulatorAvailability(for: session, lan: true) == nil)
print("PASS: TLS-PSK control identity/list/start/status/stop; same-port HTTP tunnel and half-close; release/late response; pre-bind release; address relocation without rebind; ready reuse without RPC; failed phase; occupied-port stop; LAN catalog availability")
