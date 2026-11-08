import ImageIO
import MarkdownParser
import MarkdownView
import os
import UIKit

/// Public HTTP image I/O is confined to an ephemeral URLProtocol, with no account.
@MainActor
final class RemoteImagesPreviewController: UIViewController {
  private let probe = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
  private let imageSession: URLSession
  private var timer: Timer?
  private var check: Task<Void, Never>?
  private var blockedCloudReference = false
  private weak var sharePage: MessageShareController?
  private weak var gallery: ImagePreviewController?
  private let urls = ["http://offline-image.invalid/picture.png", "https://offline-image.invalid/picture.png"]
  private var content: ChatMessageShare {
    .init(parts: [.init(text: "# Public images\n\n![HTTP picture](\(urls[0]))\n\n![HTTPS picture](\(urls[1]))")],
      model: "Offline model", workspace: "lw_offline_images", session: "offline-session")
  }

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RemoteImageProtocol.self]
    imageSession = URLSession(configuration: configuration)
    RemoteImageProtocol.calls.withLock { $0 = [] }
    super.init(nibName: nil, bundle: nil)
    title = "External images"
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  isolated deinit { timer?.invalidate(); check?.cancel(); imageSession.invalidateAndCancel() }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    let controls = UIStackView()
    controls.axis = .vertical; controls.spacing = 16; controls.translatesAutoresizingMaskIntoConstraints = false
    let actions: [(String, String, @MainActor () -> Void)] = [
      ("remote-images-share", "Generate share image", { [weak self] in self?.openShare() }),
      ("remote-images-gallery", "Preview Markdown image", { [weak self] in self?.openGallery() }),
    ]
    for (id, name, action) in actions {
      let button = UIButton(type: .system)
      button.setTitle(name, for: .normal); button.accessibilityIdentifier = id
      button.addAction(UIAction { _ in action() }, for: .touchUpInside)
      button.heightAnchor.constraint(equalToConstant: 44).isActive = true
      controls.addArrangedSubview(button)
    }
    view.addSubview(controls)
    NSLayoutConstraint.activate([
      controls.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
      controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
    ])
    probe.isAccessibilityElement = true; probe.accessibilityIdentifier = "remote-images-probe"
    check = Task { @MainActor [weak self] in
      guard let self else { return }
      let image = ChatImage(id: "protected-ref", fileName: "Cloud.png", storageSessionId: nil, width: nil, height: nil)
      let cloud = ChatMessageShare(parts: [.init(image: image)], model: "", workspace: "lw_offline_images", session: "offline-session")
      do { _ = try await ChatSharePaper.make(cloud, imageSession: imageSession) }
      catch { blockedCloudReference = (error as? ChatSharePaper.Failure) == .image }
      updateProbe()
    }
    timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.updateProbe() }
    }
    updateProbe()
  }

  private func openShare() {
    let json = String(decoding: try! JSONEncoder().encode(content), as: UTF8.self)
    let page = MessageShareController(contentJSON: json, imageSession: imageSession)
    sharePage = page
    LodyShell.shared.present(page, title: page.title ?? "", detents: [1], grabber: true)
  }

  private func openGallery() {
    var source = ""
    _ = MarkdownParser().parse(content.text).document.rewrite { (node: MarkdownInlineNode) -> [MarkdownInlineNode] in
      if case let .image(url, _) = node { source = url }
      return [node]
    }
    let item = ChatImagePreviewItem(id: "public-picture",
      image: .init(id: "public-picture", fileName: "Markdown picture", storageSessionId: nil, width: nil, height: nil),
      localURI: nil, remoteURL: URL(string: source)!)
    gallery = ImagePreviewController.present(from: self, items: [item], index: 0,
      workspace: "lw_offline_images", session: "offline-session", placeholders: [:], sourceView: { _ in nil }, imageSession: imageSession)
  }

  private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
  private func updateProbe() {
    var host: UIViewController = self
    var kind = "fixture"
    if let page = sharePage, page.viewIfLoaded?.window != nil { host = page; kind = "share" }
    if let page = gallery, page.viewIfLoaded?.window != nil { host = page; kind = "gallery" }
    if probe.superview !== host.view { host.view.addSubview(probe) }
    let children = descendants(host.view)
    let paper = children.compactMap { $0 as? UIImageView }.first { $0.accessibilityIdentifier == "message-share-preview" }
    let loaded = children.compactMap { $0 as? ChatImagePreviewPage }.contains { $0.photo.image != nil }
    let calls = RemoteImageProtocol.calls.withLock { $0 }
    probe.accessibilityValue = SessionController.json(["host": kind, "paperReady": paper?.image != nil,
      "galleryReady": loaded, "cloudReferenceBlocked": blockedCloudReference,
      "requests": calls.map { ["url": $0.url, "authorized": $0.authorized] }])
  }
}

private final class RemoteImageProtocol: URLProtocol, @unchecked Sendable {
  struct Call: Sendable { let url: String; let authorized: Bool }
  static let calls = OSAllocatedUnfairLock(initialState: [Call]())
  private static let bitmap: Data = {
    let context = CGContext(data: nil, width: 360, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.25, green: 0.31, blue: 0.72, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 360, height: 240))
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fillEllipse(in: CGRect(x: 130, y: 70, width: 100, height: 100))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination))
    return data as Data
  }()
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "offline-image.invalid" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let authorized = request.value(forHTTPHeaderField: "Authorization") != nil
    Self.calls.withLock { $0.append(.init(url: request.url!.absoluteString, authorized: authorized)) }
    if authorized { client?.urlProtocol(self, didFailWithError: CocoaError(.fileReadNoPermission)); return }
    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
      headerFields: ["Content-Type": "image/png", "Content-Length": String(Self.bitmap.count)])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Self.bitmap)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
