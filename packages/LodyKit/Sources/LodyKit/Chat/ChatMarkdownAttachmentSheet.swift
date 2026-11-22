import UIKit

@MainActor
final class ChatMarkdownAttachmentSheet: UIViewController {
  private let file: ChatMessageAttachment
  private let workspace: String
  private let session: String
  private let localURL: URL?
  private let directory = ContentPreview.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
  private var url: URL?
  private var download: Task<Void, Never>?
  private var document: LodyMarkdownDocumentView?
  private lazy var save = UIBarButtonItem(
    image: UIImage(systemName: "arrow.down.circle"),
    primaryAction: UIAction { [weak self] _ in self?.saveFile() }
  )
  private lazy var share = UIBarButtonItem(
    image: UIImage(systemName: "square.and.arrow.up"),
    primaryAction: UIAction { [weak self] _ in self?.shareFile() }
  )

  static func handles(_ file: ChatMessageAttachment) -> Bool {
    ContentStore.classify(path: file.fileName, binary: false, mimeType: nil) == "markdown"
  }

  static func present(file: ChatMessageAttachment, localURL: URL?, workspace: String, session: String, from controller: UIViewController) {
    let sheet = ChatMarkdownAttachmentSheet(file: file, localURL: localURL, workspace: workspace, session: session)
    let navigation = UINavigationController(rootViewController: sheet)
    navigation.modalPresentationStyle = .pageSheet
    if let presentation = navigation.sheetPresentationController {
      presentation.detents = [.medium(), .large()]
      presentation.selectedDetentIdentifier = .large
      presentation.prefersGrabberVisible = true
      presentation.prefersScrollingExpandsWhenScrolledToEdge = true
    }
    controller.present(navigation, animated: true)
  }

  private init(file: ChatMessageAttachment, localURL: URL?, workspace: String, session: String) {
    self.file = file
    self.localURL = localURL
    self.workspace = workspace
    self.session = file.storageSessionId ?? session
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .lodyBackground
    title = file.fileName
    navigationItem.largeTitleDisplayMode = .never
    let close = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
      self?.dismiss(animated: true)
    })
    close.accessibilityLabel = String(localized: "native.close", bundle: .lody)
    navigationItem.leftBarButtonItem = close
    save.accessibilityLabel = String(localized: "native.attachment.markdown.save", bundle: .lody)
    save.accessibilityIdentifier = "markdown-attachment-save"
    share.accessibilityLabel = String(localized: "pr.share", bundle: .lody)
    share.accessibilityIdentifier = "markdown-attachment-share"
    navigationItem.rightBarButtonItems = [share, save]
    load()
  }

  private func load() {
    download?.cancel()
    setActions(enabled: false)
    var loading = LodyEmptyConfiguration()
    loading.loading = true
    loading.text = String(localized: "native.attachment.preview.loading", bundle: .lody)
    loading.backgroundColor = .lodyBackground
    lodyContentUnavailable = loading
    download = Task { [weak self, file, workspace, session, directory, localURL] in
      do {
        let url: URL
        if let localURL {
          url = localURL
        } else {
          guard file.transport == nil || file.transport == "r2" else {
            throw SessionAttachments.error(String(localized: "native.attachment.error.pending", bundle: .lody))
          }
          url = try await SessionAttachments.download(workspace: workspace, session: session, fileId: file.id,
            fileName: file.fileName, sizeBytes: file.sizeBytes, directory: directory)
        }
        let data = try Data(contentsOf: url)
        guard String(data: data, encoding: .utf8) != nil else {
          throw SessionAttachments.error(String(localized: "native.attachment.error.download", bundle: .lody))
        }
        try Task.checkCancellation()
        guard let self else { try? FileManager.default.removeItem(at: directory); return }
        self.show(url: url, data: data)
      } catch {
        try? FileManager.default.removeItem(at: directory)
        guard !Task.isCancelled, let self else { return }
        self.fail(error.localizedDescription)
      }
    }
  }

  private func show(url: URL, data: Data) {
    self.url = url
    lodyContentUnavailable = nil
    document?.removeFromSuperview()
    let handle = ContentStore.shared.put(StoredContent(data: data, kind: "markdown", path: file.fileName, session: session, mimeType: nil))
    let next = LodyMarkdownDocumentView(frame: view.bounds)
    next.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    next.failed = { [weak self] in
      guard let self, let url = self.url, let data = try? Data(contentsOf: url) else { return }
      self.show(url: url, data: data)
    }
    next.setHandle(handle)
    view.addSubview(next)
    document = next
    setActions(enabled: true)
  }

  private func fail(_ message: String) {
    document?.removeFromSuperview()
    document = nil
    var failed = LodyEmptyConfiguration()
    failed.backgroundColor = .lodyBackground
    failed.image = UIImage(systemName: "doc.badge.ellipsis")
    failed.text = file.fileName
    failed.secondaryText = message
    if localURL != nil || file.transport != "local" {
      failed.button.title = String(localized: "native.attachment.preview.retry", bundle: .lody)
      failed.buttonAction = { [weak self] in self?.load() }
    }
    lodyContentUnavailable = failed
  }

  private func setActions(enabled: Bool) {
    save.isEnabled = enabled
    share.isEnabled = enabled
  }

  private func saveFile() {
    guard let url, presentedViewController == nil else { return }
    let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    present(picker, animated: true)
  }

  private func shareFile() {
    guard let url, presentedViewController == nil else { return }
    let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    sheet.popoverPresentationController?.barButtonItem = share
    present(sheet, animated: true)
  }

  deinit {
    download?.cancel()
    try? FileManager.default.removeItem(at: directory)
  }
}
