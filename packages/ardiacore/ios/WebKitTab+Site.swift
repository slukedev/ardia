import AppKit
import Foundation
import WebKit

enum WebKitPageGestures {
  static var selectionPopover = true
  static var linkDropAt: CFTimeInterval = 0
}

extension WebKitTab {
  func siteMessage(_ kind: String, data: [String: Any]?, frameInfo: WKFrameInfo) {
    if kind == "selection" { return noteSelection(data, main: frameInfo.isMainFrame) }
    guard let data else { return }
    switch kind {
    case "loginField": if frameInfo.isMainFrame { WebKitHub.shared.logins.fieldPressed(self, data: data, origin: frameInfo.securityOrigin) }
    case "loginSubmit": if frameInfo.isMainFrame { WebKitHub.shared.logins.submitted(self, data: data, origin: frameInfo.securityOrigin) }
    case "notification": if frameInfo.isMainFrame { WebKitHub.shared.notifications.received(data, from: self, sender: frameInfo.securityOrigin) }
    case "appBadge": if frameInfo.isMainFrame { noteAppBadge(data, origin: frameInfo.securityOrigin) }
    case "linkDrop": if frameInfo.isMainFrame { noteLinkDrop(data) }
    default: break
    }
  }

  func siteCommitted() {
    WebKitHub.shared.notifications.sharePermission(with: self)
  }

  func fillLogin(username: String, password: String, origin: String) {
    let code = "window.__ardiaLogins ? window.__ardiaLogins.fill(\(Self.jsString(username)), \(Self.jsString(password)), \(Self.jsString(origin))) : false"
    webView?.evaluateJavaScript(code, in: nil, in: WebKitHub.world) { _ in }
  }

  func noteLinkStatus(_ data: Any?, main: Bool) {
    let dict = data as? [String: Any]
    let text = String((dict?["text"] as? String ?? data as? String ?? "").prefix(8192))
    var payload: [String: Any] = ["text": text]
    if !text.isEmpty, let fromBottom = statusFromBottom(dict, main: main) { payload["fromBottom"] = fromBottom }
    emit("status", payload)
  }

  func noteIcons(_ data: [String: Any]?, main: Bool) {
    guard main, let urls = (data?["urls"] as? [String])?.prefix(32), let first = urls.first else { return }
    if data?["changed"] as? Bool == true { ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "faviconChanged"])) }
    emit("favicon", ["url": first, "urls": Array(urls)])
  }

  private func statusFromBottom(_ dict: [String: Any]?, main: Bool) -> Double? {
    if main, let y = Self.finite(dict?["y"]), let height = Self.finite(dict?["height"]), height > 0 {
      return Double(bounds.height) * (1 - min(max(y / height, 0), 1))
    }
    guard let window else { return nil }
    let local = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
    guard bounds.contains(local) else { return nil }
    return Double(isFlipped ? bounds.maxY - local.y : local.y - bounds.minY)
  }

  private func noteSelection(_ data: [String: Any]?, main: Bool) {
    guard main, WebKitPageGestures.selectionPopover || data == nil else { return }
    let selection = data.flatMap(Self.selectionState)
    if selection != nil { ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "selectionShown"])) }
    emit("selection", ["selection": selection ?? NSNull()])
  }

  private static func selectionState(_ data: [String: Any]) -> [String: Any]? {
    guard let text = data["text"] as? String, let rect = data["rect"] as? [String: Any],
      let x = finite(rect["x"]), let y = finite(rect["y"]), let width = finite(rect["width"]), let height = finite(rect["height"])
    else { return nil }
    return ["text": String(text.prefix(4000)), "rect": ["x": x, "y": y, "width": width, "height": height]]
  }

  private func noteAppBadge(_ data: [String: Any], origin: WKSecurityOrigin) {
    guard !origin.protocol.isEmpty, !origin.host.isEmpty else { return }
    let count = Self.finite(data["count"]).flatMap { $0 >= 1 ? $0 : nil }
    ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "appBadge"]))
    emit("appBadge", [
      "origin": Origins.of(origin),
      "count": count.map { floor(min($0, 1e9)) } ?? NSNull(),
      "flag": count == nil && (data["flag"] as? Bool ?? false),
    ])
  }

  private func noteLinkDrop(_ data: [String: Any]) {
    guard visible, let text = data["url"] as? String, text.count <= 8192, let url = URL(string: text),
      ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    else { return }
    let now = CACurrentMediaTime()
    let state = CGEventSourceStateID.combinedSessionState
    let sinceUp = CGEventSource.secondsSinceLastEventType(state, eventType: .leftMouseUp)
    let released = NSEvent.pressedMouseButtons & 1 == 0 && sinceUp < 1 && sinceUp <= CGEventSource.secondsSinceLastEventType(state, eventType: .leftMouseDragged)
    guard released, pointerIsOverPage, now - WebKitPageGestures.linkDropAt > 1 else { return }
    WebKitPageGestures.linkDropAt = now
    ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "linkDrop"]))
    emit("openWindow", ["url": text, "disposition": "foreground", "userGesture": true])
  }

  private var pointerIsOverPage: Bool {
    guard let window else { return false }
    let mouse = NSEvent.mouseLocation
    guard NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: 0) == window.windowNumber else { return false }
    return bounds.contains(convert(window.convertPoint(fromScreen: mouse), from: nil))
  }

  private static func finite(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let double = number.doubleValue
    return double.isFinite ? double : nil
  }
}
