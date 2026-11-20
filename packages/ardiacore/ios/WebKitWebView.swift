import AppKit
import WebKit

struct WebKitReportedTheme {
  let color: String
  let source: String
}

final class WebKitWebView: WKWebView {
  var onFocus: (() -> Void)?
  var onPressRefused: (() -> Void)?
  private var presses = WebKitPagePresses()
  var mediaFrames: [String: WKFrameInfo] = [:]
  var scriptFrames: [String: WKFrameInfo] = [:]
  var playingFrames = Set<String>()
  let nowPlaying = ArdiaNowPlaying()
  var captureOrigins: [String: Set<String>] = [:]
  var autoPictureInPictureRule = WebKitAutoPictureInPicture()
  var reportedTheme: WebKitReportedTheme?
  var sampledThemeCounted = false
  private var keyUpOfReservedKey: UInt16?
  private(set) var lastContextClick: NSPoint?
  private(set) var lastMouseUp: NSPoint?

  override init(frame: CGRect, configuration: WKWebViewConfiguration) {
    super.init(frame: frame, configuration: configuration)
    if WebKitHub.silenced { mutePageAudio() }
    if LaunchConfig.shared.background && !LaunchConfig.shared.instanceFlag("allowOcclusion") { treatWindowAsVisible() }
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }

  private func mutePageAudio() {
    let setPageMuted = NSSelectorFromString("_setPageMuted:")
    guard responds(to: setPageMuted) else { return NSLog("[webkit] page audio can't be muted in background mode") }
    typealias SetPageMuted = @convention(c) (AnyObject, Selector, UInt) -> Void
    let audioMuted: UInt = 1
    unsafeBitCast(method(for: setPageMuted), to: SetPageMuted.self)(self, setPageMuted, audioMuted)
  }

  private func treatWindowAsVisible() {
    let setDetection = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
    guard responds(to: setDetection) else { return NSLog("[webkit] window occlusion can't be ignored in background mode") }
    typealias SetDetection = @convention(c) (AnyObject, Selector, Bool) -> Void
    unsafeBitCast(method(for: setDetection), to: SetDetection.self)(self, setDetection, false)
  }

  func stopCapture(_ kind: String) {
    if kind == "camera" { setCameraCaptureState(.none, completionHandler: {}) }
    if kind == "microphone" { setMicrophoneCaptureState(.none, completionHandler: {}) }
  }

  private func admits(_ event: NSEvent) -> Bool {
    switch presses.verdict(for: event, on: self) {
    case .pass:
      notePress(event)
      return true
    case .drop: return false
    case .refuse:
      onPressRefused?()
      return false
    }
  }

  private func notePress(_ event: NSEvent) {
    switch event.type {
    case .rightMouseDown: lastContextClick = event.locationInWindow
    case .leftMouseDown where event.modifierFlags.contains(.control): lastContextClick = event.locationInWindow
    case .leftMouseUp: lastMouseUp = event.locationInWindow
    default: break
    }
  }

  override func mouseDown(with event: NSEvent) { if admits(event) { super.mouseDown(with: event) } }
  override func mouseDragged(with event: NSEvent) { if admits(event) { super.mouseDragged(with: event) } }
  override func mouseUp(with event: NSEvent) { if admits(event) { super.mouseUp(with: event) } }
  override func rightMouseDown(with event: NSEvent) { if admits(event) { super.rightMouseDown(with: event) } }
  override func rightMouseDragged(with event: NSEvent) { if admits(event) { super.rightMouseDragged(with: event) } }
  override func rightMouseUp(with event: NSEvent) { if admits(event) { super.rightMouseUp(with: event) } }
  override func otherMouseDown(with event: NSEvent) { if admits(event) { super.otherMouseDown(with: event) } }
  override func otherMouseDragged(with event: NSEvent) { if admits(event) { super.otherMouseDragged(with: event) } }
  override func otherMouseUp(with event: NSEvent) { if admits(event) { super.otherMouseUp(with: event) } }

  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    if became { onFocus?() }
    return became
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard (window?.firstResponder as? NSView)?.isDescendant(of: self) == true else { return super.performKeyEquivalent(with: event) }
    let reserved = ArdiaPerformReservedKey(event)
    keyUpOfReservedKey = reserved ? event.keyCode : nil
    return reserved || super.performKeyEquivalent(with: event)
  }

  override func keyDown(with event: NSEvent) {
    keyUpOfReservedKey = nil
    if InputSourceKeys.consumeInWebKitTab(event) { return }
    super.keyDown(with: event)
  }

  private var page: WebKitTab? { superview as? WebKitTab }

  @objc func notePagePress() {
    page?.emit("pagePress")
  }

  @objc func zoomByCommandScroll(_ direction: Int) {
    guard let page else { return }
    ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "scrollZoom"]))
    page.zoomStep(direction)
  }

  override func keyUp(with event: NSEvent) {
    if keyUpOfReservedKey == event.keyCode {
      keyUpOfReservedKey = nil
      return
    }
    super.keyUp(with: event)
  }

  override func cancelOperation(_ sender: Any?) {
    if let event = NSApp.currentEvent, event.type == .keyDown, !event.modifierFlags.isDisjoint(with: [.command, .option, .control]) { return }
    page?.emit("command", ["command": "escape", "text": ""])
  }

  override func resignFirstResponder() -> Bool {
    keyUpOfReservedKey = nil
    return super.resignFirstResponder()
  }

  override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
    super.willOpenMenu(menu, with: event)
    guard LaunchConfig.shared.background else { return }
    if !menu.items.isEmpty { NSLog("[webkit] context menu (background mode, not shown): %@", menu.items.map(\.title).joined(separator: ", ")) }
    menu.removeAllItems()
  }
}
