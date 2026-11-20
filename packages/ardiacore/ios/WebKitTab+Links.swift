import AppKit
import WebKit

extension WebKitTab {
  private enum LinkKey: String {
    case alt, shift, altShift, altMeta
  }

  private enum LinkAction {
    case peek, split
  }

  private static let littleArdiaWindow = "ardia.window.small"

  private static func linkKey(_ flags: NSEvent.ModifierFlags) -> LinkKey? {
    if flags.contains(.control) { return nil }
    if flags.contains(.command) { return flags.contains(.option) && !flags.contains(.shift) ? .altMeta : nil }
    if flags.contains(.option) { return flags.contains(.shift) ? .altShift : .alt }
    return flags.contains(.shift) ? .shift : nil
  }

  private static func linkAction(_ key: LinkKey) -> LinkAction? {
    if key.rawValue == ArdiaWebView.peekModifierInUse() { return .peek }
    if key == .altShift || key == .altMeta || key.rawValue == ArdiaWebView.splitLinkModifierInUse() { return .split }
    return nil
  }

  private static func withoutWWW(_ host: String) -> String {
    host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }

  private static func carriesURL(_ url: URL) -> Bool {
    url.absoluteString.contains(/[?&][^=&#]*=(https?(:|%3A)(\/\/|%2F%2F))/.ignoresCase())
  }

  private func leavesSite(_ url: URL) -> Bool {
    guard let page = webView?.url, ["http", "https"].contains(page.scheme?.lowercased() ?? "") else { return false }
    let here = Self.withoutWWW(page.host?.lowercased() ?? "")
    return Self.withoutWWW(url.host?.lowercased() ?? "") != here || Self.carriesURL(url)
  }

  private var clickPoint: [String: Double] {
    guard let view = webView, let window else { return ["x": 0, "y": 0] }
    var point = view.convert(view.lastMouseUp ?? window.mouseLocationOutsideOfEventStream, from: nil)
    point.x = min(max(point.x, 0), view.bounds.width)
    point.y = min(max(point.y, 0), view.bounds.height)
    let inWindow = view.convert(point, to: nil)
    return ["x": inWindow.x, "y": (window.contentView?.frame.height ?? 0) - inWindow.y]
  }

  private func openLink(_ url: URL, _ disposition: String, extra: [String: Any] = [:]) -> WKNavigationActionPolicy {
    emit("openWindow", ["url": url.absoluteString, "disposition": disposition, "userGesture": true].merging(extra) { $1 })
    return .cancel
  }

  func linkPolicy(for action: WKNavigationAction, url: URL) -> WKNavigationActionPolicy? {
    guard action.navigationType == .linkActivated else { return nil }
    let web = ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    let flags = action.modifierFlags.intersection([.command, .shift, .option, .control])
    let middle = action.buttonNumber == 2
    if !middle, web, !action.shouldPerformDownload, let key = Self.linkKey(flags), let chosen = Self.linkAction(key) {
      switch chosen {
      case .split:
        ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "linkSplit"]))
        return openLink(url, "split")
      case .peek:
        guard visible, window != nil else { return openLink(url, key == .shift ? "window" : "background") }
        ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "linkPeek"]))
        return openLink(url, "peek", extra: ["site": false, "point": clickPoint])
      }
    }
    if !middle, flags.isEmpty, web, action.sourceFrame.isMainFrame, action.targetFrame?.isMainFrame == true,
      ArdiaWebView.peeksLinksToOtherSites(inTab: transferKey), leavesSite(url) {
      ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "linkPeek"]))
      return openLink(url, "peek", extra: ["site": true, "point": clickPoint])
    }
    if !middle, flags.isEmpty, web, action.targetFrame == nil, ArdiaWebView.littleArdiaOpensNewTabLinksInPlace(),
      window?.identifier?.rawValue == Self.littleArdiaWindow {
      ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "littleArdiaLink"]))
      return openLink(url, "current", extra: ["linkWait": "matched"])
    }
    guard action.targetFrame != nil else { return nil }
    if flags.contains(.command) || middle {
      return openLink(url, flags.contains(.shift) ? "foreground" : "background")
    }
    if flags.contains(.option) { return .download }
    return nil
  }
}
