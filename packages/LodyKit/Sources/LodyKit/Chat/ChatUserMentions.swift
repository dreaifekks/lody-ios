import UIKit

/// Legacy history contains the expanded prompt, not composer ranges. Decode only
/// the explicit reference syntax; never rewrite the stored or copied message.
@MainActor enum ChatUserMentions {
  private static let pattern = try! NSRegularExpression(pattern:
    #"(?s:`{3,}.*?(?:`{3,}|$))|`+[^`\n]*`+|https?://[^\s]+|\\[@#$]|(?<!\S)use /([^\s]+) \[Skill Path\]\(((?:\\.|[^\\)])+)\)|(?<!\S)@(?:"((?:\\.|[^"\\])*)"|([^\s@"`]+))|(?<!\S)#([1-9][0-9]*)(?=$|\s|[.,;:!?\)\]])"#)

  static func decorate(
    _ source: NSAttributedString,
    references: [ChatTextReference],
    repository: String,
    traits: UITraitCollection,
    expandQuotes: Bool = false,
    accentColor: UIColor = .lodyAccent,
    chipFill: UIColor = ChatReferenceNode.chipFill,
    quoteColor: UIColor = .secondaryLabel
  ) -> NSAttributedString {
    guard !references.isEmpty else {
      return decorate(source, repository: repository, traits: traits, accentColor: accentColor, chipFill: chipFill)
    }
    let result = NSMutableAttributedString(string: "")
    var cursor = 0
    let sorted = references.sorted(by: { $0.start < $1.start })
    let text = source.string as NSString
    for (index, reference) in sorted.enumerated() {
      guard reference.start >= cursor, reference.end > reference.start, reference.end <= source.length else { continue }
      let leading = source.attributedSubstring(from: NSRange(location: cursor, length: reference.start - cursor))
      result.append(decorate(leading, repository: repository, traits: traits, accentColor: accentColor, chipFill: chipFill))
      if reference.kind == "message_quote", let quote = reference.quote {
        result.append(
          quoteBlock(
            quote,
            attributes: source.attributes(at: reference.start, effectiveRange: nil),
            expandQuotes: expandQuotes,
            quoteColor: quoteColor
          )
        )
        cursor = reference.end
        let nextQuote = sorted.dropFirst(index + 1).first { $0.kind == "message_quote" && $0.quote != nil }
        if cursor + 2 <= text.length, text.substring(with: NSRange(location: cursor, length: 2)) == "\n\n",
           nextQuote?.start != cursor + 2 {
          result.append(source.attributedSubstring(from: NSRange(location: cursor, length: 1)))
          cursor += 2
        }
        continue
      }
      let label = NSMutableAttributedString(attributedString: source.attributedSubstring(from: NSRange(location: reference.start, length: reference.end - reference.start)))
      label.addAttributes([.foregroundColor: accentColor, .lodyReferenceChip: chipFill],
        range: NSRange(location: 0, length: label.length))
      if !expandQuotes, ["file", "dir", "skill"].contains(reference.kind), let path = reference.target.flatMap(fileTarget) {
        label.addAttribute(.link, value: path, range: NSRange(location: 0, length: label.length))
      }
      result.append(label)
      cursor = reference.end
    }
    let trailing = source.attributedSubstring(from: NSRange(location: cursor, length: source.length - cursor))
    result.append(decorate(trailing, repository: repository, traits: traits, accentColor: accentColor, chipFill: chipFill))
    return result
  }

  /// Lines of a sent quote shown in the bubble; the full snapshot opens on tap.
  static let quoteLines = 3
  private static let quoteCharacters = 240

  /// A sent quote (a valid `message_quote` span) drawn as web's quote block: secondary ink
  /// indented past a leading bar, clipped to a few lines unless `expandQuotes` is true.
  static func quoteBlock(
    _ quote: String,
    attributes: [NSAttributedString.Key: Any],
    expandQuotes: Bool = false,
    quoteColor: UIColor = .secondaryLabel
  ) -> NSAttributedString {
    let shown: String
    if expandQuotes {
      shown = quote
    } else {
      let lines = quote.components(separatedBy: "\n")
      var truncated = lines.prefix(quoteLines).joined(separator: "\n")
      if truncated.count > quoteCharacters { truncated = String(truncated.prefix(quoteCharacters)) }
      if truncated.count < quote.count { truncated = truncated.trimmingCharacters(in: .whitespaces) + "…" }
      shown = truncated
    }
    var style = attributes
    let paragraph = ((attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
    paragraph.firstLineHeadIndent = 12
    paragraph.headIndent = 12
    style[.paragraphStyle] = paragraph
    style[.foregroundColor] = quoteColor
    style[.lodyQuoteBar] = true
    if !expandQuotes {
      style[.link] = ChatQuoteLink.prefix + quote
    }
    return NSAttributedString(string: shown, attributes: style)
  }

  static func decorate(
    _ source: NSAttributedString,
    repository: String,
    traits: UITraitCollection,
    accentColor: UIColor = .lodyAccent,
    chipFill: UIColor = ChatReferenceNode.chipFill
  ) -> NSAttributedString {
    let result = NSMutableAttributedString(attributedString: source)
    let text = source.string as NSString
    let repo = repository.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}$"#, options: .regularExpression) != nil
      && ![".", ".."].contains(repository.components(separatedBy: "/").last ?? "")
    for match in pattern.matches(in: source.string, range: NSRange(location: 0, length: text.length)).reversed() {
      var replacementRange = match.range
      func capture(_ index: Int) -> String? {
        let range = match.range(at: index)
        return range.location == NSNotFound ? nil : text.substring(with: range)
      }
      let label: String
      let target: String
      let symbol: String
      if let name = capture(1), let path = capture(2), let file = fileTarget(unescape(path)) {
        label = "$" + name
        target = file
        symbol = "sparkles"
      } else if let raw = capture(3) ?? capture(4) {
        var token = raw
        if capture(3) == nil {
          while let last = token.last, ",;!?.".contains(last) { token.removeLast() }
          replacementRange.length -= (raw as NSString).length - (token as NSString).length
        }
        let path = unescape(token)
        guard let file = fileTarget(path) else { continue }
        label = "@" + path
        target = file
        symbol = path.hasSuffix("/") ? "folder" : "doc.text"
      } else if let number = capture(5), repo {
        label = "#" + number
        // GitHub redirects this canonical issue-number route to /pull/ for PRs.
        target = "https://github.com/\(repository)/issues/\(number)"
        symbol = "link"
      } else { continue }
      var attributes = source.attributes(at: match.range.location, effectiveRange: nil)
      attributes[.foregroundColor] = accentColor
      attributes[.lodyReferenceChip] = chipFill
      attributes[.link] = target
      let font = attributes[.font] as? UIFont ?? .preferredFont(forTextStyle: .body)
      let size = font.pointSize * 0.85
      let attachment = NSTextAttachment()
      attachment.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size))?
        .withTintColor(accentColor.resolvedColor(with: traits), renderingMode: .alwaysOriginal)
      attachment.bounds = CGRect(x: 0, y: font.descender / 2, width: size, height: size)
      let node = NSMutableAttributedString(attachment: attachment)
      node.append(NSAttributedString(string: "\u{00a0}" + label))
      node.addAttributes(attributes, range: NSRange(location: 0, length: node.length))
      result.replaceCharacters(in: replacementRange, with: node)
    }
    return result
  }

  private static func unescape(_ text: String) -> String {
    text.replacingOccurrences(of: #"\\([\\"\)])"#, with: "$1", options: .regularExpression)
  }

  private static func fileTarget(_ path: String) -> String? {
    guard !path.isEmpty, !path.contains("\n"), !path.contains("\r"), !path.contains("\0"),
      !path.contains(":"), !path.contains("?"), !path.contains("#"), !path.hasPrefix("//") else { return nil }
    // Extensionless references such as @Dockerfile still use the file opener.
    return path.contains("/") ? path : "./" + path
  }
}
