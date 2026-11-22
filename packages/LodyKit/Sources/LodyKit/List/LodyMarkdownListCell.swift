import MarkdownView
import UIKit

final class LodyMarkdownListCell: UICollectionViewListCell {
  struct Content: Equatable {
    let id: String
    let source: String
    let author: String
    let baseURL: URL
  }

  private let document = MarkdownTextView()
  private let author = UILabel()
  private var markdown: Content?
  private let verticalInset: CGFloat = 10
  private let authorGap: CGFloat = 4

  override init(frame: CGRect) {
    super.init(frame: frame)
    isAccessibilityElement = false
    document.textLabelView.isAccessibilityElement = true
    document.textLabelView.accessibilityTraits = .staticText
    document.linkHandler = { [weak self] payload, _, _ in
      let destination: String = switch payload {
      case .url(let url): url.relativeString
      case .string(let value): value
      }
      if let url = self?.linkURL(destination) { UIApplication.shared.open(url) }
    }
    contentView.addSubview(document)
    author.font = .preferredFont(forTextStyle: .footnote)
    author.textColor = .lodySecondary
    author.adjustsFontForContentSizeCategory = true
    author.numberOfLines = 0
    contentView.addSubview(author)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func prepareForReuse() {
    super.prepareForReuse()
    markdown = nil
    document.reset()
  }

  func configure(_ content: Content) {
    guard markdown != content else { return }
    markdown = content
    document.textLabelView.accessibilityIdentifier = content.id
    author.text = content.author
    author.isHidden = content.author.isEmpty
    renderMarkdown()
    contentView.invalidateIntrinsicContentSize()
    setNeedsLayout()
  }

  func trackSelection(in scrollView: UIScrollView) {
    document.trackedScrollView = scrollView
  }

  override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
    let attributes = layoutAttributes.copy() as! UICollectionViewLayoutAttributes
    let size = measures(for: attributes.size.width)
    attributes.size.height = max(44, 2 * verticalInset + size.body + size.byline)
    return attributes
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let size = measures(for: contentView.bounds.width)
    let inset = LodyFlatRows.readingMargin
    document.frame = CGRect(x: inset, y: verticalInset, width: size.width, height: size.body)
    author.frame = CGRect(x: inset, y: document.frame.maxY + authorGap, width: size.width, height: max(0, size.byline - authorGap))
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
      || traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
      renderMarkdown()
      contentView.invalidateIntrinsicContentSize()
      setNeedsLayout()
    }
  }

  private func measures(for width: CGFloat) -> (width: CGFloat, body: CGFloat, byline: CGFloat) {
    let textWidth = max(1, width - 2 * LodyFlatRows.readingMargin)
    let body = ceil(document.boundingSize(for: textWidth).height)
    let byline = author.isHidden ? 0 : authorGap + ceil(author.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
    return (textWidth, body, byline)
  }

  private func renderMarkdown() {
    guard let markdown else { return }
    let theme = ChatMarkdownTheme.make(traits: traitCollection, secondary: false)
    document.setContentImmediately(MarkdownContent(markdown: markdown.source, theme: theme), theme: theme)
    let label = document.textLabelView
    let rendered = label.attributedText
    let readable = MarkdownPlainText.string(markdown.source)
    label.accessibilityLabel = readable.isEmpty ? rendered.string : readable
    var actions: [UIAccessibilityCustomAction] = []
    rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { value, range, _ in
      guard let destination = value as? String, let url = linkURL(destination) else { return }
      actions.append(UIAccessibilityCustomAction(name: rendered.attributedSubstring(from: range).string) { _ in
        UIApplication.shared.open(url)
        return true
      })
    }
    label.accessibilityCustomActions = actions
  }

  private func linkURL(_ destination: String) -> URL? {
    guard !destination.isEmpty, let baseURL = markdown?.baseURL,
          let url = URL(string: destination, relativeTo: baseURL)?.absoluteURL,
          let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
          url.host != nil else { return nil }
    return url
  }
}
