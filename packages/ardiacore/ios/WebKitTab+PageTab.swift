import AppKit
import WebKit

extension WebKitTab: PageTab {
  static let unsupported = "unsupported"

  var standalone: Bool { get { false } set {} }
  var temporary: Bool { get { false } set {} }
  var temporarySource: String? { get { nil } set {} }
  var extensionHost: String? { get { nil } set {} }
  var warm: Bool { get { false } set {} }
  var neighbour: Bool { get { false } set {} }
  var pageColor: String? {
    get { life.pageColor }
    set {
      life.pageColor = newValue
      applyPageColor(newValue)
    }
  }

  var contentsBackgroundColor: NSColor? {
    get { life.contentsBackgroundColor }
    set {
      life.contentsBackgroundColor = newValue
      if pageBackgroundColor == nil, let color = newValue { webView?.underPageBackgroundColor = color }
      applyBackdrop(newValue)
    }
  }

  var shownURL: String? { get { nil } set {} }
  var frozen: Bool {
    get { pageFrozen }
    set { pageFrozen = newValue }
  }

  var mediaCaptureSourceId: String? { nil }

  func startPage() { start() }

  func fitPageToInterfaceScale() {
    InterfaceScale.fitPageHost(self)
    fillWithPage()
  }

  func fillWithPage() {
    guard let webView, webView.frame != bounds else { return }
    webView.frame = bounds
  }

  func followInterfaceScale() {
    NotificationCenter.default.removeObserver(self, name: .ArdiaInterfaceScaleDidChange, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(interfaceScaleChanged), name: .ArdiaInterfaceScaleDidChange, object: nil)
    fitPageToInterfaceScale()
  }

  @objc private func interfaceScaleChanged() { fitPageToInterfaceScale() }

  func print() {
    guard let view = webView, let window else { return }
    if LaunchConfig.shared.background { return NSLog("[webkit] print panel (background mode, not shown)") }
    let operation = view.printOperation(with: NSPrintInfo.shared)
    operation.view?.frame = view.bounds
    operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
  }

  func runPageCommand(_ name: String) {
    if name == "systemPrint" { return print() }
    runPageFileCommand(name)
  }

  func capturePicture(_ scale: Double, completion: @escaping ([String: Any]?) -> Void) {
    guard let view = webView, let window, !view.isHidden else { return completion(nil) }
    let inRoot = InterfaceScale.rootRect(fromWindow: convert(bounds, to: nil), in: window)
    let frame: [Double] = [inRoot.minX, inRoot.minY, inRoot.width, inRoot.height]
    let configuration = WKSnapshotConfiguration()
    configuration.snapshotWidth = NSNumber(value: Double(view.bounds.width) * max(0.1, min(scale, 2)))
    view.takeSnapshot(with: configuration) { image, _ in
      guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
        let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: scale < 0.5 ? 0.55 : 0.75])
      else { return completion(nil) }
      completion(["data": jpeg.base64EncodedString(), "frame": frame])
    }
  }

  func closePage() {
    if Thread.isMainThread { return close() }
    DispatchQueue.main.async { self.close() }
  }

  func navigationEntries(_ completion: @escaping ([[String: Any]]) -> Void) { completion(navigationEntries()) }

  func securityInfo(_ completion: @escaping ([String: Any]) -> Void) { completion(securityInfo()) }

  func showDevTools(panel: String?) { showWebKitDevTools(panel: panel) }

  func downloadImage(_ url: String, maxPixels: Int, completion: @escaping ([String: Any]?) -> Void) {
    downloadFavicon(url, completion: completion)
  }

  func requestPictureInPicture(clickAt: Double, control: Int, _ completion: @escaping (Bool) -> Void) {
    setPictureInPicture(true) { completion($0 == .opened) }
  }

  func takeControlPress(clickAt: Double, control: Int) -> Bool { true }

  func exitPictureInPicture() { setPictureInPicture(false) { _ in } }

  func pageCookies(_ urls: [String], completion: @escaping ([[String: Any]]?) -> Void) { completion([]) }

  func openBlockedPopup(_ popupId: String, always: Bool) { openBlocked(popupId, always: always) }

  func resolvePasswordPrompt(_ action: String, username: String?, password: String?) {
    WebKitHub.shared.logins.resolveSave(self, action: action, username: username, password: password)
  }

  func resolveAutofillPrompt(_ promptId: Int, action: String) { WebKitAutofill.shared.resolve(self, promptId: promptId, action: action) }

  func answerAutofillPrompt(_ promptId: Int, action: String) -> Bool { false }

  func executeExtensionAction(_ extensionId: String) -> String? { nil }

  func resolveDisplayMedia(_ requestId: String, sourceId: String?, audio: Bool) { answerDisplayCapture(requestId, sourceId: sourceId) }

  func notificationAction(_ notificationId: String, action: String) { WebKitHub.shared.notifications.act(notificationId, action: action, in: self) }

  func resolveUnresponsive(terminate: Bool) { resolveHang(terminate: terminate) }

  func discard(unload: Bool) -> String { discardPage(unload: unload) }

  func sleepIfHidden(for seconds: Double) -> [NSNumber] { [-1] }
}
