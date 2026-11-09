import Foundation

/// Two catalog machines, only one with a current heartbeat. Project ownership,
/// names and activity intentionally produce different machine orders by sort.
@MainActor
enum HomeMachineFixture {
  static let preview = #"{"v":1,"status":"live","revision":1,"entries":[{"id":"machine-user","role":"user","status":"completed","finished":true,"items":[{"itemId":"t","type":"text","text":"LAN cached preview"}]},{"id":"machine-answer","role":"assistant","status":"completed","finished":true,"items":[{"itemId":"answer","type":"text","text":"Local history is available."}]}]}"#

  static var catalog: [String: Any] {
    let now = Date().timeIntervalSince1970 * 1000
    return [
      "machineIds": ["machine-z", "machine-a"],
      "machineNames": ["machine-z": "Zulu Studio", "machine-a": "Alpha Mac"],
      "projects": [
        ["id": "machine-atlas", "name": "Atlas", "machineId": "machine-z", "rootPath": "/tmp/atlas"],
        ["id": "machine-boreal", "name": "Boreal", "machineId": "machine-a", "rootPath": "/tmp/boreal"],
        ["id": "machine-cedar", "name": "Cedar", "machineId": "machine-a", "rootPath": "/tmp/cedar"],
      ],
      "sessions": [
        session("atlas-session", title: "Atlas latest", project: "machine-atlas", machine: "machine-z", at: now - 5_000),
        session("boreal-session", title: "Boreal needs input", project: "machine-boreal", machine: "machine-a", at: now - 20_000, status: "waiting"),
        session("cedar-session", title: "Cedar complete", project: "machine-cedar", machine: "machine-a", at: now - 40_000),
      ],
    ]
  }

  private static func session(_ id: String, title: String, project: String, machine: String, at: Double, status: String = "completed") -> [String: Any] {
    ["id": id, "title": title, "projectId": project, "machineId": machine, "status": status,
      "createdAt": "2026-01-01T00:00:00Z", "lastMessageAt": at, "lastReadAt": at]
  }
}
