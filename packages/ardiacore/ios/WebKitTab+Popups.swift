import AppKit
import WebKit

extension WebKitTab {
  private static let popupSetting = "popups"
  private static let blockedPopupsKept = 20

  @objc(_webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:completionHandler:)
  func webViewCreatesWebView(_ webView: WKWebView, configuration: WKWebViewConfiguration, action: WKNavigationAction,
                             windowFeatures: WKWindowFeatures, completionHandler: @escaping (WKWebView?) -> Void) {
    let disposition = Self.disposition(action, windowFeatures)
    guard !Self.userInitiated(action), disposition == "popup" || disposition == "foreground" else {
      return completionHandler(openPopup(configuration, action: action, disposition: disposition, gesture: true))
    }
    guard let origin = popupOrigin(webView) else { return completionHandler(blockPopup(action, disposition: disposition, in: webView)) }
    WebKitHub.shared.permissions.answers(profile: profile, origin: origin, kinds: [Self.popupSetting]) { [weak self, weak webView] answers in
      guard let self, let webView, !self.closed, webView === self.webView else { return completionHandler(nil) }
      if answers[Self.popupSetting] == true {
        return completionHandler(self.openPopup(configuration, action: action, disposition: disposition, gesture: false))
      }
      completionHandler(self.blockPopup(action, disposition: disposition, in: webView))
    }
  }

  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
               windowFeatures: WKWindowFeatures) -> WKWebView? {
    let disposition = Self.disposition(action, windowFeatures)
    guard !Self.userInitiated(action), disposition == "popup" || disposition == "foreground" else {
      return openPopup(configuration, action: action, disposition: disposition, gesture: true)
    }
    return blockPopup(action, disposition: disposition, in: webView)
  }

  private static func disposition(_ action: WKNavigationAction, _ features: WKWindowFeatures) -> String {
    let flags = action.modifierFlags
    if flags.contains(.command) || action.buttonNumber == 2 { return flags.contains(.shift) ? "foreground" : "background" }
    return features.width != nil || features.height != nil ? "popup" : "foreground"
  }

  private func popupOrigin(_ webView: WKWebView) -> String? {
    (webView.backForwardList.currentItem?.url ?? webView.url).flatMap(Origins.of)
  }

  private func openPopup(_ configuration: WKWebViewConfiguration, action: WKNavigationAction, disposition: String, gesture: Bool) -> WKWebView {
    let preferences = WKPreferences()
    WebKitHub.applyBasePreferences(preferences)
    configuration.preferences = preferences
    let child = WebKitWebView(frame: .zero, configuration: configuration)
    let id = WebKitHub.shared.transfers.offer(child)
    WebKitHeldPopup.hold(child, offer: id, opener: self)
    emit("openWindow", ["url": action.request.url?.absoluteString ?? "", "disposition": disposition, "adoptId": id, "userGesture": gesture])
    return child
  }

  private func blockPopup(_ action: WKNavigationAction, disposition: String, in webView: WKWebView) -> WKWebView? {
    let url = action.request.url?.absoluteString ?? ""
    safety.lastPopup += 1
    let id = "\(safety.lastPopup)"
    let current = webView.backForwardList.currentItem
    safety.blockedPopups = safety.blockedPopups.filter { $0.value.item === current }
    safety.blockedPopups[id] = WebKitTabSafety.BlockedPopup(url: url, disposition: disposition, item: current)
    if safety.blockedPopups.count > Self.blockedPopupsKept, let oldest = safety.blockedPopups.keys.min(by: { Int($0) ?? 0 < Int($1) ?? 0 }) {
      safety.blockedPopups.removeValue(forKey: oldest)
    }
    ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "popupBlocked"]))
    emit("popupBlocked", ["id": id, "url": url, "origin": popupOrigin(webView) ?? ""])
    return nil
  }

  func openBlocked(_ popupId: String, always: Bool) {
    guard let view = webView, let popup = safety.blockedPopups[popupId], popup.item === view.backForwardList.currentItem else { return }
    if always, let origin = popupOrigin(view) { allowPopups(origin) }
    safety.blockedPopups.removeValue(forKey: popupId)
    ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "blockedPopupOpened"]))
    emit("openWindow", ["url": popup.url, "disposition": popup.disposition, "userGesture": true])
  }

  private func allowPopups(_ origin: String) {
    let hub = WebKitHub.shared
    if WebKitPermissions.sharesChromiumRules(profile) {
      return ArdiaServices.setSiteSetting("allow", profile: profile, origin: origin, type: Self.popupSetting)
    }
    hub.stores.update(hub.stores.id(of: profile)) { $0.remembered[WebKitStores.SiteKey(site: origin, kind: Self.popupSetting)] = true }
  }
}

final class WebKitHeldPopup: NSObject, WKNavigationDelegate, WKUIDelegate {
  private struct Held {
    let action: WKNavigationAction
    let preferences: WKWebpagePreferences
    let decide: (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
  }

  private static var holderKey: UInt8 = 0
  private static var closedOffers: [String] = []
  private static let closedOffersKept = 64
  private var held: [Held] = []
  private var offer: String?
  private weak var opener: WebKitTab?

  static func hold(_ view: WKWebView, offer: String, opener: WebKitTab?) {
    let holder = WebKitHeldPopup()
    holder.offer = offer
    holder.opener = opener
    objc_setAssociatedObject(view, &holderKey, holder, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    view.navigationDelegate = holder
    view.uiDelegate = holder
  }

  static func closedBeforeAdoption(_ offer: String) -> Bool { closedOffers.contains(offer) }

  private static func take(_ view: WKWebView) -> [Held] {
    guard let holder = objc_getAssociatedObject(view, &holderKey) as? WebKitHeldPopup else { return [] }
    objc_setAssociatedObject(view, &holderKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    if view.navigationDelegate === holder { view.navigationDelegate = nil }
    if view.uiDelegate === holder { view.uiDelegate = nil }
    defer { holder.held = [] }
    return holder.held
  }

  static func release(_ view: WKWebView, to tab: WebKitTab) {
    for held in take(view) { tab.webView(view, decidePolicyFor: held.action, preferences: held.preferences, decisionHandler: held.decide) }
  }

  static func cancel(_ view: WKWebView) {
    for held in take(view) { held.decide(.cancel, held.preferences) }
  }

  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences,
               decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
    if let tab = WebKitHub.shared.transfers.owner(of: webView) {
      return tab.webView(webView, decidePolicyFor: action, preferences: preferences, decisionHandler: decisionHandler)
    }
    guard action.targetFrame?.isMainFrame == true, let url = action.request.url, url.scheme?.lowercased() != "about" else {
      return decisionHandler(.allow, preferences)
    }
    held.append(Held(action: action, preferences: preferences, decide: decisionHandler))
  }

  func webViewDidClose(_ webView: WKWebView) {
    guard let offer, WebKitHub.shared.transfers.claimOffered(offer) === webView else { return }
    Self.closedOffers.append(offer)
    if Self.closedOffers.count > Self.closedOffersKept { Self.closedOffers.removeFirst() }
    WebKitHub.close(webView)
  }
}
