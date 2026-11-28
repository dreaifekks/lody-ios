import AVFoundation
import AVKit
import UIKit

/// System video player (`AVPlayerViewController`) for conversation video attachments.
/// Reuses `SessionAttachments.download` for remote files and plays local URLs directly.
@MainActor
final class SessionVideoPreviewController: UIViewController {
  private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm", "mkv", "avi", "ogv"]

  private let file: ChatMessageAttachment
  private let localURL: URL?
  private let workspace: String
  private let session: String
  private let directory = ContentPreview.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
  private var downloadedURL: URL?
  private var download: Task<Void, Never>?
  private var fixtureAttempt = 0
  private var playerController: AVPlayerViewController?
  private var statusObservation: NSKeyValueObservation?
  private lazy var shareButton = UIBarButtonItem(
    image: UIImage(systemName: "square.and.arrow.up"),
    primaryAction: UIAction { [weak self] _ in self?.shareFile() }
  )

  static func handles(_ file: ChatMessageAttachment) -> Bool {
    if let mime = file.mimeType?.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
       mime.hasPrefix("video/") {
      return true
    }
    let ext = (file.fileName as NSString).pathExtension.lowercased()
    return videoExtensions.contains(ext)
  }

  static func present(
    file: ChatMessageAttachment,
    localURL: URL?,
    workspace: String,
    session: String,
    from controller: UIViewController
  ) {
    let preview = SessionVideoPreviewController(file: file, localURL: localURL, workspace: workspace, session: session)
    let navigation = UINavigationController(rootViewController: preview)
    navigation.modalPresentationStyle = .fullScreen
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
    view.accessibilityIdentifier = "session-video-preview"
    title = file.fileName
    navigationItem.largeTitleDisplayMode = .never
    let close = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
      self?.dismiss(animated: true)
    })
    close.accessibilityLabel = String(localized: "native.close", bundle: .lody)
    navigationItem.leftBarButtonItem = close
    shareButton.accessibilityLabel = String(localized: "pr.share", bundle: .lody)
    shareButton.isEnabled = false
    navigationItem.rightBarButtonItem = shareButton
    load()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    playerController?.player?.pause()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed || navigationController?.isBeingDismissed == true {
      cleanup()
    }
  }

  deinit {
    download?.cancel()
    try? FileManager.default.removeItem(at: directory)
  }

  private func load() {
    download?.cancel()
    teardownPlayer()
    shareButton.isEnabled = false

    if let localURL {
      downloadedURL = localURL
      shareButton.isEnabled = true
      mountPlayer(url: localURL)
      return
    }

    var loading = LodyEmptyConfiguration()
    loading.loading = true
    loading.text = String(localized: "native.attachment.preview.loading", bundle: .lody)
    loading.backgroundColor = .lodyBackground
    lodyContentUnavailable = loading

    fixtureAttempt += 1
    let attempt = fixtureAttempt
    download = Task { [weak self, file, workspace, session, directory] in
      do {
        guard file.transport == nil || file.transport == "r2" else {
          throw SessionAttachments.error(String(localized: "native.attachment.error.pending", bundle: .lody))
        }
        let url: URL
        if LodyUIVerify.enabled, session == "ui-verify-attachments" {
          try await Task.sleep(for: .milliseconds(file.id == "cancel" ? 4000 : 400))
          url = try FilePreviewFixture.attachment(file.id, attempt: attempt, directory: directory)
        } else {
          url = try await SessionAttachments.download(
            workspace: workspace,
            session: session,
            fileId: file.id,
            fileName: file.fileName,
            sizeBytes: file.sizeBytes,
            directory: directory
          )
        }
        try Task.checkCancellation()
        guard let self else {
          try? FileManager.default.removeItem(at: directory)
          return
        }
        self.downloadedURL = url
        self.shareButton.isEnabled = true
        self.lodyContentUnavailable = nil
        self.mountPlayer(url: url)
      } catch {
        try? FileManager.default.removeItem(at: directory)
        guard !Task.isCancelled, let self else { return }
        self.showError(message: error.localizedDescription, canRetry: file.transport != "local", canShare: false)
      }
    }
  }

  private func mountPlayer(url: URL) {
    teardownPlayer()
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    try? AVAudioSession.sharedInstance().setActive(true)

    let item = AVPlayerItem(url: url)
    let player = AVPlayer(playerItem: item)
    let controller = AVPlayerViewController()
    controller.player = player
    controller.showsPlaybackControls = true
    controller.allowsPictureInPicturePlayback = true

    addChild(controller)
    controller.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(controller.view)
    NSLayoutConstraint.activate([
      controller.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    controller.didMove(toParent: self)
    playerController = controller

    statusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
      guard observed.status == .failed else { return }
      let message = observed.error?.localizedDescription ?? String(localized: "native.attachment.error.download", bundle: .lody)
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.teardownPlayer()
        self.showError(message: message, canRetry: false, canShare: self.downloadedURL != nil)
      }
    }

    player.play()
  }

  private func showError(message: String, canRetry: Bool, canShare: Bool) {
    var failed = LodyEmptyConfiguration()
    failed.backgroundColor = .lodyBackground
    failed.image = UIImage(systemName: "film")
    failed.text = file.fileName
    failed.secondaryText = message
    if canRetry {
      failed.button.title = String(localized: "native.attachment.preview.retry", bundle: .lody)
      failed.buttonAction = { [weak self] in self?.load() }
    } else if canShare {
      failed.button.title = String(localized: "pr.share", bundle: .lody)
      failed.buttonAction = { [weak self] in self?.shareFile() }
    }
    failed.secondaryButton.title = String(localized: "native.close", bundle: .lody)
    failed.secondaryButtonAction = { [weak self] in self?.dismiss(animated: true) }
    lodyContentUnavailable = failed
  }

  private func shareFile() {
    guard let url = downloadedURL else { return }
    let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    sheet.popoverPresentationController?.barButtonItem = shareButton
    present(sheet, animated: true)
  }

  private func teardownPlayer() {
    statusObservation?.invalidate()
    statusObservation = nil
    guard let controller = playerController else { return }
    controller.player?.pause()
    controller.player = nil
    controller.willMove(toParent: nil)
    controller.view.removeFromSuperview()
    controller.removeFromParent()
    playerController = nil
  }

  private func cleanup() {
    download?.cancel()
    download = nil
    teardownPlayer()
    if localURL == nil {
      try? FileManager.default.removeItem(at: directory)
    }
  }
}
