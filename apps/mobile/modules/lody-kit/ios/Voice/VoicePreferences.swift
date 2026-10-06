import Foundation

/// Experimental voice dictation, off unless the user turns it on in Settings.
/// The agent is this device's own choice; without one the workspace's applies.
enum VoicePreferences {
  static let didChange = Notification.Name("LodyVoicePreferencesDidChange")
  private static let enabledKey = "voiceDictation"
  private static let agentKey = "voiceDictationAgent"

  static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

  static var agent: [String: String]? {
    guard let value = UserDefaults.standard.dictionary(forKey: agentKey) as? [String: String],
          value["configId"]?.isEmpty == false, value["machineId"]?.isEmpty == false else { return nil }
    return value
  }

  static var json: String {
    var value: [String: Any] = ["enabled": enabled]
    if let agent { value["agent"] = agent }
    let data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
  }

  static func save(enabled: Bool, configId: String, machineId: String) {
    UserDefaults.standard.set(enabled, forKey: enabledKey)
    if configId.isEmpty || machineId.isEmpty {
      UserDefaults.standard.removeObject(forKey: agentKey)
    } else {
      UserDefaults.standard.set(["configId": configId, "machineId": machineId], forKey: agentKey)
    }
    NotificationCenter.default.post(name: didChange, object: nil)
  }
}
