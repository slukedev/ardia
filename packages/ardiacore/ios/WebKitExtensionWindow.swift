import AppKit
import WebKit

@available(macOS 15.4, *)
final class WebKitExtensionWindow: NSObject, WKWebExtensionWindow {
  weak var window: NSWindow?
  private weak var hub: WebKitExtensionHub?

  init(window: NSWindow, hub: WebKitExtensionHub) {
    self.window = window
    self.hub = hub
  }

  private var tabs: [WebKitTab] {
    guard let window, let hub else { return [] }
    return hub.tabs(in: window)
  }

  func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { tabs }

  func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { tabs.first { $0.visible } }

  func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

  func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
    guard let window else { return .normal }
    if window.isMiniaturized { return .minimized }
    if window.styleMask.contains(.fullScreen) { return .fullscreen }
    return window.isZoomed ? .maximized : .normal
  }

  func isPrivate(for context: WKWebExtensionContext) -> Bool { hub.map { WebKitStores.isPrivate($0.profile) } ?? false }

  func frame(for context: WKWebExtensionContext) -> CGRect { window?.frame ?? .null }

  func screenFrame(for context: WKWebExtensionContext) -> CGRect { window?.screen?.frame ?? .null }

  func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
    if LaunchConfig.shared.background { NSLog("[webkit] extension asked to focus a window (background mode, not focused)") } else { window?.makeKeyAndOrderFront(nil) }
    completionHandler(nil)
  }
}
