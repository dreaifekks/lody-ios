import CryptoKit
import Foundation
import Network

// swiftc -swift-version 6 ../../ios/LanTerminal/LanTerminalLink.swift ../../ios/LanTerminal/LanFileChannel.swift main.swift -o /tmp/lan-files && /tmp/lan-files
// A local TLS-PSK listener answers like Lody's `serveLanFileConnection`
// (`lan-files.ts`): a header, `ready`, the counted bytes, `stored`; or `read`,
// `content` and the bytes.

func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "", line: Int = #line) {
  if !condition() {
    FileHandle.standardError.write(Data("FAIL line \(line): \(message())\n".utf8))
    exit(1)
  }
}

func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

// Header names stay one path segment; capabilities follow `machineSupportsLanFiles`.
check(LanFileProtocol.headerFileName("../a/b\\photo.jpg") == "photo.jpg")
check(LanFileProtocol.headerFileName(" \u{1}x.txt ") == "_x.txt", LanFileProtocol.headerFileName(" \u{1}x.txt "))
check(LanFileProtocol.headerFileName("..") == "file" && LanFileProtocol.headerFileName("a/") == "a")
check(LanFileProtocol.supported(["lanFiles": 1]) && LanFileProtocol.supported(["lanFiles": 2]))
check(!LanFileProtocol.supported(["lanFiles": 0]) && !LanFileProtocol.supported(["lanControl": 1]) && !LanFileProtocol.supported(nil))

// MARK: Loopback member

let key = LanTerminalProtocol.key(token: "test-token")
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

final class Member: @unchecked Sendable {
  let listener: NWListener
  let queue = DispatchQueue(label: "member")
  /// Answers every hello as a build from before services did.
  var terminalOnly = false
  /// Names another machine in the stored block.
  var lie = false
  var kept: [String: Data] = [:]
  var headers: [[String: Any]] = []

  final class Peer: @unchecked Sendable {
    var buffer = Data()
    var pending: (header: [String: Any], size: Int)?
  }

  init() throws {
    listener = try NWListener(using: NWParameters(tls: tlsOptions()), on: .any)
    listener.newConnectionHandler = { [unowned self] connection in
      connection.start(queue: self.queue)
      self.read(connection, Peer())
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

  func read(_ connection: NWConnection, _ peer: Peer) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [unowned self] content, _, complete, _ in
      peer.buffer.append(content ?? Data())
      self.drain(connection, peer)
      if !complete { self.read(connection, peer) }
    }
  }

  func drain(_ connection: NWConnection, _ peer: Peer) {
    while true {
      if let pending = peer.pending {
        guard peer.buffer.count >= pending.size else { return }
        let bytes = Data(peer.buffer.prefix(pending.size))
        peer.buffer = Data(peer.buffer.dropFirst(pending.size))
        peer.pending = nil
        store(connection, pending.header, bytes)
        continue
      }
      guard let newline = peer.buffer.firstIndex(of: 0x0A) else { return }
      let line = Data(peer.buffer[peer.buffer.startIndex..<newline])
      peer.buffer = Data(peer.buffer[peer.buffer.index(after: newline)...])
      let message = try! JSONSerialization.jsonObject(with: line) as! [String: Any]
      answer(connection, peer, message)
    }
  }

  func answer(_ connection: NWConnection, _ peer: Peer, _ message: [String: Any]) {
    switch message["type"] as? String {
    case "hello":
      write(connection, ["type": "hello", "version": 1, "machineId": machineId,
                         "service": terminalOnly ? "terminal" : message["service"] as? String ?? "terminal"])
    case "file":
      headers.append(message)
      if message["sessionId"] as? String == "archived" {
        write(connection, ["type": "error", "code": "session_archived", "message": "session_archived:archived"], end: true)
        return
      }
      peer.pending = (message, message["sizeBytes"] as! Int)
      write(connection, ["type": "ready"])
    case "read":
      let fileId = message["fileId"] as! String
      if fileId == "damaged" {
        write(connection, ["type": "content", "sizeBytes": 4])
        connection.send(content: Data("evil".utf8), completion: .contentProcessed { _ in })
      } else if let bytes = kept[fileId] {
        write(connection, ["type": "content", "sizeBytes": bytes.count])
        connection.send(content: bytes, completion: .contentProcessed { _ in })
      } else {
        write(connection, ["type": "error", "code": "file_not_found", "message": "file_not_found:this machine does not keep \(fileId)"], end: true)
      }
    default:
      write(connection, ["type": "error", "code": "invalid_request", "message": "invalid_request:unknown"], end: true)
    }
  }

  func store(_ connection: NWConnection, _ header: [String: Any], _ bytes: Data) {
    guard hex(bytes) == header["sha256"] as? String else {
      write(connection, ["type": "error", "code": "invalid_file", "message": "invalid_file:the file arrived damaged"], end: true)
      return
    }
    let fileId = "file-\(kept.count + 1)"
    kept[fileId] = bytes
    let name = header["fileName"] as! String
    write(connection, ["type": "stored", "file": [
      "type": "file", "fileId": fileId, "fileName": name,
      "mimeType": name.hasSuffix(".jpg") ? "image/jpeg" : "application/octet-stream",
      "sizeBytes": bytes.count, "sha256": hex(bytes), "textPreview": false,
      "transport": "local", "machineId": lie ? "someone-else" : machineId, "uploadedAt": 1,
    ] as [String: Any]])
  }
}

let member = try Member()
let port = member.start()
let endpoint = LanTerminalEndpoint(host: "127.0.0.1", port: port)
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lan-files-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }

func channel(key: Data = key, machine: String = machineId) -> LanFileChannel {
  LanFileChannel(endpoint: endpoint, lanId: lanId, key: key, machineId: machine)
}

func failure(_ body: () async throws -> Void) async -> LanFileChannel.Failure? {
  do { try await body(); return nil } catch let failure as LanFileChannel.Failure { return failure } catch {
    return LanFileChannel.Failure(code: "other", message: "\(error)")
  }
}

// Two files over one connection, the second larger than one write.
let photo = directory.appendingPathComponent("photo.jpg")
let photoBytes = Data((0..<700_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
try photoBytes.write(to: photo)
let notes = directory.appendingPathComponent("notes.txt")
try Data("hello from the phone\n".utf8).write(to: notes)
let sender = channel()
try await sender.open()
final class Flag: @unchecked Sendable { var value = false }
let progress = Flag()
let first = try await sender.send(file: notes, fileName: "notes.txt", sessionId: "s1")
let second = try await sender.send(file: photo, fileName: "dir/photo.jpg", sessionId: "s1") { sent, total in
  if sent == total { progress.value = true }
}
sender.close()
check(first["fileId"] as? String == "file-1" && first["transport"] as? String == "local", "\(first)")
check(second["machineId"] as? String == machineId && second["sizeBytes"] as? Int == photoBytes.count, "\(second)")
check(second["mimeType"] as? String == "image/jpeg" && progress.value, "\(second)")
check(member.kept["file-2"] == photoBytes)
check(member.headers.map { $0["fileName"] as? String } == ["notes.txt", "photo.jpg"], "\(member.headers)")
check(member.headers[1]["sha256"] as? String == hex(photoBytes))

// The file comes back intact on a fresh connection.
let reader = channel()
try await reader.open()
let fetched = directory.appendingPathComponent("fetched.jpg")
try await reader.read(sessionId: "s1", fileId: "file-2", sizeBytes: photoBytes.count, sha256: hex(photoBytes), to: fetched)
reader.close()
let fetchedBytes = try Data(contentsOf: fetched)
check(fetchedBytes == photoBytes)

// Damaged bytes are refused and removed; a missing file is the member's refusal.
let damaged = directory.appendingPathComponent("damaged")
let broken = await failure {
  let link = channel(); defer { link.close() }
  try await link.open()
  try await link.read(sessionId: "s1", fileId: "damaged", sizeBytes: 4, sha256: hex(Data("good".utf8)), to: damaged)
}
check(broken?.code == "invalid_file" && !FileManager.default.fileExists(atPath: damaged.path), "\(String(describing: broken))")
let missing = await failure {
  let link = channel(); defer { link.close() }
  try await link.open()
  try await link.read(sessionId: "s1", fileId: "nope", sizeBytes: 4, sha256: hex(Data("good".utf8)), to: directory.appendingPathComponent("missing"))
}
check(missing == .init(code: "file_not_found", message: "this machine does not keep nope"), "\(String(describing: missing))")

// A refusal before the bytes travel keeps its code and drops the repeated prefix.
let archived = await failure {
  let link = channel(); defer { link.close() }
  try await link.open()
  _ = try await link.send(file: notes, fileName: "notes.txt", sessionId: "archived")
}
check(archived == .init(code: "session_archived", message: "archived"), "\(String(describing: archived))")

// A block naming another machine is not the file that was sent.
member.lie = true
let lied = await failure {
  let link = channel(); defer { link.close() }
  try await link.open()
  _ = try await link.send(file: notes, fileName: "notes.txt", sessionId: "s1")
}
check(lied?.code == "remote_unreachable", "\(String(describing: lied))")
member.lie = false

// A build that knows terminals only, another machine, or another key: no files.
member.terminalOnly = true
let old = await failure { let link = channel(); defer { link.close() }; try await link.open() }
check(old?.message == "the machine serves no files; update it", "\(String(describing: old))")
member.terminalOnly = false
let other = await failure { let link = channel(machine: "someone-else"); defer { link.close() }; try await link.open() }
check(other?.message == "another machine answered", "\(String(describing: other))")
let stranger = await failure { let link = channel(key: LanTerminalProtocol.key(token: "other")); defer { link.close() }; try await link.open() }
check(stranger != nil, "a wrong key must not connect")

// Nothing listens: the channel fails instead of waiting.
member.listener.cancel()
try await Task.sleep(for: .milliseconds(300))
let gone = await failure { let link = channel(); defer { link.close() }; try await link.open() }
check(gone?.code == "remote_unreachable", "\(String(describing: gone))")

print("PASS: LAN files header names, capability, loopback send of two files on one connection, read back, damaged and missing reads, refusal, foreign block, old build, machine and key checks, unreachable member")
