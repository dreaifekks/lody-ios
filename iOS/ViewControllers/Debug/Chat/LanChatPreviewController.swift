import UIKit

/// Credential-free chat projections rendered by the production transcript.
@MainActor
final class LanChatPreviewController: UIViewController {
  private let chat = LodyChatView(frame: .zero)

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
    chat.setEntries(SessionController.json(entries), animate: false)
    chat.scheduleUpdate()
  }
}
