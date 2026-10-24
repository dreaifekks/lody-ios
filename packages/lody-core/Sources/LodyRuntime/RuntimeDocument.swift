import Foundation
import WebKit

/// Platform owners supply lifecycle, resource location, credentials and messages.
@MainActor
public enum RuntimeDocument {
  public static func makeWebView(handler: any WKScriptMessageHandler, delegate: any WKNavigationDelegate, configure: (WKWebViewConfiguration) -> Void = { _ in }) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController.add(handler, name: "dataRuntime")
    configure(configuration)
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = delegate
    #if DEBUG
    view.isInspectable = true
    #endif
    return view
  }

  public static func load(in view: WKWebView, bundle: Bundle, origin: String = "https://lody.ai/") throws {
    guard let url = bundle.url(forResource: "DataRuntime", withExtension: "html")
      ?? Bundle.main.url(forResource: "DataRuntime", withExtension: "html")
    else { throw CocoaError(.fileNoSuchFile) }
    // Keep the official origin without loading remote documents or scripts.
    view.loadHTMLString(try String(contentsOf: url, encoding: .utf8), baseURL: URL(string: origin))
  }

  public static func allows(_ action: WKNavigationAction, origin: String = "https://lody.ai/") -> Bool {
    let url = action.request.url?.absoluteString
    return action.navigationType == .other && (url == "about:blank" || url == origin)
  }
}
