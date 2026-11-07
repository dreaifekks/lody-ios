import CryptoKit
import Foundation
import Network

/// Where a LAN member accepts terminal connections, as published in its
/// machine metadata. The address is not a secret; the LAN credential opens it.
struct LanTerminalEndpoint: Sendable, Equatable {
  let host: String
  let port: UInt16
}

/// Lody's LAN member protocol (`lan-terminal.ts`): TLS 1.2 with a pre-shared
/// key derived from the LAN credential, one JSON line of hello each way, then
/// newline-delimited service messages.
enum LanTerminalProtocol {
  static let version = 1
  static let handshakeTimeout: TimeInterval = 10
  /// `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256`, the one suite Node and Electron share.
  static let cipherSuite: UInt16 = 0xCCAC

  /// Mirrors `deriveLanTerminalKey`: the raw SHA-256 of the scoped credential.
  static func key(token: String) -> Data {
    Data(SHA256.hash(data: Data("lody-lan-hub:terminal:\(token)".utf8)))
  }

  /// A connection to any service of a member; the hello names the service.
  static func connection(to endpoint: LanTerminalEndpoint, lanId: String, key: Data) -> NWConnection {
    let tls = NWProtocolTLS.Options()
    let security = tls.securityProtocolOptions
    let psk = key.withUnsafeBytes { DispatchData(bytes: $0) }
    let identity = Data(lanId.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
    sec_protocol_options_add_pre_shared_key(security, psk as __DispatchData, identity as __DispatchData)
    if let suite = tls_ciphersuite_t(rawValue: cipherSuite) {
      sec_protocol_options_append_tls_ciphersuite(security, suite)
    }
    sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
    sec_protocol_options_set_max_tls_protocol_version(security, .TLSv12)
    // Every connection proves the current credential; a cached session would skip the key.
    sec_protocol_options_set_tls_resumption_enabled(security, false)
    let tcp = NWProtocolTCP.Options()
    tcp.enableKeepalive = true
    tcp.keepaliveIdle = 30
    tcp.connectionTimeout = Int(handshakeTimeout)
    return NWConnection(
      host: NWEndpoint.Host(endpoint.host),
      port: NWEndpoint.Port(rawValue: endpoint.port) ?? 8789,
      using: NWParameters(tls: tls, tcp: tcp)
    )
  }
}
