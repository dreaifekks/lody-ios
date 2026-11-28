import ImageIO
import LodyCore
import UniformTypeIdentifiers
import UIKit

enum ChatShareExportError: Error, Equatable {
  case tooLarge
  case scopeChanged
  case renderFailed
  case writeFailed
}

enum ChatShareRasterizer {
  struct ScalePlan: Equatable, Sendable {
    let scale: CGFloat
    let pixelWidth: Int
    let pixelHeight: Int
    let stripCount: Int
  }

  static let targetScale: CGFloat = 2.0
  static let minScale: CGFloat = 1.25
  static let maxPixelHeight = 16_384
  static let defaultMaxStripPixelHeight = 2_048

  static func scalePlan(
    outerWidth: CGFloat,
    outerHeight: CGFloat,
    maxStripPixelHeight: Int = defaultMaxStripPixelHeight
  ) throws -> ScalePlan {
    guard outerWidth.isFinite, outerHeight.isFinite, outerWidth > 0, outerHeight > 0 else {
      throw ChatShareExportError.renderFailed
    }
    let stripLimit = max(64, maxStripPixelHeight)
    let scale: CGFloat
    if outerHeight * targetScale <= CGFloat(maxPixelHeight) {
      scale = targetScale
    } else {
      scale = floor((CGFloat(maxPixelHeight) / outerHeight) * 100.0) / 100.0
    }
    guard scale >= minScale else {
      throw ChatShareExportError.tooLarge
    }
    let pixelWidth = max(1, Int((outerWidth * scale).rounded()))
    let pixelHeight = max(1, min(maxPixelHeight, Int(floor(outerHeight * scale))))
    let stripCount = max(1, (pixelHeight + stripLimit - 1) / stripLimit)
    return ScalePlan(scale: scale, pixelWidth: pixelWidth, pixelHeight: pixelHeight, stripCount: stripCount)
  }

  @MainActor
  static func renderPNG(
    _ configuration: ChatShareConfiguration,
    hostView: UIView? = nil,
    maxStripPixelHeight: Int = defaultMaxStripPixelHeight
  ) throws -> Data {
    let traits = configuration.theme.scopedTraits()
    let cardView = ChatShareCardView(frame: .zero)
    cardView.showsPreviewBackdropImage = false
    let outerSize = cardView.configure(configuration)
    let stripLimit = max(64, maxStripPixelHeight)
    let plan = try scalePlan(
      outerWidth: outerSize.width,
      outerHeight: outerSize.height,
      maxStripPixelHeight: stripLimit
    )

    let stagingHost: UIView
    var temporaryWindow: UIWindow?
    if let hostView {
      stagingHost = hostView
    } else {
      let win = UIWindow(frame: CGRect(x: 0, y: 0, width: max(600, outerSize.width), height: 900))
      win.overrideUserInterfaceStyle = configuration.theme.userInterfaceStyle
      win.isHidden = false
      win.alpha = 0.01
      stagingHost = win
      temporaryWindow = win
    }

    cardView.frame = CGRect(x: -outerSize.width - 100, y: 0, width: outerSize.width, height: outerSize.height)
    stagingHost.addSubview(cardView)
    defer {
      cardView.removeFromSuperview()
      temporaryWindow?.isHidden = true
    }

    traits.performAsCurrent {
      layoutHierarchy(cardView)
    }

    let isOpaque = configuration.backdrop != .none && configuration.effectiveMat > 0
    let alphaInfo = isOpaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | alphaInfo
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    guard let finalContext = CGContext(
      data: nil,
      width: plan.pixelWidth,
      height: plan.pixelHeight,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: bitmapInfo
    ) else {
      throw ChatShareExportError.renderFailed
    }

    if !isOpaque {
      finalContext.clear(CGRect(x: 0, y: 0, width: plan.pixelWidth, height: plan.pixelHeight))
    }

    let surfaceSubviews = cardView.cardSurfaceView.subviews
    let cardTopInOuter = cardView.cardSurfaceView.frame.minY

    for stripIndex in 0..<plan.stripCount {
      let stripTopPx = stripIndex * stripLimit
      let stripHeightPx = min(stripLimit, plan.pixelHeight - stripTopPx)
      guard stripHeightPx > 0 else { continue }
      let stripTopPt = CGFloat(stripTopPx) / plan.scale
      let stripHeightPt = CGFloat(stripHeightPx) / plan.scale
      let stripMinY = stripTopPt - 24
      let stripMaxY = stripTopPt + stripHeightPt + 24

      var stripImage: CGImage?
      autoreleasepool {
        guard let stripContext = CGContext(
          data: nil,
          width: plan.pixelWidth,
          height: stripHeightPx,
          bitsPerComponent: 8,
          bytesPerRow: 0,
          space: colorSpace,
          bitmapInfo: bitmapInfo
        ) else { return }

        if !isOpaque {
          stripContext.clear(CGRect(x: 0, y: 0, width: plan.pixelWidth, height: stripHeightPx))
        }

        for subview in surfaceSubviews {
          let minY = cardTopInOuter + subview.frame.minY
          let maxY = cardTopInOuter + subview.frame.maxY
          let intersects = maxY >= stripMinY && minY <= stripMaxY
          subview.isHidden = !intersects
        }

        stripContext.translateBy(x: 0, y: CGFloat(stripHeightPx))
        stripContext.scaleBy(x: plan.scale, y: -plan.scale)
        stripContext.translateBy(x: 0, y: -stripTopPt)
        stripContext.clip(to: CGRect(x: 0, y: stripTopPt, width: outerSize.width, height: stripHeightPt))

        traits.performAsCurrent {
          UIGraphicsPushContext(stripContext)
          configuration.backdrop.draw(in: stripContext, rect: CGRect(origin: .zero, size: outerSize))
          cardView.layer.render(in: stripContext)
          UIGraphicsPopContext()
        }

        stripImage = stripContext.makeImage()
      }

      for subview in surfaceSubviews {
        subview.isHidden = false
      }

      guard let renderedStrip = stripImage else {
        throw ChatShareExportError.renderFailed
      }
      let targetY = plan.pixelHeight - stripTopPx - stripHeightPx
      finalContext.draw(renderedStrip, in: CGRect(x: 0, y: targetY, width: plan.pixelWidth, height: stripHeightPx))
    }

    guard let finalImage = finalContext.makeImage() else {
      throw ChatShareExportError.renderFailed
    }

    let pngData = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      pngData as CFMutableData,
      UTType.png.identifier as CFString,
      1,
      nil
    ) else {
      throw ChatShareExportError.renderFailed
    }
    CGImageDestinationAddImage(destination, finalImage, nil)
    guard CGImageDestinationFinalize(destination), pngData.length > 0 else {
      throw ChatShareExportError.renderFailed
    }
    return pngData as Data
  }

  @MainActor
  private static func layoutHierarchy(_ view: UIView) {
    view.setNeedsLayout()
    view.layoutIfNeeded()
    for child in view.subviews {
      layoutHierarchy(child)
    }
  }
}

enum ChatShareTempStore {
  static var defaultBaseDirectory: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("lody-chat-share", isDirectory: true)
  }

  static func sanitizeFileName(_ rawTitle: String?) -> String {
    let trimmed = (rawTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
      .union(.controlCharacters)
      .union(.newlines)

    var replaced = ""
    var previousWasHyphen = false
    var previousWasSpace = false
    for scalar in trimmed.unicodeScalars {
      if forbidden.contains(scalar) {
        if !previousWasHyphen && !replaced.isEmpty {
          replaced.append("-")
          previousWasHyphen = true
          previousWasSpace = false
        }
      } else if CharacterSet.whitespaces.contains(scalar) {
        if !previousWasSpace && !previousWasHyphen && !replaced.isEmpty {
          replaced.append(" ")
          previousWasSpace = true
        }
      } else {
        replaced.unicodeScalars.append(scalar)
        previousWasHyphen = scalar == "-"
        previousWasSpace = false
      }
    }

    let trimChars = CharacterSet(charactersIn: " .-")
    var cleaned = replaced.trimmingCharacters(in: trimChars)
    if cleaned.count > 60 {
      cleaned = String(cleaned.prefix(60)).trimmingCharacters(in: trimChars)
    }
    if cleaned.isEmpty {
      cleaned = "lody-chat"
    }
    return cleaned + ".png"
  }

  static func stagePNG(
    _ data: Data,
    title: String?,
    baseDirectory: URL = defaultBaseDirectory
  ) throws -> (directory: URL, fileURL: URL) {
    let directory = baseDirectory.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let fileURL = directory.appendingPathComponent(sanitizeFileName(title), isDirectory: false)
      try data.write(to: fileURL, options: .atomic)
      return (directory, fileURL)
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw ChatShareExportError.writeFailed
    }
  }

  static func removeDirectory(_ directory: URL?) {
    guard let directory else { return }
    try? FileManager.default.removeItem(at: directory)
  }

  static func cleanupStale(
    in baseDirectory: URL = defaultBaseDirectory,
    maxAge: TimeInterval = 600,
    now: Date = Date()
  ) {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(
      at: baseDirectory,
      includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
      options: [.skipsHiddenFiles]
    ) else { return }

    for entry in entries {
      let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
      let timestamp = values?.contentModificationDate ?? values?.creationDate
      if let timestamp, now.timeIntervalSince(timestamp) > maxAge {
        try? fm.removeItem(at: entry)
      }
    }
  }
}

@MainActor
final class ChatShareImageController: UIViewController {
  private enum ExportAction {
    case copy
    case export
  }

  private let payload: RuntimeContract.ConversationShareMessagesResultReady
  private let selectedMessages: [RuntimeContract.ConversationShareMessage]
  private let repository: String
  private let meta: ChatShareCardMeta
  private let isScopeValid: @MainActor () -> Bool
  private let onCompleteShare: @MainActor () -> Void

  private var destination: ChatShareDestination = .chat
  private var mat: Int = ChatShareDestination.chat.layout.defaultMat
  private var backdrop: ChatShareBackdrop = .lody
  private var theme: ChatShareTheme
  private var themeResolvedFromHost = false
  private var activeExport: ExportAction?
  private var stagedDirectories: Set<URL> = []
  private var observers: [NSObjectProtocol] = []

  private let previewScroll = UIScrollView()
  private let previewWell = UIView()
  private let cardWrapper = UIView()
  private let cardView = ChatShareCardView(frame: .zero)
  private var cardNaturalSize: CGSize = .zero
  private var lastViewportWidth: CGFloat = 0

  private let controlsPanel = UIView()
  private let controlsHairline = UIView()
  private let destinationControl = UISegmentedControl()
  private let themeControl = UISegmentedControl()
  private let paddingTitleLabel = UILabel()
  private let paddingValueLabel = UILabel()
  private let paddingSlider = UISlider()
  private let swatchesStack = UIStackView()
  private var swatchButtons: [ChatShareBackdrop: ChatShareBackdropSwatchButton] = [:]
  private let copyButton = UIButton(type: .system)
  private let exportButton = UIButton(type: .system)

  private lazy var closeItem: UIBarButtonItem = {
    let sheetTitle = String(localized: "chat.shareImage.title", bundle: .lody)
    let item = LodyFormController.barButton(
      symbol: "xmark",
      label: String.localizedStringWithFormat(
        String(localized: "accessibility.closeSheet", bundle: .lody),
        sheetTitle
      )
    ) { [weak self] in
      self?.closeSheetPreservingSelection()
    }
    item.accessibilityIdentifier = "chat.shareImage.close"
    return item
  }()

  init(
    payload: RuntimeContract.ConversationShareMessagesResultReady,
    selectedMessages: [RuntimeContract.ConversationShareMessage],
    repository: String = "",
    initialTheme: ChatShareTheme? = nil,
    isScopeValid: @escaping @MainActor () -> Bool,
    onCompleteShare: @escaping @MainActor () -> Void
  ) {
    self.payload = payload
    self.selectedMessages = selectedMessages
    self.repository = repository
    self.meta = ChatShareCardFormatting.makeMeta(from: payload, selectedMessages: selectedMessages)
    if let initialTheme {
      self.theme = initialTheme
      self.themeResolvedFromHost = true
    } else {
      self.theme = .light
      self.themeResolvedFromHost = false
    }
    self.isScopeValid = isScopeValid
    self.onCompleteShare = onCompleteShare
    super.init(nibName: nil, bundle: nil)
    title = String(localized: "chat.shareImage.title", bundle: .lody)
    ChatShareTempStore.cleanupStale()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  isolated deinit {
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
    for dir in stagedDirectories {
      ChatShareTempStore.removeDirectory(dir)
    }
  }

  var currentConfiguration: ChatShareConfiguration {
    ChatShareConfiguration(
      messages: selectedMessages,
      title: payload.title,
      destination: destination,
      mat: mat,
      theme: theme,
      backdrop: backdrop,
      meta: meta,
      repository: repository
    )
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .lodyBackground
    view.accessibilityIdentifier = "chat.shareImage.sheet"

    if !themeResolvedFromHost {
      let hostStyle = presentingViewController?.traitCollection.userInterfaceStyle ?? traitCollection.userInterfaceStyle
      theme = hostStyle == .dark ? .dark : .light
      themeResolvedFromHost = true
    }

    setupPreviewViewport()
    setupControlsPanel()
    installConstraints()
    installScopeObservers()
    syncControls()
    rebuildCardPreview()
  }

  override func didMove(toParent parent: UIViewController?) {
    super.didMove(toParent: parent)
    let target = parent ?? self
    target.navigationItem.leftBarButtonItems = [closeItem]
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    (parent ?? self).navigationItem.leftBarButtonItems = [closeItem]
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed || navigationController?.isBeingDismissed == true || parent?.isBeingDismissed == true {
      cleanupAllStagedFiles()
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    if let host = parent ?? self as UIViewController? {
      LodyScrollEdges.bind(previewScroll, to: host)
    }
    layoutPreviewCard()
  }

  private func setupPreviewViewport() {
    previewScroll.accessibilityIdentifier = "chat.shareImage.previewScroll"
    previewScroll.alwaysBounceVertical = true
    previewScroll.showsHorizontalScrollIndicator = false
    previewScroll.contentInsetAdjustmentBehavior = .automatic
    LodyScrollEdges.navigation(previewScroll)
    previewScroll.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(previewScroll)

    previewWell.layer.cornerRadius = 18
    previewWell.layer.cornerCurve = .continuous
    previewWell.backgroundColor = .lodyInset
    previewScroll.addSubview(previewWell)

    cardWrapper.backgroundColor = .clear
    cardWrapper.clipsToBounds = false
    previewScroll.addSubview(cardWrapper)
    cardWrapper.addSubview(cardView)
  }

  private func setupControlsPanel() {
    controlsPanel.accessibilityIdentifier = "chat.shareImage.controls"
    controlsPanel.backgroundColor = .lodyOpaqueBackground
    controlsPanel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(controlsPanel)

    controlsHairline.backgroundColor = .lodyLine2
    controlsHairline.translatesAutoresizingMaskIntoConstraints = false
    controlsPanel.addSubview(controlsHairline)

    destinationControl.insertSegment(
      withTitle: String(localized: "chat.shareImage.destination.chat", bundle: .lody),
      at: 0,
      animated: false
    )
    destinationControl.insertSegment(
      withTitle: String(localized: "chat.shareImage.destination.post", bundle: .lody),
      at: 1,
      animated: false
    )
    destinationControl.accessibilityIdentifier = "chat.shareImage.destination"
    destinationControl.accessibilityLabel = String(localized: "chat.shareImage.destination.label", bundle: .lody)
    destinationControl.addAction(UIAction { [weak self] _ in self?.destinationChanged() }, for: .valueChanged)

    themeControl.insertSegment(
      withTitle: String(localized: "chat.shareImage.theme.light", bundle: .lody),
      at: 0,
      animated: false
    )
    themeControl.insertSegment(
      withTitle: String(localized: "chat.shareImage.theme.dark", bundle: .lody),
      at: 1,
      animated: false
    )
    themeControl.accessibilityIdentifier = "chat.shareImage.theme"
    themeControl.accessibilityLabel = String(localized: "chat.shareImage.theme.label", bundle: .lody)
    themeControl.addAction(UIAction { [weak self] _ in self?.themeChanged() }, for: .valueChanged)

    paddingTitleLabel.font = .preferredFont(forTextStyle: .subheadline)
    paddingTitleLabel.adjustsFontForContentSizeCategory = true
    paddingTitleLabel.textColor = .label
    paddingTitleLabel.text = String(localized: "chat.shareImage.padding", bundle: .lody)

    paddingValueLabel.font = LodyDesign.mono(12)
    paddingValueLabel.textColor = .secondaryLabel
    paddingValueLabel.textAlignment = .right
    paddingValueLabel.accessibilityIdentifier = "chat.shareImage.paddingValue"

    paddingSlider.minimumValue = Float(ChatShareCardFormatting.minMat)
    paddingSlider.maximumValue = Float(ChatShareCardFormatting.maxMat)
    paddingSlider.isContinuous = true
    paddingSlider.accessibilityIdentifier = "chat.shareImage.paddingSlider"
    paddingSlider.accessibilityLabel = String(localized: "chat.shareImage.padding", bundle: .lody)
    paddingSlider.addAction(UIAction { [weak self] _ in self?.paddingChanged() }, for: .valueChanged)

    swatchesStack.axis = .horizontal
    swatchesStack.distribution = .equalSpacing
    swatchesStack.alignment = .center
    for item in ChatShareBackdrop.allCases {
      let button = ChatShareBackdropSwatchButton(backdrop: item)
      button.addAction(UIAction { [weak self] _ in self?.selectBackdrop(item) }, for: .touchUpInside)
      swatchButtons[item] = button
      swatchesStack.addArrangedSubview(button)
    }

    var copyConfig = UIButton.Configuration.gray()
    copyConfig.cornerStyle = .capsule
    copyConfig.baseForegroundColor = .label
    copyConfig.image = UIImage(
      systemName: "doc.on.doc",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
    )
    copyConfig.imagePadding = 6
    copyConfig.title = String(localized: "chat.shareImage.copyImage", bundle: .lody)
    copyButton.configuration = copyConfig
    copyButton.accessibilityIdentifier = "chat.shareImage.copy"
    copyButton.addAction(UIAction { [weak self] _ in self?.performCopyImage() }, for: .touchUpInside)

    var exportConfig = UIButton.Configuration.lodyProminent(font: .systemFont(ofSize: 15, weight: .semibold))
    exportConfig.cornerStyle = .capsule
    exportConfig.image = UIImage(
      systemName: "square.and.arrow.up",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
    )
    exportConfig.imagePadding = 6
    exportConfig.title = String(localized: "chat.shareImage.exportPNG", bundle: .lody)
    exportButton.configuration = exportConfig
    exportButton.accessibilityIdentifier = "chat.shareImage.export"
    exportButton.addAction(UIAction { [weak self] _ in self?.performExportPNG() }, for: .touchUpInside)
  }

  private func installConstraints() {
    let segmentsRow = UIStackView(arrangedSubviews: [destinationControl, themeControl])
    segmentsRow.axis = .horizontal
    segmentsRow.spacing = 10
    segmentsRow.distribution = .fillEqually
    segmentsRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true

    let paddingHeader = UIStackView(arrangedSubviews: [paddingTitleLabel, paddingValueLabel])
    paddingHeader.axis = .horizontal
    paddingHeader.spacing = 8
    paddingTitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    paddingValueLabel.setContentHuggingPriority(.required, for: .horizontal)

    let paddingGroup = UIStackView(arrangedSubviews: [paddingHeader, paddingSlider])
    paddingGroup.axis = .vertical
    paddingGroup.spacing = 4
    paddingSlider.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true

    let actionsRow = UIStackView(arrangedSubviews: [copyButton, exportButton])
    actionsRow.axis = .horizontal
    actionsRow.spacing = 10
    actionsRow.distribution = .fillEqually
    copyButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true
    exportButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true

    let stack = UIStackView(arrangedSubviews: [segmentsRow, paddingGroup, swatchesStack, actionsRow])
    stack.axis = .vertical
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    controlsPanel.addSubview(stack)

    let stackWidth = stack.widthAnchor.constraint(equalTo: controlsPanel.safeAreaLayoutGuide.widthAnchor, constant: -32)
    stackWidth.priority = .defaultHigh

    NSLayoutConstraint.activate([
      previewScroll.topAnchor.constraint(equalTo: view.topAnchor),
      previewScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      previewScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      previewScroll.bottomAnchor.constraint(equalTo: controlsPanel.topAnchor),

      controlsPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      controlsPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      controlsPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      controlsHairline.topAnchor.constraint(equalTo: controlsPanel.topAnchor),
      controlsHairline.leadingAnchor.constraint(equalTo: controlsPanel.leadingAnchor),
      controlsHairline.trailingAnchor.constraint(equalTo: controlsPanel.trailingAnchor),
      controlsHairline.heightAnchor.constraint(equalToConstant: 1),

      stack.topAnchor.constraint(equalTo: controlsPanel.topAnchor, constant: 12),
      stack.centerXAnchor.constraint(equalTo: controlsPanel.safeAreaLayoutGuide.centerXAnchor),
      stack.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
      stackWidth,
      stack.bottomAnchor.constraint(equalTo: controlsPanel.safeAreaLayoutGuide.bottomAnchor, constant: -10),
    ])
  }

  private func installScopeObservers() {
    let names: [Notification.Name] = [.lodyWorkspaceEncryptionObserved, .lodyCatalogDidChange]
    observers = names.map { name in
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          if !self.isScopeValid() {
            self.cleanupAllStagedFiles()
            self.closeSheetPreservingSelection()
          }
        }
      }
    }
  }

  private func destinationChanged() {
    let next: ChatShareDestination = destinationControl.selectedSegmentIndex == 1 ? .post : .chat
    guard next != destination else { return }
    destination = next
    mat = next.layout.defaultMat
    UISelectionFeedbackGenerator().selectionChanged()
    syncControls()
    rebuildCardPreview()
  }

  private func themeChanged() {
    let next: ChatShareTheme = themeControl.selectedSegmentIndex == 1 ? .dark : .light
    guard next != theme else { return }
    theme = next
    UISelectionFeedbackGenerator().selectionChanged()
    syncControls()
    rebuildCardPreview()
  }

  private func paddingChanged() {
    let snapped = ChatShareCardFormatting.snapMat(paddingSlider.value)
    if Int(paddingSlider.value.rounded()) != snapped {
      paddingSlider.value = Float(snapped)
    }
    guard snapped != mat else { return }
    mat = snapped
    syncControls()
    rebuildCardPreview()
  }

  private func selectBackdrop(_ next: ChatShareBackdrop) {
    guard next != backdrop else { return }
    backdrop = next
    UISelectionFeedbackGenerator().selectionChanged()
    syncControls()
    rebuildCardPreview()
  }

  private func syncControls() {
    let exporting = activeExport != nil
    destinationControl.selectedSegmentIndex = destination == .post ? 1 : 0
    themeControl.selectedSegmentIndex = theme == .dark ? 1 : 0

    let hasBackdrop = backdrop != .none
    let shownMat = hasBackdrop ? mat : 0
    paddingSlider.value = Float(mat)
    paddingSlider.isEnabled = hasBackdrop && !exporting
    paddingValueLabel.text = "\(shownMat) px"
    paddingValueLabel.alpha = hasBackdrop ? 1 : 0.45

    for (kind, button) in swatchButtons {
      button.setSelectedState(kind == backdrop)
      button.isEnabled = !exporting
    }

    destinationControl.isEnabled = !exporting
    themeControl.isEnabled = !exporting

    var copyCfg = copyButton.configuration
    copyCfg?.showsActivityIndicator = activeExport == .copy
    copyButton.configuration = copyCfg
    copyButton.isEnabled = !exporting

    var exportCfg = exportButton.configuration
    exportCfg?.showsActivityIndicator = activeExport == .export
    exportButton.configuration = exportCfg
    exportButton.isEnabled = !exporting
  }

  private func rebuildCardPreview() {
    cardView.transform = .identity
    cardNaturalSize = cardView.configure(currentConfiguration)
    cardView.accessibilityValue = "\(Int(cardNaturalSize.width)) × \(Int(cardNaturalSize.height))"
    layoutPreviewCard()
  }

  private func layoutPreviewCard() {
    let viewportWidth = previewScroll.bounds.width
    guard viewportWidth > 0, cardNaturalSize.width > 0, cardNaturalSize.height > 0 else { return }
    lastViewportWidth = viewportWidth
    let horizontalMargin: CGFloat = 20
    let verticalMargin: CGFloat = 16
    let availableWidth = max(60, viewportWidth - horizontalMargin * 2)
    let scale = min(1.0, availableWidth / cardNaturalSize.width)
    let scaledWidth = round(cardNaturalSize.width * scale)
    let scaledHeight = round(cardNaturalSize.height * scale)
    let originX = round((viewportWidth - scaledWidth) / 2)

    cardWrapper.frame = CGRect(x: originX, y: verticalMargin, width: scaledWidth, height: scaledHeight)
    cardView.transform = .identity
    cardView.frame = CGRect(origin: .zero, size: cardNaturalSize)
    if scale < 0.9999 {
      cardView.transform = CGAffineTransform(scaleX: scale, y: scale)
      cardView.frame.origin = .zero
    }

    if backdrop == .none {
      previewWell.isHidden = false
      previewWell.frame = cardWrapper.frame.insetBy(dx: -8, dy: -8)
    } else {
      previewWell.isHidden = true
    }

    previewScroll.contentSize = CGSize(width: viewportWidth, height: cardWrapper.frame.maxY + verticalMargin)
  }

  private func performCopyImage() {
    guard activeExport == nil else { return }
    guard isScopeValid() else {
      LodyToastOverlay.shared.show(message: String(localized: "chat.shareImage.copyFailed", bundle: .lody), kind: .error)
      return
    }
    activeExport = .copy
    syncControls()
    let config = currentConfiguration

    // Let UIKit paint the button spinner before synchronous CPU strip rasterization.
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      defer {
        self.activeExport = nil
        self.syncControls()
      }
      do {
        guard self.isScopeValid() else { throw ChatShareExportError.scopeChanged }
        let pngData = try ChatShareRasterizer.renderPNG(config, hostView: self.view)
        guard self.isScopeValid() else { throw ChatShareExportError.scopeChanged }
        UIPasteboard.general.setData(pngData, forPasteboardType: UTType.png.identifier)
        let onComplete = self.onCompleteShare
        self.dismissSheet {
          onComplete()
          LodyToastOverlay.shared.show(message: String(localized: "chat.shareImage.copied", bundle: .lody), kind: .success)
        }
      } catch let error as ChatShareExportError where error == .tooLarge {
        LodyToastOverlay.shared.show(message: String(localized: "chat.shareImage.tooLarge", bundle: .lody), kind: .warning)
      } catch {
        LodyToastOverlay.shared.show(message: String(localized: "chat.shareImage.copyFailed", bundle: .lody), kind: .error)
      }
    }
  }

  private func performExportPNG() {
    guard activeExport == nil else { return }
    guard isScopeValid() else {
      LodyToastOverlay.shared.show(message: String(localized: "chat.shareImage.exportFailed", bundle: .lody), kind: .error)
      return
    }
    activeExport = .export
    syncControls()
    let config = currentConfiguration

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      do {
        guard self.isScopeValid() else { throw ChatShareExportError.scopeChanged }
        let pngData = try ChatShareRasterizer.renderPNG(config, hostView: self.view)
        guard self.isScopeValid() else { throw ChatShareExportError.scopeChanged }
        let staged = try ChatShareTempStore.stagePNG(pngData, title: config.title)
        self.stagedDirectories.insert(staged.directory)
        self.activeExport = nil
        self.syncControls()
        self.presentShareSheet(fileURL: staged.fileURL, stagedDirectory: staged.directory)
      } catch let error as ChatShareExportError where error == .tooLarge {
        self.activeExport = nil
        self.syncControls()
        LodyToastOverlay.shared.show(message: String(localized: "chat.shareImage.tooLarge", bundle: .lody), kind: .warning)
      } catch {
        self.activeExport = nil
        self.syncControls()
        LodyToastOverlay.shared.show(message: String(localized: "chat.shareImage.exportFailed", bundle: .lody), kind: .error)
      }
    }
  }

  private func presentShareSheet(fileURL: URL, stagedDirectory: URL) {
    let presenter = navigationController ?? parent ?? self
    guard presenter.presentedViewController == nil else {
      removeStagedDirectory(stagedDirectory)
      return
    }
    let activity = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
    if let popover = activity.popoverPresentationController {
      popover.sourceView = exportButton
      popover.sourceRect = exportButton.bounds
    }
    activity.completionWithItemsHandler = { [weak self] _, completed, _, error in
      MainActor.assumeIsolated {
        self?.removeStagedDirectory(stagedDirectory)
        guard let self else { return }
        if error != nil {
          LodyToastOverlay.shared.show(
            message: String(localized: "chat.shareImage.exportFailed", bundle: .lody),
            kind: .error
          )
          return
        }
        if completed {
          let onComplete = self.onCompleteShare
          self.dismissSheet {
            onComplete()
          }
        }
      }
    }
    presenter.present(activity, animated: true)
  }

  private func removeStagedDirectory(_ directory: URL) {
    stagedDirectories.remove(directory)
    ChatShareTempStore.removeDirectory(directory)
  }

  private func cleanupAllStagedFiles() {
    let dirs = stagedDirectories
    stagedDirectories.removeAll()
    for dir in dirs {
      ChatShareTempStore.removeDirectory(dir)
    }
  }

  private func closeSheetPreservingSelection() {
    cleanupAllStagedFiles()
    dismissSheet(completion: nil)
  }

  private func dismissSheet(completion: (() -> Void)?) {
    if let nav = navigationController, nav.presentingViewController != nil {
      nav.dismiss(animated: true, completion: completion)
    } else if let host = parent, host.presentingViewController != nil {
      host.dismiss(animated: true, completion: completion)
    } else if presentingViewController != nil {
      dismiss(animated: true, completion: completion)
    } else {
      LodyShell.shared.close(from: self)
      completion?()
    }
  }
}

@MainActor
private final class ChatShareBackdropSwatchButton: UIButton {
  private let backdropKind: ChatShareBackdrop
  private let ringView = UIView()
  private let swatchView = UIView()
  private let slashLayer = CAShapeLayer()
  private let swatchImage = UIImageView()

  init(backdrop: ChatShareBackdrop) {
    self.backdropKind = backdrop
    super.init(frame: .zero)
    accessibilityIdentifier = "chat.shareImage.backdrop." + backdrop.rawValue
    accessibilityLabel = backdrop.localizedName

    ringView.isUserInteractionEnabled = false
    ringView.backgroundColor = .clear
    ringView.layer.cornerRadius = 18
    ringView.layer.cornerCurve = .circular
    ringView.layer.borderWidth = 2
    addSubview(ringView)

    swatchView.isUserInteractionEnabled = false
    swatchView.clipsToBounds = true
    swatchView.layer.cornerRadius = 14
    swatchView.layer.cornerCurve = .circular
    swatchView.layer.borderWidth = 1
    addSubview(swatchView)

    swatchImage.isUserInteractionEnabled = false
    swatchImage.contentMode = .scaleAspectFill
    swatchImage.image = backdrop.previewImage()
    swatchView.addSubview(swatchImage)

    slashLayer.lineWidth = 1.5
    slashLayer.fillColor = nil
    swatchView.layer.addSublayer(slashLayer)

    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
      heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
    ])

    lodyObserveTraitChanges([.userInterfaceStyle]) { (button: ChatShareBackdropSwatchButton, _) in
      button.updateColors()
    }
    updateColors()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  func setSelectedState(_ selected: Bool) {
    isSelected = selected
    accessibilityTraits = selected ? [.button, .selected] : .button
    updateColors()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let ringSide: CGFloat = 36
    let swatchSide: CGFloat = 28
    ringView.frame = CGRect(
      x: round((bounds.width - ringSide) / 2),
      y: round((bounds.height - ringSide) / 2),
      width: ringSide,
      height: ringSide
    )
    swatchView.frame = CGRect(
      x: round((bounds.width - swatchSide) / 2),
      y: round((bounds.height - swatchSide) / 2),
      width: swatchSide,
      height: swatchSide
    )
    swatchImage.frame = swatchView.bounds
    if backdropKind == .none {
      let path = UIBezierPath()
      path.move(to: CGPoint(x: 6, y: swatchSide - 6))
      path.addLine(to: CGPoint(x: swatchSide - 6, y: 6))
      slashLayer.frame = swatchView.bounds
      slashLayer.path = path.cgPath
      slashLayer.isHidden = false
    } else {
      slashLayer.isHidden = true
    }
  }

  private func updateColors() {
    if isSelected {
      ringView.layer.borderColor = UIColor.lodyAccent.resolvedColor(with: traitCollection).cgColor
    } else {
      ringView.layer.borderColor = UIColor.clear.cgColor
    }
    swatchView.layer.borderColor = UIColor.lodyLine2.resolvedColor(with: traitCollection).cgColor
    if backdropKind == .none {
      swatchView.backgroundColor = UIColor.lodyInset.resolvedColor(with: traitCollection)
      slashLayer.strokeColor = UIColor.secondaryLabel.resolvedColor(with: traitCollection).cgColor
    } else {
      swatchView.backgroundColor = .clear
    }
  }
}

@MainActor
enum ChatShareImagePreviewFixture {
  static func makeController() -> ChatShareImageController {
    let quoteText = "Line 1 of quoted context\nLine 2 of quoted context\nLine 3 of quoted context\nLine 4 preserved without clipping"
    let userBody = "\(quoteText)\nWhy did @src/router.ts fail here?"
    let quoteRange = (userBody as NSString).range(of: quoteText)
    let fileRange = (userBody as NSString).range(of: "@src/router.ts")
    let payload = RuntimeContract.ConversationShareMessagesResultReady(
      title: "Fix native share card layout",
      createdAt: "2026-11-26T02:30:00.000Z",
      cliType: "builtin",
      agentType: "claude",
      agentName: nil,
      messages: [
        .init(
          id: "u1",
          role: .user,
          text: userBody,
          references: [
            .init(start: quoteRange.location, end: NSMaxRange(quoteRange), kind: "message_quote", label: "Quote", quote: quoteText),
            .init(start: fileRange.location, end: NSMaxRange(fileRange), kind: "file", label: "src/router.ts", target: "src/router.ts"),
          ],
          estimatedTokens: 320
        ),
        .init(
          id: "a1",
          role: .assistant,
          text: """
          The route table clipped wide blocks instead of wrapping them cleanly.

          ```diff
          --- a/src/router.ts
          +++ b/src/router.ts
          @@ -12,2 +12,2 @@
          -export const overflowMode = 'scroll-horizontal-clipped-container-that-exceeds-card-measure';
          +export const overflowMode = 'soft-wrap-unconditionally-inside-fixed-card-measure';
          ```
          """,
          estimatedTokens: 920,
          modelName: "Claude Sonnet 4.5",
          userTurnId: "u1"
        ),
      ]
    )
    let _ = try? WorkspaceModePins.shared.observe("preview-workspace", mode: .plaintext)
    return ChatShareImageController(
      payload: payload,
      selectedMessages: payload.messages,
      repository: "LodyAI/lody",
      isScopeValid: { WorkspaceModePins.shared.mode("preview-workspace") == .plaintext },
      onCompleteShare: {}
    )
  }
}
