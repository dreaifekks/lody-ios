import ImageIO
import Litext
import os
import UIKit

/// The transcript opens its own gallery; only URLSession returns scripted image bytes.
@MainActor
final class RemoteImagesPreviewController: UIViewController {
  private let chat = LodyChatView(frame: .zero)
  private let probe = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
  private let imageSession: URLSession
  private var timer: Timer?
  private var check: Task<Void, Never>?
  private var blockedCloudReference = false
  private weak var sharePage: MessageShareController?
  private var openedLinks: [String] = []
  private var openedFiles: [String] = []
  private let urls = ["http://offline-image.invalid/picture.png", "https://offline-image.invalid/picture.png"]
  private var content: ChatMessageShare {
    .init(parts: [.init(text: "![HTTP picture](\(urls[0]))\n\n[Same image address](\(urls[0]))\n\n[Local file](docs/README.md)\n\n![HTTPS picture](\(urls[1]))\n\n`![Literal picture](\(urls[1]))`")],
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
    let share = UIButton(type: .system)
    share.setTitle("Generate share image", for: .normal)
    share.accessibilityIdentifier = "remote-images-share"
    share.translatesAutoresizingMaskIntoConstraints = false
    share.addAction(UIAction { [weak self] _ in self?.openShare() }, for: .touchUpInside)
    chat.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(share); view.addSubview(chat)
    NSLayoutConstraint.activate([
      share.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
      share.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      share.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      share.heightAnchor.constraint(equalToConstant: 44),
      chat.topAnchor.constraint(equalTo: share.bottomAnchor, constant: 12),
      chat.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      chat.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      chat.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    chat.usesLAN = { true }
    chat.imageWorkspace = "lw_offline_images"; chat.imageSession = "offline-session"
    chat.imageURLSession = imageSession
    chat.setComposerState(SessionController.json(["editable": false, "canSend": false, "sending": false,
      "notice": "", "reconnect": false, "placeholder": "", "quotaLocked": true]))
    chat.onLinkPress = { [weak self] in self?.openedLinks.append($0) }
    chat.onFilePress = { [weak self] body in
      if let path = body["path"] as? String { self?.openedFiles.append(path) }
    }
    let entries: [[String: Any]] = [
      ["id": "remote-images", "role": "assistant", "status": "completed", "finished": true, "items": [
        ["itemId": "answer", "type": "text", "text": content.text],
        ["itemId": "plan", "type": "proposed_plan", "status": "completed", "isLatest": false,
         "markdown": "![Plan picture](\(urls[1]))"]]],
    ]
    let data = try! JSONSerialization.data(withJSONObject: entries)
    chat.setEntries(String(decoding: data, as: UTF8.self), animate: false)
    chat.scheduleUpdate()
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

  private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
  private func updateProbe() {
    var host: UIViewController = self
    var kind = "fixture"
    if let page = sharePage, page.viewIfLoaded?.window != nil { host = page; kind = "share" }
    if let page = chat.imagePreview, page.viewIfLoaded?.window != nil { host = page; kind = "gallery" }
    if probe.superview !== host.view { host.view.addSubview(probe) }
    let children = descendants(host.view)
    let paper = children.compactMap { $0 as? UIImageView }.first { $0.accessibilityIdentifier == "message-share-preview" }
    let loaded = children.compactMap { $0 as? ChatImagePreviewPage }.contains { $0.photo.image != nil }
    var targets: [[String: Any]] = []
    var code: [[String: Double]] = []
    var fileIcon: [String: Double] = [:]
    func rowID(_ view: UIView) -> String {
      var parent: UIView? = view
      while let node = parent {
        if let id = node.accessibilityIdentifier, id.hasPrefix("remote-images:") { return id }
        parent = node.superview
      }
      return ""
    }
    for view in descendants(chat) {
      if let button = view as? UIButton, button.accessibilityLabel == "README.md", let window = button.window {
        let frame = button.convert(button.bounds, to: window)
        if frame.width > 0, frame.height > 0, window.bounds.contains(CGPoint(x: frame.midX, y: frame.midY)) {
          fileIcon = ["x": frame.midX, "y": frame.midY]
        }
      }
      guard let label = view as? TextLabelView, let window = label.window else { continue }
      let text = label.attributedText
      text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
        let href: String
        if let value = value as? String { href = value }
        else if let value = value as? URL { href = value.absoluteString }
        else { return }
        let image = text.attribute(FileMarkdownView.imageSource, at: range.location, effectiveRange: nil) != nil
        for box in label.textLayout.rects(for: range) {
          let rect = label.convert(label.viewRect(fromLayoutRect: box), to: window)
          guard window.bounds.contains(CGPoint(x: rect.midX, y: rect.midY)), rect.width > 0 else { continue }
          targets.append(["href": href, "image": image, "row": rowID(label), "start": range.location,
            "x": rect.midX, "y": rect.midY])
        }
      }
      let literal = (text.string as NSString).range(of: "![Literal picture](\(urls[1]))")
      if literal.location != NSNotFound {
        for box in label.textLayout.rects(for: literal) {
          let rect = label.convert(label.viewRect(fromLayoutRect: box), to: window)
          guard window.bounds.contains(CGPoint(x: rect.midX, y: rect.midY)), rect.width > 0 else { continue }
          code.append(["x": rect.midX, "y": rect.midY])
        }
      }
    }
    let calls = RemoteImageProtocol.calls.withLock { $0 }
    probe.accessibilityValue = SessionController.json(["host": kind, "paperReady": paper?.image != nil,
      "galleryReady": loaded, "cloudReferenceBlocked": blockedCloudReference, "targets": targets, "code": code,
      "fileIcon": fileIcon, "links": openedLinks, "files": openedFiles,
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
