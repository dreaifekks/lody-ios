import SafariServices
import UIKit
import WebKit

/// The conversation's browser preview, embedded rather than presented over the whole window: on
/// iPad `LodyShell.presentDetail` places it in the inspector column beside the conversation, so the
/// page can be watched while the agent edits it; compact widths get the same page as a sheet.
///
/// The page is the user's own dev server behind a share tunnel, not Lody content. It runs in a
/// non-persistent website data store, apart from the trusted cloud data runtime, with no script
/// message handlers; links that leave the web open in the system instead.
@MainActor
final class BrowserPreviewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
  enum LinkStatus: Equatable {
    case idle
    case checking
    case needsRegenerate
    case regenerating
    case unconfirmed
  }

  private static let ownedButtonPrefix = "browser-preview-"

  private(set) var url: URL
  var linkStatus: LinkStatus = .idle {
    didSet {
      guard oldValue != linkStatus else { return }
      renderLinkStatus()
    }
  }
  var canStopProcess = false {
    didSet {
      guard oldValue != canStopProcess else { return }
      renderNavigationItems()
    }
  }
  var onRegenerate: (() -> Void)?
  var onDisconnect: ((Bool) -> Void)?

  private var webViewCreated = false
  private lazy var webView: WKWebView = {
    webViewCreated = true
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.allowsBackForwardNavigationGestures = true
    webView.accessibilityIdentifier = "browser-preview-web"
    return webView
  }()
  private let progress = UIProgressView(progressViewStyle: .bar)
  private let statusBanner = UIView()
  private let statusStack = UIStackView()
  private let statusSpinner = UIActivityIndicatorView(style: .medium)
  private let statusIcon = UIImageView()
  private let statusLabel = UILabel()
  private var webTopToSafeArea: NSLayoutConstraint?
  private var webTopToBanner: NSLayoutConstraint?
  private var observations: [NSKeyValueObservation] = []

  var currentPageURL: URL {
    if webViewCreated, let current = webView.url { return current }
    return url
  }

  init(url: URL) {
    self.url = url
    super.init(nibName: nil, bundle: nil)
    title = String(localized: "session.preview.title", bundle: .lody)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .lodyBackground
    configureStatusBanner()
    for child in [statusBanner, webView, progress] as [UIView] {
      child.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(child)
    }
    progress.trackTintColor = .clear
    let topToSafeArea = webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
    let topToBanner = webView.topAnchor.constraint(equalTo: statusBanner.bottomAnchor)
    webTopToSafeArea = topToSafeArea
    webTopToBanner = topToBanner
    NSLayoutConstraint.activate([
      statusBanner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      statusBanner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      statusBanner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      topToSafeArea,
      webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      progress.topAnchor.constraint(equalTo: webView.topAnchor),
      progress.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      progress.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    observations = [
      webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] webView, _ in
        MainActor.assumeIsolated { self?.renderProgress(webView.estimatedProgress, loading: webView.isLoading) }
      },
      webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
        MainActor.assumeIsolated { self?.renderProgress(webView.estimatedProgress, loading: webView.isLoading) }
      },
    ]
    webView.load(URLRequest(url: url))
    renderLinkStatus()
  }

  /// Detaches from a previous `LodyPageController` host before re-presenting this cached
  /// controller in a new sheet or iPad inspector column, keeping `WKWebView` alive.
  func detachFromParentIfNeeded() {
    guard parent != nil else { return }
    willMove(toParent: nil)
    viewIfLoaded?.removeFromSuperview()
    removeFromParent()
  }

  func loadRegeneratedURL(_ nextURL: URL) {
    url = nextURL
    linkStatus = .idle
    if isViewLoaded {
      webView.load(URLRequest(url: nextURL))
    }
  }

  func updateCachedURL(_ nextURL: URL) {
    url = nextURL
  }

  func teardown() {
    detachFromParentIfNeeded()
    observations.removeAll()
    if webViewCreated {
      webView.stopLoading()
      webView.navigationDelegate = nil
      webView.uiDelegate = nil
    }
    onRegenerate = nil
    onDisconnect = nil
  }

  /// Appended once the hosting page has loaded, so a sheet keeps the shell's shared close item
  /// and the iPad inspector its leading close.
  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    renderNavigationItems()
  }

  private func configureStatusBanner() {
    statusBanner.backgroundColor = .secondarySystemBackground
    statusBanner.isHidden = true
    statusStack.axis = .horizontal
    statusStack.alignment = .center
    statusStack.spacing = 6
    statusStack.translatesAutoresizingMaskIntoConstraints = false
    statusSpinner.hidesWhenStopped = true
    statusSpinner.transform = CGAffineTransform(scaleX: 0.75, y: 0.75)
    statusIcon.contentMode = .scaleAspectFit
    statusIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
    statusIcon.isHidden = true
    statusLabel.font = .preferredFont(forTextStyle: .footnote)
    statusLabel.adjustsFontForContentSizeCategory = true
    statusLabel.textColor = .secondaryLabel
    statusLabel.numberOfLines = 1
    statusStack.addArrangedSubview(statusSpinner)
    statusStack.addArrangedSubview(statusIcon)
    statusStack.addArrangedSubview(statusLabel)
    statusBanner.addSubview(statusStack)
    NSLayoutConstraint.activate([
      statusStack.topAnchor.constraint(equalTo: statusBanner.topAnchor, constant: 6),
      statusStack.bottomAnchor.constraint(equalTo: statusBanner.bottomAnchor, constant: -6),
      statusStack.leadingAnchor.constraint(greaterThanOrEqualTo: statusBanner.leadingAnchor, constant: 12),
      statusStack.trailingAnchor.constraint(lessThanOrEqualTo: statusBanner.trailingAnchor, constant: -12),
      statusStack.centerXAnchor.constraint(equalTo: statusBanner.centerXAnchor),
    ])
  }

  private func renderLinkStatus() {
    renderNavigationItems()
    guard isViewLoaded else { return }
    switch linkStatus {
    case .idle, .needsRegenerate:
      statusSpinner.stopAnimating()
      statusIcon.isHidden = true
      statusBanner.isHidden = true
      webTopToBanner?.isActive = false
      webTopToSafeArea?.isActive = true
    case .checking:
      statusSpinner.startAnimating()
      statusIcon.isHidden = true
      statusLabel.text = String(localized: "session.preview.checking", bundle: .lody)
      statusLabel.textColor = .secondaryLabel
      statusBanner.isHidden = false
      webTopToSafeArea?.isActive = false
      webTopToBanner?.isActive = true
    case .regenerating:
      statusSpinner.startAnimating()
      statusIcon.isHidden = true
      statusLabel.text = String(localized: "session.preview.regenerating", bundle: .lody)
      statusLabel.textColor = .secondaryLabel
      statusBanner.isHidden = false
      webTopToSafeArea?.isActive = false
      webTopToBanner?.isActive = true
    case .unconfirmed:
      statusSpinner.stopAnimating()
      statusIcon.image = UIImage(systemName: "exclamationmark.triangle.fill")
      statusIcon.tintColor = .systemOrange
      statusIcon.isHidden = false
      statusLabel.text = String(localized: "session.preview.unconfirmed", bundle: .lody)
      statusLabel.textColor = .secondaryLabel
      statusBanner.isHidden = false
      webTopToSafeArea?.isActive = false
      webTopToBanner?.isActive = true
    }
  }

  private func renderNavigationItems() {
    guard let item = parent?.navigationItem else { return }
    let preserved = (item.rightBarButtonItems ?? []).filter {
      !($0.accessibilityIdentifier?.hasPrefix(Self.ownedButtonPrefix) ?? false)
    }
    var owned: [UIBarButtonItem] = []
    if onDisconnect != nil {
      var disconnectActions: [UIAction] = [
        UIAction(
          title: String(localized: "session.preview.disconnectRemoteOnly", bundle: .lody),
          image: UIImage(systemName: "stop.circle")
        ) { [weak self] _ in
          self?.onDisconnect?(false)
        },
      ]
      if canStopProcess {
        disconnectActions.append(
          UIAction(
            title: String(localized: "session.preview.disconnectAndStopProcess", bundle: .lody),
            image: UIImage(systemName: "power"),
            attributes: .destructive
          ) { [weak self] _ in
            self?.onDisconnect?(true)
          }
        )
      }
      let disconnect = UIBarButtonItem(
        image: UIImage(systemName: "power"),
        menu: UIMenu(children: disconnectActions)
      )
      disconnect.accessibilityLabel = String(localized: "session.preview.stop", bundle: .lody)
      disconnect.accessibilityIdentifier = "browser-preview-disconnect"
      owned.append(disconnect)
    }
    switch linkStatus {
    case .idle:
      break
    case .checking, .regenerating:
      let spinner = UIActivityIndicatorView(style: .medium)
      spinner.startAnimating()
      let button = UIBarButtonItem(customView: spinner)
      let key = linkStatus == .checking ? "session.preview.checking" : "session.preview.regenerating"
      button.accessibilityLabel = String(localized: String.LocalizationValue(key), bundle: .lody)
      button.accessibilityIdentifier = "browser-preview-checking"
      owned.append(button)
    case .needsRegenerate:
      let regenerate = UIBarButtonItem(image: UIImage(systemName: "arrow.trianglehead.2.clockwise"), primaryAction: UIAction { [weak self] _ in
        self?.onRegenerate?()
      })
      regenerate.tintColor = .tintColor
      regenerate.accessibilityLabel = String(localized: "session.preview.regenerate", bundle: .lody)
      regenerate.accessibilityIdentifier = "browser-preview-regenerate"
      owned.append(regenerate)
    case .unconfirmed:
      let unconfirmed = UIBarButtonItem(image: UIImage(systemName: "exclamationmark.triangle"), primaryAction: UIAction { _ in
        LodyToastOverlay.shared.show(message: String(localized: "session.preview.unconfirmed", bundle: .lody), kind: .neutral)
      })
      unconfirmed.tintColor = .systemOrange
      unconfirmed.accessibilityLabel = String(localized: "session.preview.unconfirmed", bundle: .lody)
      unconfirmed.accessibilityIdentifier = "browser-preview-unconfirmed"
      owned.append(unconfirmed)
    }
    let reload = UIBarButtonItem(image: UIImage(systemName: "arrow.clockwise"), primaryAction: UIAction { [weak self] _ in
      self?.webView.reload()
    })
    reload.accessibilityLabel = String(localized: "session.preview.reload", bundle: .lody)
    reload.accessibilityIdentifier = "browser-preview-reload"
    let safari = UIBarButtonItem(image: UIImage(systemName: "safari"), primaryAction: UIAction { [weak self] _ in
      guard let self else { return }
      present(SFSafariViewController(url: currentPageURL), animated: true)
    })
    safari.accessibilityLabel = String(localized: "session.preview.openInSafari", bundle: .lody)
    safari.accessibilityIdentifier = "browser-preview-safari"
    item.rightBarButtonItems = preserved + owned + [safari, reload]
  }

  private func renderProgress(_ value: Double, loading: Bool) {
    progress.setProgress(Float(value), animated: loading)
    progress.isHidden = !loading
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
    guard let target = navigationAction.request.url else { return .cancel }
    if ["http", "https", "about", "blob", "data"].contains(target.scheme?.lowercased() ?? "") { return .allow }
    // mailto:, tel: and app links belong to the system, never to the preview.
    if navigationAction.navigationType == .linkActivated { await UIApplication.shared.open(target) }
    return .cancel
  }

  /// `target="_blank"` and `window.open` stay in the preview instead of being dropped.
  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
               for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
    return nil
  }
}
