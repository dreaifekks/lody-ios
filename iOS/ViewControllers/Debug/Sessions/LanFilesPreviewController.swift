import CryptoKit
import UIKit

/// Offline production chat/picker/gallery/Quick Look with injected byte providers.
/// No LAN credential, runtime, member, or Cloud request is involved.
@MainActor
final class LanFilesPreviewController: UIViewController {
  private let chat = LodyChatView(frame: .zero)
  private let status = UILabel()
  private let controls = UIStackView()
  private let root = FileManager.default.temporaryDirectory.appendingPathComponent("lan-files-preview-\(UUID().uuidString)")
  private lazy var cache = LanImageCache(directory: root.appendingPathComponent("cache"))
  private var user = "offline-user"
  private var identity: String { AttachmentIdentity.key(userId: user, workspaceId: "lw_offline-files", lanId: "offline-hub") }
  private var runtimeEpoch = 1
  private var memberOnline = true
  private var prepares = 0
  private var editSends = 0
  private var fetches = 0
  private var reads = 0
  private var restores = 0
  private var completed = 0
  private let scenario: String

  init(scenario: String = "media") {
    self.scenario = scenario
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError() }
  isolated deinit { try? FileManager.default.removeItem(at: root) }

  override func viewDidLoad() {
    super.viewDidLoad()
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let imageURL = root.appendingPathComponent("photo.png")
    let bytes = UIGraphicsImageRenderer(size: CGSize(width: 480, height: 320)).pngData { context in
      UIColor.lodySignal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 480, height: 320))
      ("LAN picture" as NSString).draw(at: CGPoint(x: 36, y: 120), withAttributes: [.font: UIFont.systemFont(ofSize: 36), .foregroundColor: UIColor.white])
    }
    try! bytes.write(to: imageURL)
    let notes = root.appendingPathComponent("notes.txt")
    try! Data("LAN draft attachment\n".utf8).write(to: notes)
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    chat.usesLAN = { true }
    chat.keptImages = ChatKeptImageService(file: { [weak self] image, _, _ in
      guard let self, let digest = image.sha256 else { throw CancellationError() }
      let scope = identity, epoch = runtimeEpoch
      return try await cache.file(digest: digest, scope: scope, epoch: String(epoch), isCurrent: { [weak self] in
        self?.identity == scope && self?.runtimeEpoch == epoch
      }) { [weak self] directory in
        guard let self else { throw CancellationError() }
        fetches += 1; updateStatus()
        guard memberOnline else { throw SessionAttachments.error("Offline member unavailable") }
        // Intentionally allow a late result so the production scope fence is exercised.
        try? await Task.sleep(for: .milliseconds(scenario == "late" ? 6000 : 400))
        if scenario == "recovery", fetches <= 2 {
          runtimeEpoch += 1; updateStatus()
          throw SessionAttachments.error("Offline runtime replaced. Retry the picture.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(image.fileName)
        try bytes.write(to: url)
        completed += 1; updateStatus()
        return url
      }
    }, identity: { [weak self] in self?.identity ?? "closed" })
    chat.attachmentLoader = { [weak self] _, _, _, directory in
      guard let self else { throw CancellationError() }
      reads += 1; updateStatus()
      try? await Task.sleep(for: .milliseconds(400))
      if scenario == "recovery", reads == 1 { runtimeEpoch += 1; updateStatus() }
      if reads == 1 { throw SessionAttachments.error("Offline member unavailable. Retry this file.") }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent("notes.txt")
      try FileManager.default.copyItem(at: notes, to: url)
      return url
    }
    chat.onEditMessage = { [weak self] _ in self?.openEditor(notes: notes, image: imageURL) }
    chat.editableMessageID = "lan-user"
    chat.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(chat)
    chat.setAttachmentContext(SessionController.json(["workspaceId": "lw_offline-files", "sessionId": "offline-files"]))
    chat.setComposerState(SessionController.json(["editable": true, "canSend": true, "sending": false, "notice": "", "reconnect": false, "placeholder": "LAN draft"]))
    let attachments = [["id": "draft-file", "name": "notes.txt", "uri": notes.absoluteString, "kind": "file"]]
    chat.setInitialDraft("Retain LAN text and file")
    chat.setInitialAttachments(String(decoding: try! JSONSerialization.data(withJSONObject: attachments), as: UTF8.self))
    chat.onSend = { [weak self] _ in
      guard let self else { return }
      let scope = identity
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(400))
        guard let self, identity == scope else { return }
        restores += 1
        chat.restoreDraft(token: restores)
        updateStatus()
      }
    }
    func file(_ id: String, _ name: String, _ mime: String) -> [String: Any] {
      ["id": id, "fileName": name, "transport": "local", "machineId": "offline-desk", "sha256": digest,
        "sizeBytes": bytes.count, "mimeType": mime, "storageSessionId": "kept-storage"]
    }
    let entries: [[String: Any]] = [
      ["id": "lan-user", "role": "user", "status": "completed", "finished": true, "items": [
        ["itemId": "photo", "type": "file", "file": file("photo-1", "photo.png", "image/png")],
        ["itemId": "notes", "type": "file", "file": file("notes", "notes.txt", "text/plain")],
        ["itemId": "text", "type": "text", "text": "Kept LAN attachments"]]],
      ["id": "lan-agent", "role": "assistant", "status": "completed", "finished": true, "items": [
        ["itemId": "photo", "type": "file", "file": file("photo-2", "renamed.jpg", "image/png")]]],
    ]
    chat.setEntries(String(decoding: try! JSONSerialization.data(withJSONObject: entries), as: UTF8.self))
    status.accessibilityIdentifier = "lan-files-status"
    status.isAccessibilityElement = true
    status.font = .preferredFont(forTextStyle: .caption1)
    status.numberOfLines = 2
    controls.axis = .vertical
    controls.spacing = 0
    controls.addArrangedSubview(status)
    let actions = UIStackView()
    actions.axis = .horizontal
    actions.distribution = .fillEqually
    actions.spacing = 8
    controls.addArrangedSubview(actions)
    let switchAccount = UIButton(type: .system)
    switchAccount.setTitle("Switch account", for: .normal)
    switchAccount.accessibilityIdentifier = "lan-files-switch"
    switchAccount.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      user = UUID().uuidString
      chat.setEntries("[]")
      chat.scheduleUpdate()
      chat.setComposerState(SessionController.json(["editable": false, "canSend": false, "sending": false, "notice": "", "reconnect": false, "placeholder": "LAN draft"]))
      updateStatus()
    }, for: .touchUpInside)
    actions.addArrangedSubview(switchAccount)
    let edit = UIButton(type: .system)
    edit.setTitle("Edit", for: .normal)
    edit.accessibilityIdentifier = "lan-files-edit"
    edit.addAction(UIAction { [weak self] _ in self?.openEditor(notes: notes, image: imageURL) }, for: .touchUpInside)
    actions.addArrangedSubview(edit)
    let recover = UIButton(type: .system)
    recover.setTitle("Recover", for: .normal)
    recover.accessibilityIdentifier = "lan-files-recover"
    recover.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      runtimeEpoch += 1; memberOnline = false; updateStatus()
    }, for: .touchUpInside)
    actions.addArrangedSubview(recover)
    controls.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(controls)
    NSLayoutConstraint.activate([
      controls.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      status.heightAnchor.constraint(equalToConstant: 44),
      actions.heightAnchor.constraint(equalToConstant: 44),
      chat.topAnchor.constraint(equalTo: controls.bottomAnchor),
      chat.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      chat.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      chat.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    updateStatus()
  }

  private func openEditor(notes: URL, image: URL) {
    let service = EditMessageService(
      prepare: { [weak self] _ in
        guard let self else { throw CancellationError() }
        prepares += 1
        if scenario == "recovery", prepares == 1 {
          try await Task.sleep(for: .milliseconds(400))
          runtimeEpoch += 1; updateStatus()
          throw SessionAttachments.error("Offline runtime replaced during edit preparation")
        }
        return EditMessageDraft(state: "ready", text: "Edit this LAN prompt", attachments: [
          .init(id: "original:0", name: "notes.txt", uri: notes.absoluteString, kind: "file"),
          .init(id: "original:1", name: "photo.png", uri: image.absoluteString, kind: "image"),
        ])
      },
      send: { [weak self] _, _, _ in
        guard let self else { throw CancellationError() }
        editSends += 1
        try await Task.sleep(for: .milliseconds(400))
        if scenario == "recovery" {
          runtimeEpoch += 1; updateStatus()
          return .unknown(.init())
        }
        return .notSent(.init(reason: "Offline member unavailable"))
      },
      read: { [weak self] _ in
        guard let self else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(400))
        runtimeEpoch += 1; updateStatus()
        throw SessionAttachments.error("Offline runtime replaced during edit confirmation")
      },
      usesLAN: { true },
      identity: { [weak self] in self?.identity ?? "closed" }
    )
    let editor = EditMessageController(sessionId: "offline-files", entryId: "lan-user", service: service)
    LodyShell.shared.present(editor, title: String(localized: "chat.edit.title", bundle: .lody), dismissible: false, style: "fullScreen")
  }

  private func updateStatus() {
    status.text = "\(fetches) image fetch; \(reads) file reads; \(restores) restored; \(completed) finished; epoch \(runtimeEpoch); \(editSends) edit sends"
  }
}
