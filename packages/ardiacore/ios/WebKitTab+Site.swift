import Foundation
import WebKit

extension WebKitTab {
  func siteMessage(_ kind: String, data: [String: Any]?, frameInfo: WKFrameInfo) {
    guard let data else { return }
    switch kind {
    case "loginField": if frameInfo.isMainFrame { WebKitHub.shared.logins.fieldPressed(self, data: data) }
    case "loginSubmit": if frameInfo.isMainFrame { WebKitHub.shared.logins.submitted(self, data: data) }
    case "notification": if frameInfo.isMainFrame { WebKitHub.shared.notifications.received(data, from: self) }
    default: break
    }
  }

  func siteCommitted() {
    WebKitHub.shared.notifications.sharePermission(with: self)
  }

  func fillLogin(username: String, password: String) {
    let code = "window.__ardiaLogins ? window.__ardiaLogins.fill(\(Self.jsString(username)), \(Self.jsString(password))) : false"
    webView?.evaluateJavaScript(code, in: nil, in: WebKitHub.world) { _ in }
  }
}
