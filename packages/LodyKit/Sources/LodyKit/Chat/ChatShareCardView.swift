import ChatKit
import CoreGraphics
import CoreText
import Litext
import LodyCore
import LodyDesignSystem
import MarkdownParser
import MarkdownView
import UIKit

enum ChatShareDestination: String, CaseIterable, Sendable {
  case chat
  case post

  struct Layout: Equatable, Sendable {
    let width: CGFloat
    let radius: CGFloat
    let gutter: CGFloat
    let top: CGFloat
    let afterTitle: CGFloat
    let bottom: CGFloat
    let exchangeGap: CGFloat
    let replyGap: CGFloat
    let promptRadius: CGFloat
    let promptPadH: CGFloat
    let promptPadV: CGFloat
    let captionPadV: CGFloat
    let signatureTop: CGFloat
    let titleSize: CGFloat
    let defaultMat: Int
  }

  var layout: Layout {
    switch self {
    case .chat:
      return Layout(
        width: 360,
        radius: 22,
        gutter: 20,
        top: 24,
        afterTitle: 16,
        bottom: 20,
        exchangeGap: 24,
        replyGap: 12,
        promptRadius: 14,
        promptPadH: 14,
        promptPadV: 10,
        captionPadV: 14,
        signatureTop: 16,
        titleSize: 17,
        defaultMat: 16
      )
    case .post:
      return Layout(
        width: 560,
        radius: 26,
        gutter: 28,
        top: 28,
        afterTitle: 20,
        bottom: 24,
        exchangeGap: 28,
        replyGap: 14,
        promptRadius: 16,
        promptPadH: 16,
        promptPadV: 12,
        captionPadV: 16,
        signatureTop: 20,
        titleSize: 20,
        defaultMat: 56
      )
    }
  }
}

enum ChatShareBackdrop: String, CaseIterable, Sendable {
  case none
  case lody
  case welcome
  case aurora
  case ocean
  case sunset

  var usesLightSignOffInk: Bool {
    self == .welcome
  }

  var signOffInkColor: UIColor {
    if usesLightSignOffInk {
      return UIColor(red: 32 / 255, green: 66 / 255, blue: 76 / 255, alpha: 0.78)
    }
    return UIColor(white: 1, alpha: 0.85)
  }

  var localizedName: String {
    String(localized: String.LocalizationValue("chat.shareImage.backdrop." + rawValue), bundle: .lody)
  }

  func draw(in context: CGContext, rect: CGRect) {
    guard rect.width > 0, rect.height > 0, self != .none else { return }
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    context.saveGState()
    context.clip(to: rect)

    func linear(_ colors: [(UInt32, CGFloat)], locations: [CGFloat], start: CGPoint, end: CGPoint) {
      let cgColors = colors.map { Self.rgb($0.0, alpha: $0.1).cgColor } as CFArray
      guard let gradient = CGGradient(colorsSpace: space, colors: cgColors, locations: locations) else { return }
      context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    func radial(center: CGPoint, radius: CGFloat, inner: (UInt32, CGFloat), outer: (UInt32, CGFloat) = (0x000000, 0)) {
      guard radius > 0 else { return }
      let cgColors = [Self.rgb(inner.0, alpha: inner.1).cgColor, Self.rgb(outer.0, alpha: outer.1).cgColor] as CFArray
      let locs: [CGFloat] = [0, 1]
      guard let gradient = CGGradient(colorsSpace: space, colors: cgColors, locations: locs) else { return }
      context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    let minX = rect.minX
    let minY = rect.minY
    let w = rect.width
    let h = rect.height
    let span = max(w, h)

    switch self {
    case .none:
      break
    case .lody:
      linear(
        [(0x07161B, 1), (0x0C2438, 1), (0x081626, 1)],
        locations: [0, 0.55, 1],
        start: CGPoint(x: minX + w * 0.15, y: minY),
        end: CGPoint(x: minX + w * 0.85, y: minY + h)
      )
      radial(center: CGPoint(x: minX + w * 0.18, y: minY + h * 0.12), radius: span * 0.52, inner: (0x2396AD, 0.45))
      radial(center: CGPoint(x: minX + w * 0.86, y: minY + h * 0.16), radius: span * 0.48, inner: (0x2F77BF, 0.48))
      radial(center: CGPoint(x: minX + w * 0.68, y: minY + h * 0.94), radius: span * 0.62, inner: (0x1F4F7F, 0.60))
      radial(center: CGPoint(x: minX + w * 0.78, y: minY + h * 0.88), radius: span * 0.36, inner: (0xFFB450, 0.16))
    case .welcome:
      linear(
        [(0xF3FAFB, 1), (0xECF7F9, 1), (0xF8FBFD, 1)],
        locations: [0, 0.52, 1],
        start: CGPoint(x: minX, y: minY),
        end: CGPoint(x: minX, y: minY + h)
      )
      radial(center: CGPoint(x: minX + w * 0.18, y: minY + h * 0.18), radius: span * 0.46, inner: (0xFFFFFF, 0.65))
      radial(center: CGPoint(x: minX + w * 0.82, y: minY + h * 0.72), radius: span * 0.56, inner: (0x2A5D6F, 0.14))
      radial(center: CGPoint(x: minX + w * 0.75, y: minY + h * 0.20), radius: span * 0.34, inner: (0xFFB450, 0.08))
      context.setStrokeColor(UIColor(red: 25 / 255, green: 58 / 255, blue: 68 / 255, alpha: 0.09).cgColor)
      context.setLineWidth(1)
      var gridX = minX + 44
      while gridX < rect.maxX {
        context.move(to: CGPoint(x: gridX + 0.5, y: minY))
        context.addLine(to: CGPoint(x: gridX + 0.5, y: rect.maxY))
        gridX += 88
      }
      context.strokePath()
    case .aurora:
      linear(
        [(0x0C0F1D, 1), (0x151B38, 1), (0x1F1836, 1)],
        locations: [0, 0.5, 1],
        start: CGPoint(x: minX, y: minY),
        end: CGPoint(x: minX + w, y: minY + h)
      )
      radial(center: CGPoint(x: minX + w * 0.18, y: minY + h * 0.16), radius: span * 0.55, inner: (0x4F46E5, 0.52))
      radial(center: CGPoint(x: minX + w * 0.82, y: minY + h * 0.45), radius: span * 0.55, inner: (0x7C3AED, 0.46))
      radial(center: CGPoint(x: minX + w * 0.30, y: minY + h * 0.88), radius: span * 0.50, inner: (0x10B981, 0.28))
    case .ocean:
      linear(
        [(0x0B2239, 1), (0x114B5F, 1), (0x1A759F, 1)],
        locations: [0, 0.52, 1],
        start: CGPoint(x: minX, y: minY),
        end: CGPoint(x: minX + w, y: minY + h)
      )
      radial(center: CGPoint(x: minX + w * 0.78, y: minY + h * 0.20), radius: span * 0.52, inner: (0x38BDF8, 0.36))
      radial(center: CGPoint(x: minX + w * 0.24, y: minY + h * 0.86), radius: span * 0.48, inner: (0x34D399, 0.24))
    case .sunset:
      linear(
        [(0x2B162C, 1), (0x6B2D5C, 1), (0xC85A32, 1), (0xE8985E, 1)],
        locations: [0, 0.36, 0.72, 1],
        start: CGPoint(x: minX, y: minY),
        end: CGPoint(x: minX + w, y: minY + h)
      )
      radial(center: CGPoint(x: minX + w * 0.80, y: minY + h * 0.82), radius: span * 0.45, inner: (0xF59E0B, 0.28))
    }

    context.restoreGState()
  }

  @MainActor
  private static var previewCache: [ChatShareBackdrop: UIImage] = [:]

  @MainActor
  func previewImage() -> UIImage? {
    guard self != .none else { return nil }
    if let cached = Self.previewCache[self] { return cached }
    let size = CGSize(width: 360, height: 480)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 2
    format.preferredRange = .standard
    format.opaque = true
    let image = UIGraphicsImageRenderer(size: size, format: format).image { rendererContext in
      draw(in: rendererContext.cgContext, rect: CGRect(origin: .zero, size: size))
    }
    Self.previewCache[self] = image
    return image
  }

  fileprivate static func rgb(_ value: UInt32, alpha: CGFloat = 1) -> UIColor {
    UIColor(
      red: CGFloat((value >> 16) & 0xFF) / 255,
      green: CGFloat((value >> 8) & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255,
      alpha: alpha
    )
  }
}

enum ChatShareTheme: String, CaseIterable, Sendable {
  case light
  case dark

  var userInterfaceStyle: UIUserInterfaceStyle {
    self == .dark ? .dark : .light
  }

  func scopedTraits() -> UITraitCollection {
    let base = UITraitCollection(userInterfaceStyle: userInterfaceStyle)
    if #available(iOS 17.0, *) {
      return base.modifyingTraits {
        $0.preferredContentSizeCategory = .large
        $0.accessibilityContrast = .normal
      }
    }
    return UITraitCollection(traitsFrom: [
      base,
      UITraitCollection(preferredContentSizeCategory: .large),
      UITraitCollection(accessibilityContrast: .normal),
    ])
  }

  struct Palette {
    let cardBackground: UIColor
    let foreground: UIColor
    let secondaryForeground: UIColor
    let hairline: UIColor
    let cardRing: UIColor
    let promptFill: UIColor
    let promptBorder: UIColor
    let codeBlockFill: UIColor
    let codeBlockBorder: UIColor
    let inlineCodeFill: UIColor
    let inlineCodeInk: UIColor
    let linkColor: UIColor
    let mentionInk: UIColor
    let mentionChipFill: UIColor
    let quoteBar: UIColor
    let diffAddText: UIColor
    let diffAddFill: UIColor
    let diffDelText: UIColor
    let diffDelFill: UIColor
  }

  var palette: Palette {
    switch self {
    case .light:
      return Palette(
        cardBackground: ChatShareBackdrop.rgb(0xFFFFFF),
        foreground: ChatShareBackdrop.rgb(0x18181B),
        secondaryForeground: ChatShareBackdrop.rgb(0x6B6B73),
        hairline: UIColor(white: 0, alpha: 0.08),
        cardRing: UIColor(white: 0, alpha: 0.06),
        promptFill: UIColor(white: 0, alpha: 0.045),
        promptBorder: UIColor(white: 0, alpha: 0.07),
        codeBlockFill: ChatShareBackdrop.rgb(0xF4F4F6),
        codeBlockBorder: UIColor(white: 0, alpha: 0.07),
        inlineCodeFill: UIColor(white: 0, alpha: 0.055),
        inlineCodeInk: ChatShareBackdrop.rgb(0x3F3F46),
        linkColor: UIColor(red: 0.0952, green: 0.4216, blue: 0.5848, alpha: 1),
        mentionInk: ChatShareBackdrop.rgb(0x18181B),
        mentionChipFill: UIColor(white: 0, alpha: 0.08),
        quoteBar: UIColor(white: 0, alpha: 0.22),
        diffAddText: UIColor(red: 0.08, green: 0.48, blue: 0.22, alpha: 1),
        diffAddFill: UIColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 0.12),
        diffDelText: UIColor(red: 0.72, green: 0.14, blue: 0.18, alpha: 1),
        diffDelFill: UIColor(red: 0.94, green: 0.27, blue: 0.27, alpha: 0.12)
      )
    case .dark:
      return Palette(
        cardBackground: ChatShareBackdrop.rgb(0x161618),
        foreground: ChatShareBackdrop.rgb(0xF2F2F5),
        secondaryForeground: ChatShareBackdrop.rgb(0x9A9AA3),
        hairline: UIColor(white: 1, alpha: 0.10),
        cardRing: UIColor(white: 1, alpha: 0.10),
        promptFill: UIColor(white: 1, alpha: 0.07),
        promptBorder: UIColor(white: 1, alpha: 0.10),
        codeBlockFill: ChatShareBackdrop.rgb(0x1F1F23),
        codeBlockBorder: UIColor(white: 1, alpha: 0.08),
        inlineCodeFill: UIColor(white: 1, alpha: 0.09),
        inlineCodeInk: ChatShareBackdrop.rgb(0xE4E4EA),
        linkColor: UIColor(red: 0.493, green: 0.769, blue: 0.907, alpha: 1),
        mentionInk: ChatShareBackdrop.rgb(0xF2F2F5),
        mentionChipFill: UIColor(white: 1, alpha: 0.13),
        quoteBar: UIColor(white: 1, alpha: 0.28),
        diffAddText: UIColor(red: 0.38, green: 0.88, blue: 0.54, alpha: 1),
        diffAddFill: UIColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 0.16),
        diffDelText: UIColor(red: 0.97, green: 0.48, blue: 0.48, alpha: 1),
        diffDelFill: UIColor(red: 0.94, green: 0.27, blue: 0.27, alpha: 0.16)
      )
    }
  }
}

struct ChatShareCardMeta: Equatable, Sendable {
  var name: String
  var cliType: String?
  var agentType: String?
  var params: [String]
  var date: String?
}

struct ChatShareConfiguration: Equatable, Sendable {
  var messages: [RuntimeContract.ConversationShareMessage]
  var title: String?
  var destination: ChatShareDestination
  var mat: Int
  var theme: ChatShareTheme
  var backdrop: ChatShareBackdrop
  var meta: ChatShareCardMeta
  var repository: String = ""

  var effectiveMat: Int {
    ChatShareCardFormatting.effectiveMat(backdrop: backdrop, mat: mat)
  }

  var signOffOnMat: Bool {
    ChatShareCardFormatting.signOffOnMat(backdrop: backdrop, mat: mat)
  }
}

enum ChatShareCardFormatting {
  static let minMat = 0
  static let maxMat = 96
  static let matStep = 4
  static let minSignOffMat = 12
  static let bodyFontSize: CGFloat = 15

  static func effectiveMat(backdrop: ChatShareBackdrop, mat: Int) -> Int {
    if backdrop == .none { return 0 }
    return max(minMat, min(maxMat, mat))
  }

  static func signOffOnMat(backdrop: ChatShareBackdrop, mat: Int) -> Bool {
    guard backdrop != .none else { return false }
    return effectiveMat(backdrop: backdrop, mat: mat) >= minSignOffMat
  }

  static func snapMat(_ raw: Float) -> Int {
    let stepped = Int((raw / Float(matStep)).rounded()) * matStep
    return max(minMat, min(maxMat, stepped))
  }

  static func orderedMessages(
    from allMessages: [RuntimeContract.ConversationShareMessage],
    selectedIDs: Set<String>
  ) -> [RuntimeContract.ConversationShareMessage] {
    allMessages.filter { selectedIDs.contains($0.id) }
  }

  static func verticalGap(
    at index: Int,
    in messages: [RuntimeContract.ConversationShareMessage],
    destination: ChatShareDestination
  ) -> CGFloat {
    guard index > 0, index < messages.count else { return 0 }
    let current = messages[index]
    let previous = messages[index - 1]
    let layout = destination.layout
    guard current.role == .assistant, previous.role == .user else {
      return layout.exchangeGap
    }
    let turnID = current.userTurnId?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let turnID, !turnID.isEmpty {
      return turnID == previous.id ? layout.replyGap : layout.exchangeGap
    }
    return layout.replyGap
  }

  static func compactTokens(_ total: Double) -> String {
    let count = max(0, Int(total.rounded()))
    if count < 1_000 {
      return "\(count)"
    }
    if count < 10_000 {
      let tenths = Int((Double(count) / 100.0).rounded())
      if tenths >= 100 { return "10k" }
      if tenths % 10 == 0 { return "\(tenths / 10)k" }
      return "\(tenths / 10).\(tenths % 10)k"
    }
    if count < 1_000_000 {
      let thousands = Int((Double(count) / 1_000.0).rounded())
      if thousands >= 1_000 { return "1M" }
      return "\(thousands)k"
    }
    if count < 10_000_000 {
      let tenths = Int((Double(count) / 100_000.0).rounded())
      if tenths >= 100 { return "10M" }
      if tenths % 10 == 0 { return "\(tenths / 10)M" }
      return "\(tenths / 10).\(tenths % 10)M"
    }
    let millions = Int((Double(count) / 1_000_000.0).rounded())
    return "\(millions)M"
  }

  static func formatCreatedAt(_ raw: String?, timeZone: TimeZone = .current) -> String? {
    let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    var resolvedDate: Date?

    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    resolvedDate = fractional.date(from: trimmed)

    if resolvedDate == nil {
      let plain = ISO8601DateFormatter()
      plain.formatOptions = [.withInternetDateTime]
      resolvedDate = plain.date(from: trimmed)
    }

    if resolvedDate == nil, let numeric = Double(trimmed), numeric.isFinite, numeric > 0 {
      let seconds = numeric > 1_000_000_000_000 ? numeric / 1_000.0 : numeric
      resolvedDate = Date(timeIntervalSince1970: seconds)
    }

    guard let date = resolvedDate else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
  }

  static func makeMeta(
    from payload: RuntimeContract.ConversationShareMessagesResultReady,
    selectedMessages: [RuntimeContract.ConversationShareMessage],
    timeZone: TimeZone = .current
  ) -> ChatShareCardMeta {
    let customName = (payload.agentName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedName: String
    if !customName.isEmpty {
      resolvedName = customName
    } else {
      resolvedName = LodyAgentIcon.displayName(cliType: payload.cliType, agentType: payload.agentType)
    }

    let lastModel = selectedMessages.reversed().compactMap { message -> String? in
      guard message.role == .assistant else { return nil }
      let trimmed = (message.modelName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }.first

    var params: [String] = []
    if let lastModel {
      params.append(lastModel)
    }
    let totalTokens = selectedMessages.reduce(0.0) { $0 + max(0, $1.estimatedTokens) }
    if Int(totalTokens.rounded()) > 0 {
      let compact = compactTokens(totalTokens)
      let label = String.localizedStringWithFormat(
        String(localized: "chat.shareImage.tokensApprox", bundle: .lody),
        compact
      )
      params.append(label)
    }

    let formattedDate = formatCreatedAt(payload.createdAt, timeZone: timeZone)
    return ChatShareCardMeta(
      name: resolvedName,
      cliType: payload.cliType,
      agentType: payload.agentType,
      params: params,
      date: formattedDate
    )
  }
}

@MainActor
final class ChatShareCardView: UIView {
  private let backdropImageView = UIImageView()
  private let cardShadowView = UIView()
  let cardSurfaceView = UIView()
  private let cardRingView = UIView()
  private let signOffContainer = UIView()
  private var appliedConfiguration: ChatShareConfiguration?

  var showsPreviewBackdropImage: Bool = true {
    didSet { backdropImageView.isHidden = !showsPreviewBackdropImage || appliedConfiguration?.backdrop == .none }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    clipsToBounds = false
    accessibilityIdentifier = "chat.shareImage.card"

    backdropImageView.contentMode = .scaleToFill
    backdropImageView.clipsToBounds = true
    addSubview(backdropImageView)

    cardShadowView.backgroundColor = .clear
    addSubview(cardShadowView)

    cardSurfaceView.clipsToBounds = true
    cardSurfaceView.layer.cornerCurve = .continuous
    addSubview(cardSurfaceView)

    cardRingView.isUserInteractionEnabled = false
    cardRingView.backgroundColor = .clear
    cardRingView.layer.cornerCurve = .continuous
    cardRingView.layer.borderWidth = 1
    addSubview(cardRingView)

    signOffContainer.isUserInteractionEnabled = false
    signOffContainer.backgroundColor = .clear
    addSubview(signOffContainer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  @discardableResult
  func configure(_ config: ChatShareConfiguration) -> CGSize {
    if appliedConfiguration == config, bounds.size != .zero {
      return bounds.size
    }
    appliedConfiguration = config
    let traits = config.theme.scopedTraits()
    overrideUserInterfaceStyle = config.theme.userInterfaceStyle
    if #available(iOS 17.0, *) {
      traitOverrides.userInterfaceStyle = config.theme.userInterfaceStyle
      traitOverrides.preferredContentSizeCategory = .large
      traitOverrides.accessibilityContrast = .normal
    }

    var computedSize: CGSize = .zero
    traits.performAsCurrent {
      computedSize = rebuild(config, traits: traits)
    }
    return computedSize
  }

  private func rebuild(_ config: ChatShareConfiguration, traits: UITraitCollection) -> CGSize {
    for subview in cardSurfaceView.subviews { subview.removeFromSuperview() }
    for subview in signOffContainer.subviews { subview.removeFromSuperview() }

    let layout = config.destination.layout
    let palette = config.theme.palette
    let mat = CGFloat(config.effectiveMat)
    let signOffOnMat = config.signOffOnMat
    let cardWidth = layout.width
    let innerWidth = cardWidth - layout.gutter * 2

    cardSurfaceView.backgroundColor = palette.cardBackground
    cardSurfaceView.layer.cornerRadius = layout.radius
    cardRingView.layer.cornerRadius = layout.radius
    cardRingView.layer.borderColor = palette.cardRing.cgColor

    var y: CGFloat = layout.top
    let trimmedTitle = (config.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedTitle.isEmpty {
      let titleLabel = UILabel()
      titleLabel.numberOfLines = 2
      titleLabel.lineBreakMode = .byTruncatingTail
      let titleFont = UIFont.systemFont(ofSize: layout.titleSize, weight: .semibold)
      let paragraph = NSMutableParagraphStyle()
      paragraph.minimumLineHeight = round(layout.titleSize * 1.35)
      paragraph.maximumLineHeight = round(layout.titleSize * 1.35)
      paragraph.lineBreakMode = .byTruncatingTail
      titleLabel.attributedText = NSAttributedString(
        string: trimmedTitle,
        attributes: [
          .font: titleFont,
          .foregroundColor: palette.foreground,
          .kern: -0.35,
          .paragraphStyle: paragraph,
        ]
      )
      let titleSize = titleLabel.sizeThatFits(CGSize(width: innerWidth, height: .greatestFiniteMagnitude))
      let titleHeight = ceil(titleSize.height)
      titleLabel.frame = CGRect(x: layout.gutter, y: y, width: innerWidth, height: titleHeight)
      cardSurfaceView.addSubview(titleLabel)
      y += titleHeight + layout.afterTitle
    }

    for (index, message) in config.messages.enumerated() {
      y += ChatShareCardFormatting.verticalGap(at: index, in: config.messages, destination: config.destination)
      let turnView: UIView
      if message.role == .user {
        turnView = buildUserPromptView(
          message: message,
          width: innerWidth,
          layout: layout,
          palette: palette,
          traits: traits,
          repository: config.repository
        )
      } else {
        turnView = buildAssistantTurnView(
          message: message,
          width: innerWidth,
          palette: palette,
          traits: traits
        )
      }
      turnView.frame.origin = CGPoint(x: layout.gutter, y: y)
      cardSurfaceView.addSubview(turnView)
      y += turnView.bounds.height
    }

    y += layout.bottom

    let divider = UIView(frame: CGRect(x: 0, y: y, width: cardWidth, height: 1))
    divider.backgroundColor = palette.hairline
    cardSurfaceView.addSubview(divider)
    y += 1

    let captionView = buildCaptionView(
      meta: config.meta,
      width: innerWidth,
      padV: layout.captionPadV,
      signOffOnMat: signOffOnMat,
      palette: palette
    )
    captionView.frame.origin = CGPoint(x: layout.gutter, y: y)
    cardSurfaceView.addSubview(captionView)
    y += captionView.bounds.height

    let cardHeight = ceil(y)
    let cardFrame = CGRect(x: mat, y: mat, width: cardWidth, height: cardHeight)
    cardSurfaceView.frame = cardFrame
    cardRingView.frame = cardFrame
    cardShadowView.frame = cardFrame

    if signOffOnMat {
      cardShadowView.layer.shadowColor = UIColor(red: 2 / 255, green: 10 / 255, blue: 18 / 255, alpha: 1).cgColor
      cardShadowView.layer.shadowOpacity = 0.45
      cardShadowView.layer.shadowRadius = 24
      cardShadowView.layer.shadowOffset = CGSize(width: 0, height: 14)
      cardShadowView.layer.shadowPath = UIBezierPath(roundedRect: CGRect(origin: .zero, size: cardFrame.size), cornerRadius: layout.radius).cgPath
    } else {
      cardShadowView.layer.shadowOpacity = 0
      cardShadowView.layer.shadowPath = nil
    }

    let outerWidth = cardWidth + mat * 2
    var outerHeight = cardFrame.maxY + mat

    if signOffOnMat {
      signOffContainer.isHidden = false
      let signOff = buildBackdropSignOff(backdrop: config.backdrop)
      let signOffY = cardFrame.maxY + layout.signatureTop
      signOff.frame.origin = CGPoint(x: round((outerWidth - signOff.bounds.width) / 2), y: signOffY)
      signOffContainer.frame = CGRect(x: 0, y: signOffY, width: outerWidth, height: signOff.bounds.height)
      signOff.frame.origin.y = 0
      signOffContainer.addSubview(signOff)
      outerHeight = signOffContainer.frame.maxY + mat
    } else {
      signOffContainer.isHidden = true
      signOffContainer.frame = .zero
    }

    let totalSize = CGSize(width: ceil(outerWidth), height: ceil(outerHeight))
    frame = CGRect(origin: frame.origin, size: totalSize)
    backdropImageView.frame = CGRect(origin: .zero, size: totalSize)
    backdropImageView.image = config.backdrop.previewImage()
    backdropImageView.isHidden = !showsPreviewBackdropImage || config.backdrop == .none
    backgroundColor = .clear
    return totalSize
  }

  func renderedTextFragments() -> [String] {
    var result: [String] = []
    func collect(_ view: UIView) {
      if let label = view as? UILabel {
        if let text = label.attributedText?.string, !text.isEmpty { result.append(text) }
        else if let text = label.text, !text.isEmpty { result.append(text) }
      } else if let ck = view as? CKTextView {
        let text = ck.attributedTextValue.string
        if !text.isEmpty { result.append(text) }
      } else if let litext = view as? TextLabelView {
        let text = litext.attributedText.string
        if !text.isEmpty { result.append(text) }
      }
      for child in view.subviews { collect(child) }
    }
    collect(self)
    return result
  }

  private func buildUserPromptView(
    message: RuntimeContract.ConversationShareMessage,
    width: CGFloat,
    layout: ChatShareDestination.Layout,
    palette: ChatShareTheme.Palette,
    traits: UITraitCollection,
    repository: String
  ) -> UIView {
    let box = UIView()
    box.backgroundColor = palette.promptFill
    box.layer.cornerRadius = layout.promptRadius
    box.layer.cornerCurve = .continuous
    box.layer.borderWidth = 1
    box.layer.borderColor = palette.promptBorder.cgColor

    let textWidth = max(1, width - layout.promptPadH * 2)
    let font = UIFont.systemFont(ofSize: ChatShareCardFormatting.bodyFontSize)
    let lineHeight: CGFloat = 23
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = lineHeight
    paragraph.maximumLineHeight = lineHeight
    paragraph.lineBreakMode = .byWordWrapping

    let base = NSAttributedString(
      string: message.text,
      attributes: [
        .font: font,
        .foregroundColor: palette.foreground,
        .paragraphStyle: paragraph,
        .baselineOffset: (lineHeight - font.lineHeight) / 2,
      ]
    )

    let references = (message.references ?? []).map { ref in
      ChatTextReference(
        start: ref.start,
        end: ref.end,
        kind: ref.kind,
        target: ref.target,
        quote: ref.quote
      )
    }

    let decorated = ChatUserMentions.decorate(
      base,
      references: references,
      repository: repository,
      traits: traits,
      expandQuotes: true,
      accentColor: palette.mentionInk,
      chipFill: palette.mentionChipFill,
      quoteColor: palette.secondaryForeground
    )

    let slices = Self.sliceAttributedString(decorated, maxCharsPerSlice: 2_400)
    var innerY = layout.promptPadV
    for (sliceIndex, slice) in slices.enumerated() {
      if sliceIndex > 0 { innerY += 4 }
      let chips = ChatReferenceChipsView()
      chips.quoteBarColor = palette.quoteBar
      let label = CKTextView()
      label.isUserInteractionEnabled = false
      label.setText(slice, animate: false, reset: true)
      let fitted = label.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))
      let sliceHeight = max(lineHeight, ceil(fitted.height))
      let sliceContainer = UIView(frame: CGRect(x: layout.promptPadH, y: innerY, width: textWidth, height: sliceHeight))
      label.frame = sliceContainer.bounds
      label.linkHitHeight = sliceHeight
      chips.frame = sliceContainer.bounds
      chips.update(label: label)
      sliceContainer.addSubview(chips)
      sliceContainer.addSubview(label)
      box.addSubview(sliceContainer)
      innerY += sliceHeight
    }

    let boxHeight = ceil(innerY + layout.promptPadV)
    box.frame = CGRect(x: 0, y: 0, width: width, height: boxHeight)
    return box
  }

  private func buildAssistantTurnView(
    message: RuntimeContract.ConversationShareMessage,
    width: CGFloat,
    palette: ChatShareTheme.Palette,
    traits: UITraitCollection
  ) -> UIView {
    let container = UIView()
    var theme = MarkdownTheme()
    let bodyFont = UIFont.systemFont(ofSize: ChatShareCardFormatting.bodyFontSize)
    theme.fonts.body = bodyFont
    theme.fonts.bold = bodyFont.bold
    theme.fonts.italic = bodyFont.italic
    theme.fonts.code = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
    theme.fonts.codeInline = .monospacedSystemFont(ofSize: 13.5, weight: .regular)
    theme.fonts.title = .systemFont(ofSize: 17, weight: .semibold)
    theme.fonts.largeTitle = .systemFont(ofSize: 20, weight: .semibold)
    theme.fonts.footnote = .systemFont(ofSize: 13, weight: .regular)
    theme.colors.body = palette.foreground
    theme.colors.code = palette.inlineCodeInk
    theme.colors.highlight = palette.linkColor
    theme.colors.emphasis = palette.foreground
    theme.colors.codeBackground = palette.inlineCodeFill
    theme.colors.codeBlockBackground = palette.codeBlockFill
    theme.colors.codeBlockBarBackground = .clear
    theme.colors.selectionBackground = nil
    theme.table.headerBackgroundColor = palette.promptFill
    theme.table.borderColor = palette.hairline
    theme.spacings.paragraph = 10
    theme.spacings.headingBefore = 14
    theme.spacings.final = 0

    let parsed = MarkdownParser().parse(message.text)
    let rubyBlocks = MarkdownRuby.blocks(parsed.document)
    let mermaidBlocks = MarkdownMermaid.blocks(rubyBlocks)
    let rendered = parsed.renderedContent(theme: theme)
    let highlights = parsed.highlightMaps(theme: theme)

    var y: CGFloat = 0
    for (blockIndex, rawBlock) in mermaidBlocks.enumerated() {
      if blockIndex > 0 {
        if case .heading = rawBlock {
          y += 14
        } else {
          y += 10
        }
      }

      if case let .codeBlock(language, source) = rawBlock {
        let codeView = ChatShareCodeBlockView.make(
          language: language,
          source: source,
          width: width,
          theme: theme,
          palette: palette,
          traits: traits
        )
        codeView.frame.origin = CGPoint(x: 0, y: y)
        container.addSubview(codeView)
        y += codeView.bounds.height
        continue
      }

      var nestedCode: [String: (String?, String)] = [:]
      let rewritten = [rawBlock].rewrite { (node: MarkdownBlockNode) -> [MarkdownBlockNode] in
        guard case let .codeBlock(language, source) = node else { return [node] }
        let key = "\u{F0000}share-nested-code:\(nestedCode.count)"
        nestedCode[key] = (language, source)
        return [.paragraph(content: [.text(key)])]
      }
      let prepared = FileMarkdownView.content(
        MarkdownContent(blocks: rewritten, rendered: rendered, highlightMaps: highlights)
      )

      let blockView = ShareCardMarkdownBlockView(
        printWidth: width,
        nestedCode: nestedCode,
        palette: palette,
        scopedTraits: traits
      )
      blockView.overrideUserInterfaceStyle = traits.userInterfaceStyle
      blockView.isUserInteractionEnabled = false
      UIView.performWithoutAnimation {
        blockView.setContentImmediately(prepared, theme: theme)
      }

      var layoutWidth = max(1, width)
      for _ in 0..<4 {
        let measured = blockView.boundingSize(for: layoutWidth).height
        let safeHeight = measured.isFinite ? max(1, measured) : 20
        blockView.frame = CGRect(x: 0, y: 0, width: layoutWidth, height: safeHeight)
        blockView.layoutIfNeeded()
        let overflow = Self.horizontalOverflow(blockView)
        if overflow <= 1 { break }
        layoutWidth = min(2_400, layoutWidth + overflow)
      }

      let scale = min(1, width / max(1, layoutWidth))
      let scaledHeight = ceil(blockView.bounds.height * scale)
      let wrapper = UIView(frame: CGRect(x: 0, y: y, width: width, height: scaledHeight))
      if scale < 0.999 {
        blockView.transform = CGAffineTransform(scaleX: scale, y: scale)
      }
      blockView.frame.origin = .zero
      wrapper.addSubview(blockView)
      container.addSubview(wrapper)
      y += scaledHeight
    }

    container.frame = CGRect(x: 0, y: 0, width: width, height: max(1, ceil(y)))
    return container
  }

  private func buildCaptionView(
    meta: ChatShareCardMeta,
    width: CGFloat,
    padV: CGFloat,
    signOffOnMat: Bool,
    palette: ChatShareTheme.Palette
  ) -> UIView {
    let caption = UIView()
    let markSide: CGFloat = 18
    let markView = Self.makeAgentMarkView(
      cliType: meta.cliType,
      agentType: meta.agentType,
      side: markSide,
      tintColor: palette.foreground
    )

    let nameLabel = UILabel()
    nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    nameLabel.textColor = palette.foreground
    nameLabel.lineBreakMode = .byTruncatingTail
    nameLabel.numberOfLines = 1
    nameLabel.text = meta.name

    var subLabel: UILabel?
    if !signOffOnMat {
      let label = UILabel()
      label.font = .systemFont(ofSize: 10.5, weight: .regular)
      label.textColor = palette.secondaryForeground
      label.lineBreakMode = .byTruncatingTail
      label.numberOfLines = 1
      label.text = "lody.ai"
      subLabel = label
    }

    let maxRightWidth = floor(width * 0.62)
    var paramsLabel: UILabel?
    let nonEmptyParams = meta.params.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    if !nonEmptyParams.isEmpty {
      let label = UILabel()
      label.font = UIFont.systemFont(ofSize: 12, weight: .medium).withTabularNumbers()
      label.textColor = palette.foreground
      label.textAlignment = .right
      label.lineBreakMode = .byTruncatingTail
      label.numberOfLines = 1
      label.text = nonEmptyParams.joined(separator: " · ")
      paramsLabel = label
    }

    var dateLabel: UILabel?
    if let date = meta.date, !date.isEmpty {
      let label = UILabel()
      label.font = UIFont.systemFont(ofSize: 10.5, weight: .regular).withTabularNumbers()
      label.textColor = palette.secondaryForeground
      label.textAlignment = .right
      label.lineBreakMode = .byTruncatingTail
      label.numberOfLines = 1
      label.text = date
      dateLabel = label
    }

    var rightWidth: CGFloat = 0
    var rightHeight: CGFloat = 0
    let paramsSize = paramsLabel?.sizeThatFits(CGSize(width: maxRightWidth, height: 30)) ?? .zero
    let dateSize = dateLabel?.sizeThatFits(CGSize(width: maxRightWidth, height: 30)) ?? .zero
    rightWidth = min(maxRightWidth, ceil(max(paramsSize.width, dateSize.width)))
    if paramsLabel != nil { rightHeight += ceil(paramsSize.height) }
    if dateLabel != nil {
      if rightHeight > 0 { rightHeight += 2 }
      rightHeight += ceil(dateSize.height)
    }

    let leftX = markSide + 10
    let rightGap: CGFloat = rightWidth > 0 ? 12 : 0
    let leftAvailable = max(40, width - leftX - rightWidth - rightGap)
    let nameHeight = ceil(nameLabel.sizeThatFits(CGSize(width: leftAvailable, height: 30)).height)
    var leftHeight = nameHeight
    let subHeight: CGFloat
    if let subLabel {
      subHeight = ceil(subLabel.sizeThatFits(CGSize(width: leftAvailable, height: 24)).height)
      leftHeight += 2 + subHeight
    } else {
      subHeight = 0
    }

    let innerHeight = max(markSide, max(leftHeight, rightHeight))
    let totalHeight = ceil(innerHeight + padV * 2)
    caption.frame = CGRect(x: 0, y: 0, width: width, height: totalHeight)

    markView.frame = CGRect(x: 0, y: round((totalHeight - markSide) / 2), width: markSide, height: markSide)
    caption.addSubview(markView)

    let leftTop = round((totalHeight - leftHeight) / 2)
    nameLabel.frame = CGRect(x: leftX, y: leftTop, width: leftAvailable, height: nameHeight)
    caption.addSubview(nameLabel)
    if let subLabel {
      subLabel.frame = CGRect(x: leftX, y: nameLabel.frame.maxY + 2, width: leftAvailable, height: subHeight)
      caption.addSubview(subLabel)
    }

    if rightWidth > 0 {
      var rightY = round((totalHeight - rightHeight) / 2)
      let rightX = width - rightWidth
      if let paramsLabel {
        let h = ceil(paramsSize.height)
        paramsLabel.frame = CGRect(x: rightX, y: rightY, width: rightWidth, height: h)
        caption.addSubview(paramsLabel)
        rightY += h + 2
      }
      if let dateLabel {
        let h = ceil(dateSize.height)
        dateLabel.frame = CGRect(x: rightX, y: rightY, width: rightWidth, height: h)
        caption.addSubview(dateLabel)
      }
    }

    return caption
  }

  private func buildBackdropSignOff(backdrop: ChatShareBackdrop) -> UIView {
    let row = UIView()
    let iconSide: CGFloat = 16
    let icon = Self.makeBrandMarkView(side: iconSide, tintColor: backdrop.signOffInkColor)
    let label = UILabel()
    label.attributedText = NSAttributedString(
      string: "lody.ai",
      attributes: [
        .font: UIFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: backdrop.signOffInkColor,
        .kern: 0.3,
      ]
    )
    let labelSize = label.sizeThatFits(CGSize(width: 200, height: 30))
    let height = max(iconSide, ceil(labelSize.height))
    let width = iconSide + 7 + ceil(labelSize.width)
    row.frame = CGRect(x: 0, y: 0, width: width, height: height)
    icon.frame = CGRect(x: 0, y: round((height - iconSide) / 2), width: iconSide, height: iconSide)
    label.frame = CGRect(x: iconSide + 7, y: round((height - ceil(labelSize.height)) / 2), width: ceil(labelSize.width), height: ceil(labelSize.height))
    row.addSubview(icon)
    row.addSubview(label)
    return row
  }

  private static func makeAgentMarkView(
    cliType: String?,
    agentType: String?,
    side: CGFloat,
    tintColor: UIColor
  ) -> UIView {
    switch LodyAgentIcon.mark(cliType: cliType, agentType: agentType) {
    case .asset(let assetName):
      let imageView = UIImageView()
      imageView.contentMode = .scaleAspectFit
      let template = UIImage(named: assetName)?.withRenderingMode(.alwaysTemplate)
        ?? LodyIcon.agent.uiImage?.withRenderingMode(.alwaysTemplate)
      imageView.image = template
      imageView.tintColor = tintColor
      return imageView
    case .terminal:
      let imageView = UIImageView()
      imageView.contentMode = .scaleAspectFit
      imageView.image = LodyIcon.terminal.uiImage?.withRenderingMode(.alwaysTemplate)
        ?? UIImage(systemName: "terminal")
      imageView.tintColor = tintColor
      return imageView
    case .generic:
      return makeBrandMarkView(side: side, tintColor: tintColor)
    }
  }

  private static func makeBrandMarkView(side: CGFloat, tintColor: UIColor) -> UIView {
    if let appIcon = UIImage(named: "AppIconPreview-default") {
      let imageView = UIImageView(image: appIcon)
      imageView.contentMode = .scaleAspectFill
      imageView.clipsToBounds = true
      imageView.layer.cornerRadius = round(side * 0.24)
      imageView.layer.cornerCurve = .continuous
      return imageView
    }
    let imageView = UIImageView()
    imageView.contentMode = .scaleAspectFit
    imageView.image = LodyIcon.agent.uiImage?.withRenderingMode(.alwaysTemplate)
      ?? UIImage(systemName: "sparkles")
    imageView.tintColor = tintColor
    return imageView
  }

  private static func horizontalOverflow(_ root: UIView) -> CGFloat {
    var overflow: CGFloat = 0
    if let scroll = root as? UIScrollView {
      overflow = max(0, scroll.contentSize.width - scroll.bounds.width)
    }
    for subview in root.subviews {
      overflow = max(overflow, horizontalOverflow(subview))
    }
    return overflow
  }

  private static func sliceAttributedString(_ text: NSAttributedString, maxCharsPerSlice: Int) -> [NSAttributedString] {
    guard text.length > maxCharsPerSlice else { return [text] }
    var slices: [NSAttributedString] = []
    let nsString = text.string as NSString
    var start = 0
    while start < text.length {
      let remaining = text.length - start
      if remaining <= maxCharsPerSlice {
        slices.append(text.attributedSubstring(from: NSRange(location: start, length: remaining)))
        break
      }
      var splitAt = start + maxCharsPerSlice
      let searchRange = NSRange(location: start + maxCharsPerSlice / 2, length: maxCharsPerSlice / 2)
      let newline = nsString.range(of: "\n", options: .backwards, range: searchRange)
      if newline.location != NSNotFound {
        splitAt = newline.location
      }
      let sliceLength = max(1, splitAt - start)
      slices.append(text.attributedSubstring(from: NSRange(location: start, length: sliceLength)))
      start += sliceLength
      if start < text.length, nsString.character(at: start) == 10 {
        start += 1
      }
    }
    return slices.isEmpty ? [text] : slices
  }
}

@MainActor
private enum ChatShareCodeBlockView {
  static func make(
    language: String?,
    source: String,
    width: CGFloat,
    theme: MarkdownTheme,
    palette: ChatShareTheme.Palette,
    traits: UITraitCollection
  ) -> UIView {
    let container = UIView()
    container.backgroundColor = palette.codeBlockFill
    container.layer.cornerRadius = 12
    container.layer.cornerCurve = .continuous
    container.layer.borderWidth = 1
    container.layer.borderColor = palette.codeBlockBorder.cgColor
    container.clipsToBounds = true

    let padH: CGFloat = 12
    let innerWidth = max(1, width - padH * 2)
    var y: CGFloat = 10

    let trimmedLang = (language ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedLang.isEmpty {
      let langLabel = UILabel()
      langLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
      langLabel.textColor = palette.secondaryForeground
      langLabel.numberOfLines = 1
      langLabel.lineBreakMode = .byTruncatingTail
      langLabel.text = trimmedLang
      let langHeight = ceil(langLabel.font.lineHeight)
      langLabel.frame = CGRect(x: padH, y: 8, width: innerWidth, height: langHeight)
      container.addSubview(langLabel)
      y = langLabel.frame.maxY + 6
    }

    var trimmedSource = source
    while trimmedSource.hasSuffix("\n") || trimmedSource.hasSuffix("\r") {
      trimmedSource.removeLast()
    }

    let isDiff = trimmedLang.lowercased() == "diff" || trimmedLang.lowercased() == "patch"
    let codeFont = theme.fonts.code
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 3
    paragraph.lineBreakMode = .byCharWrapping

    if isDiff {
      let lines = trimmedSource.components(separatedBy: "\n")
      for line in lines {
        let rowBg = UIView()
        var lineColor = palette.foreground
        if line.hasPrefix("+") && !line.hasPrefix("+++") {
          lineColor = palette.diffAddText
          rowBg.backgroundColor = palette.diffAddFill
        } else if line.hasPrefix("-") && !line.hasPrefix("---") {
          lineColor = palette.diffDelText
          rowBg.backgroundColor = palette.diffDelFill
        } else if line.hasPrefix("@@") {
          lineColor = palette.linkColor
        } else {
          rowBg.backgroundColor = .clear
        }

        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byCharWrapping
        let displayLine = line.isEmpty ? " " : line
        label.attributedText = NSAttributedString(
          string: displayLine,
          attributes: [
            .font: codeFont,
            .foregroundColor: lineColor,
            .paragraphStyle: paragraph,
          ]
        )
        let lineHeight = max(ceil(codeFont.lineHeight), ceil(label.sizeThatFits(CGSize(width: innerWidth, height: .greatestFiniteMagnitude)).height))
        rowBg.frame = CGRect(x: 0, y: y - 1, width: width, height: lineHeight + 2)
        label.frame = CGRect(x: padH, y: 1, width: innerWidth, height: lineHeight)
        rowBg.addSubview(label)
        container.addSubview(rowBg)
        y += lineHeight + 3
      }
      y = max(y - 3, 12) + 10
    } else {
      let highlighted = NSMutableAttributedString(
        string: trimmedSource.isEmpty ? " " : trimmedSource,
        attributes: [
          .font: codeFont,
          .foregroundColor: palette.foreground,
          .paragraphStyle: paragraph,
        ]
      )
      if !trimmedSource.isEmpty {
        let tokens = CodeHighlighter.current.highlight(key: nil, content: trimmedSource, language: trimmedLang.isEmpty ? nil : trimmedLang)
        for (range, token) in tokens where NSMaxRange(range) <= highlighted.length {
          let resolved = theme.syntax.color(for: token).resolvedColor(with: traits)
          highlighted.addAttribute(.foregroundColor, value: resolved, range: range)
        }
      }

      let chunks = sliceCodeAttributedString(highlighted, maxLinesPerChunk: 50)
      for (chunkIndex, chunk) in chunks.enumerated() {
        if chunkIndex > 0 { y += 3 }
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byCharWrapping
        label.attributedText = chunk
        let chunkHeight = max(ceil(codeFont.lineHeight), ceil(label.sizeThatFits(CGSize(width: innerWidth, height: .greatestFiniteMagnitude)).height))
        label.frame = CGRect(x: padH, y: y, width: innerWidth, height: chunkHeight)
        container.addSubview(label)
        y += chunkHeight
      }
      y += 10
    }

    container.frame = CGRect(x: 0, y: 0, width: width, height: ceil(y))
    return container
  }

  private static func sliceCodeAttributedString(_ source: NSAttributedString, maxLinesPerChunk: Int) -> [NSAttributedString] {
    let raw = source.string as NSString
    guard raw.length > 0 else { return [source] }
    var chunks: [NSAttributedString] = []
    var chunkStart = 0
    var cursor = 0
    var linesInChunk = 0
    while cursor < raw.length {
      let newline = raw.range(of: "\n", options: [], range: NSRange(location: cursor, length: raw.length - cursor))
      if newline.location == NSNotFound {
        chunks.append(source.attributedSubstring(from: NSRange(location: chunkStart, length: raw.length - chunkStart)))
        break
      }
      linesInChunk += 1
      if linesInChunk >= maxLinesPerChunk {
        let length = newline.location - chunkStart
        chunks.append(source.attributedSubstring(from: NSRange(location: chunkStart, length: max(0, length))))
        chunkStart = newline.location + 1
        linesInChunk = 0
      }
      cursor = newline.location + 1
      if cursor == raw.length && chunkStart <= raw.length {
        let remaining = raw.length - chunkStart
        if remaining > 0 {
          chunks.append(source.attributedSubstring(from: NSRange(location: chunkStart, length: remaining)))
        }
      }
    }
    return chunks.isEmpty ? [source] : chunks
  }
}

@MainActor
private final class ShareCardMarkdownBlockView: MarkdownTextView {
  private static let fileMarker = "\u{F0000}lody-file:"
  private static let imageMarker = "\u{F0000}lody-image:"
  private static let htmlMarker = "\u{F0000}lody-html:"

  let printWidth: CGFloat
  let nestedCode: [String: (String?, String)]
  let palette: ChatShareTheme.Palette
  let scopedTraits: UITraitCollection

  init(
    printWidth: CGFloat,
    nestedCode: [String: (String?, String)],
    palette: ChatShareTheme.Palette,
    scopedTraits: UITraitCollection
  ) {
    self.printWidth = printWidth
    self.nestedCode = nestedCode
    self.palette = palette
    self.scopedTraits = scopedTraits
    super.init()
    throttleInterval = nil
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    MarkdownMermaid.resize(textLabelView, width: bounds.width)
    super.layoutSubviews()
  }

  override func boundingSize(for width: CGFloat) -> CGSize {
    MarkdownMermaid.resize(textLabelView, width: width)
    return super.boundingSize(for: width)
  }

  override func decorate(inlineText text: NSAttributedString, theme: MarkdownTheme) -> NSAttributedString {
    if let (language, source) = nestedCode[text.string] {
      let available = max(80, printWidth - 20)
      let codeView = ChatShareCodeBlockView.make(
        language: language,
        source: source,
        width: available,
        theme: theme,
        palette: palette,
        traits: scopedTraits
      )
      let attachment = TextLabel.Attachment()
      attachment.size = codeView.bounds.size
      attachment.view = codeView
      return attachment.attributedString(attributes: [.font: theme.fonts.body])
    }
    if let diagram = MarkdownMermaid.attachment(text.string, label: textLabelView, traits: scopedTraits) {
      diagram.view?.overrideUserInterfaceStyle = scopedTraits.userInterfaceStyle
      diagram.view?.isUserInteractionEnabled = false
      return diagram.attributedString(attributes: [.font: theme.fonts.body])
    }
    if let ruby = MarkdownRuby.decode(text.string) {
      var attributes: [NSAttributedString.Key: Any] = [.font: theme.fonts.body, .foregroundColor: theme.colors.body]
      if !ruby.reading.isEmpty {
        attributes[NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)] =
          CTRubyAnnotationCreateWithAttributes(
            .auto, .auto, .before, ruby.reading as CFString,
            [kCTRubyAnnotationSizeFactorAttributeName: 0.5] as CFDictionary
          )
      }
      return NSAttributedString(string: ruby.base, attributes: attributes)
    }
    for prefix in [Self.imageMarker, Self.htmlMarker] where text.string.hasPrefix(prefix) {
      let source = String(text.string.dropFirst(prefix.count))
      if prefix == Self.imageMarker {
        return NSAttributedString(string: source, attributes: [.font: theme.fonts.body, .foregroundColor: theme.colors.highlight])
      }
      return NSAttributedString(
        string: source,
        attributes: [
          .font: theme.fonts.codeInline,
          .foregroundColor: theme.colors.code,
          .backgroundColor: theme.colors.codeBackground,
        ]
      )
    }
    guard text.string.hasPrefix(Self.fileMarker) else { return text }
    let href = String(text.string.dropFirst(Self.fileMarker.count))
    guard let target = ChatFileLink(href) else { return text }
    let icon = UIImageView(image: MaterialFileIcon.image(for: target.path))
    icon.contentMode = .scaleAspectFit
    icon.tintColor = palette.linkColor
    let attachment = TextLabel.Attachment()
    attachment.size = CGSize(width: theme.fonts.body.pointSize + 5, height: theme.fonts.body.pointSize)
    attachment.view = icon
    let result = NSMutableAttributedString(attributedString: attachment.attributedString(attributes: text.attributes(at: 0, effectiveRange: nil)))
    result.replaceCharacters(in: NSRange(location: 0, length: result.length), with: "\u{200B}")
    return result
  }
}
