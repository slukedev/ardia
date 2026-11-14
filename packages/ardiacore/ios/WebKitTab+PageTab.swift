import AppKit

extension WebKitTab: PageTab {
  static let unsupported = "unsupported"

  var standalone: Bool { get { false } set {} }
  var temporary: Bool { get { false } set {} }
  var temporarySource: String? { get { nil } set {} }
  var extensionHost: String? { get { nil } set {} }
  var warm: Bool { get { false } set {} }
  var neighbour: Bool { get { false } set {} }
  var pageColor: String? { get { nil } set {} }
  var contentsBackgroundColor: NSColor? { get { nil } set {} }
  var shownURL: String? { get { nil } set {} }
  var frozen: Bool { get { false } set {} }
  var mediaCaptureSourceId: String? { nil }

  func startPage() { start() }

  func closePage() {
    if Thread.isMainThread { return close() }
    DispatchQueue.main.async { self.close() }
  }

  func navigationEntries(_ completion: @escaping ([[String: Any]]) -> Void) { completion(navigationEntries()) }

  func securityInfo(_ completion: @escaping ([String: Any]) -> Void) { completion(securityInfo()) }

  func showDevTools(panel: String?) {}

  func downloadImage(_ url: String, maxPixels: Int, completion: @escaping ([String: Any]?) -> Void) {
    downloadFavicon(url, completion: completion)
  }

  func requestPictureInPicture(clickAt: Double, control: Int, _ completion: @escaping (Bool) -> Void) {
    setPictureInPicture(true) { completion($0 == .opened) }
  }

  func takeControlPress(clickAt: Double, control: Int) -> Bool { true }

  func exitPictureInPicture() { setPictureInPicture(false) { _ in } }

  func pageCookies(_ urls: [String], completion: @escaping ([[String: Any]]?) -> Void) {
    WebKitHub.shared.engineCookies(profile: profile, urls: urls.compactMap(URL.init(string:)), completion: completion)
  }

  func openBlockedPopup(_ popupId: String, always: Bool) {}

  func resolvePasswordPrompt(_ action: String, username: String?, password: String?) {
    WebKitHub.shared.logins.resolveSave(self, action: action, username: username, password: password)
  }

  func resolveAutofillPrompt(_ promptId: Int, action: String) {}

  func executeExtensionAction(_ extensionId: String) -> String? { runExtensionAction(extensionId) }

  func resolveDisplayMedia(_ requestId: String, sourceId: String?, audio: Bool) {}

  func notificationAction(_ notificationId: String, action: String) { WebKitHub.shared.notifications.act(notificationId, action: action, in: self) }

  func resolveUnresponsive(terminate: Bool) {}

  func discard(unload: Bool) -> String { Self.unsupported }
}
