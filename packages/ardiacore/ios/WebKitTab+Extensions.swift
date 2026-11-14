import AppKit
import WebKit

extension WebKitTab {
  func noteExtensionTabOpened() { WebKitExtensions.shared.tabOpened(self) }

  func noteExtensionTabClosed() {
    WebKitExtensions.shared.tabClosed(self)
    WebKitHub.shared.logins.forget(self)
  }

  func noteExtensionTabShown() { WebKitExtensions.shared.tabShown(self) }

  func noteExtensionTabChanged() { WebKitExtensions.shared.tabChanged(self) }

  func runExtensionAction(_ extensionId: String) -> String? { WebKitExtensions.shared.performAction(extensionId, tab: self) }
}

@available(macOS 15.4, *)
extension WebKitTab: WKWebExtensionTab {
  func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
    guard let hub = context.webExtensionController?.delegate as? WebKitExtensionHub else { return nil }
    return hub.window(of: self)
  }

  func indexInWindow(for context: WKWebExtensionContext) -> Int {
    guard let window, let hub = context.webExtensionController?.delegate as? WebKitExtensionHub else { return 0 }
    return hub.tabs(in: window).firstIndex { $0 === self } ?? 0
  }

  func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }

  func title(for context: WKWebExtensionContext) -> String? { webView?.title }

  func url(for context: WKWebExtensionContext) -> URL? { webView?.url }

  func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { webView?.isLoading == false }

  func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { !playingFrames.isEmpty }

  func isMuted(for context: WKWebExtensionContext) -> Bool { muted }

  func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(webView?.pageZoom ?? 1) }

  func size(for context: WKWebExtensionContext) -> CGSize { bounds.size }

  func isSelected(for context: WKWebExtensionContext) -> Bool { visible }

  func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
    loadURL(url.absoluteString, userInitiated: false)
    completionHandler(nil)
  }

  func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
    if fromOrigin { reloadIgnoringCache() } else { reload() }
    completionHandler(nil)
  }

  func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
    goBack()
    completionHandler(nil)
  }

  func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
    goForward()
    completionHandler(nil)
  }

  func setMuted(_ muted: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
    setMuted(muted)
    completionHandler(nil)
  }

  func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }
}
