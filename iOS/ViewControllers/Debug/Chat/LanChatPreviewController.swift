import UIKit

/// Credential-free chat projections rendered by the production transcript.
@MainActor
final class LanChatPreviewController: UIViewController {
  private let chat = LodyChatView(frame: .zero)
  private let board: Bool

  init(board: Bool = false) {
    self.board = board
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    chat.usesLAN = { true }
    chat.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(chat)
    NSLayoutConstraint.activate([
      chat.topAnchor.constraint(equalTo: view.topAnchor),
      chat.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      chat.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      chat.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    let entries: [[String: Any]] = [
      ["id": "delegated", "role": "user", "status": "completed", "finished": true,
       "author": ["kind": "agent", "name": "Planner", "role": ["name": "iosDev", "instanceLabel": "Mini"], "model": "GPT"],
       "items": [["itemId": "text", "type": "text", "text": "Check the native chat layout."]]],
      ["id": "human", "role": "user", "status": "completed", "finished": true,
       "items": [["itemId": "text", "type": "text", "text": "A message without an author stays unchanged."]]],
    ]
    chat.setEntries(SessionController.json(board ? Self.boardEntries : entries), animate: false)
    chat.scheduleUpdate()
  }
  private static let boardEntries: [[String: Any]] = [
    ["id": "results", "role": "system", "status": "completed", "finished": true, "items": [
      ["itemId": "batch", "type": "operation_completion_batch", "memberCount": 2, "members": [
        ["title": "Layout check", "status": "succeeded"], ["title": "Wire check", "status": "failed"]]],
      ["itemId": "single", "type": "operation_completion", "memberCount": 1, "deliveryStatus": "unknown", "members": [
        ["title": "Agent reply", "status": "waiting_user"]]]]],
    ["id": "maintenance", "role": "system", "status": "completed", "finished": true, "items": [
      ["itemId": "compact", "type": "system_notice", "name": "board_context_maintenance", "meta": ["kind": "compact", "status": "done", "trigger": "manual"]],
      ["itemId": "limit", "type": "system_notice", "name": "board_chain_limit"]]],
    ["id": "proposal", "role": "system", "status": "completed", "finished": true, "items": [
      ["itemId": "role", "type": "system_notice", "name": "agent_role_proposal", "meta": [
        "command": ["action": "update", "patch": ["description": "Review native chat", "promptPrefix": "Use UIKit."]],
        "before": ["name": "iosDev"], "outcome": "saved"]]]],
    ["id": "idle", "role": "system", "status": "completed", "finished": true, "items": [
      ["itemId": "hidden", "type": "system_notice", "name": "board_context_maintenance", "meta": ["kind": "compact", "status": "interrupted", "trigger": "idle"]]]],
  ]
}
