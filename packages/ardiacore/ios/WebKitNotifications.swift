import Foundation
import WebKit

final class WebKitNotifications {
  private struct Shown {
    let wireId: String
    let profile: String
    let tag: String
    let scope: String
    let origin: String
    let entry: [String: Any]
  }

  private struct WorkerShown {
    let wireId: String
    let profile: String
    let origin: String
    let tag: String
    let notification: NSDictionary
    let order: Int
    weak var store: WKWebsiteDataStore?
  }

  private var workerShown: [String: WorkerShown] = [:]
  private var workerDelegates: [ObjectIdentifier: WebKitWorkerNotifications] = [:]
  private var granted: [String: [String: Bool]] = [:]
  private var workerCount = 0
  private var sequence = 0
  private static let launch = String(UUID().uuidString.prefix(8)).lowercased()

  private static let shownPerScope = 50

  private var shown: [String: [Shown]] = [:]

  static func reply(_ detail: [String: Any], to tab: WebKitTab) {
    guard let data = try? JSONSerialization.data(withJSONObject: detail), let json = String(data: data, encoding: .utf8) else { return }
    let code = "document.dispatchEvent(new CustomEvent(\"ardia:notification-reply\", { detail: \(WebKitTab.jsString(json)) }))"
    tab.webView?.evaluateJavaScript(code, in: nil, in: WebKitHub.world) { _ in }
  }

  private static func origin(of tab: WebKitTab) -> String? {
    guard let url = tab.webView?.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
    return Origins.of(url)
  }

  private static func pageWireId(_ id: String, tab: WebKitTab) -> String { "wk-n\(launch)-t\(-tab.browserId)-\(id)" }

  private func nextWireId() -> String {
    sequence += 1
    return "wk-n\(Self.launch)-\(sequence)"
  }

  private static func livePage(_ wireId: String) -> (tab: WebKitTab, id: String)? {
    let prefix = "wk-n\(launch)-t"
    guard wireId.hasPrefix(prefix) else { return nil }
    let rest = wireId.dropFirst(prefix.count)
    guard let dash = rest.firstIndex(of: "-"), let browser = Int32(rest[..<dash]) else { return nil }
    guard let tab = WebKitHub.shared.transfers.liveTabs.first(where: { -$0.browserId == browser }) else { return nil }
    return (tab, String(rest[rest.index(after: dash)...]))
  }

  private static func liveTab(profile: String, origin: String) -> WebKitTab? {
    let tabs = WebKitHub.shared.transfers.liveTabs.filter { $0.profile == profile && Self.origin(of: $0) == origin }
    return tabs.first(where: \.visible) ?? tabs.first
  }

  private static func emitClose(_ wireId: String, via tab: WebKitTab?) {
    if let tab { return tab.emit("notificationClose", ["id": wireId]) }
    ArdiaEvents.emit("webKit.notificationClose", data: ArdiaConsentStamp.begin().onto(["id": wireId]))
  }

  func sharePermission(with tab: WebKitTab) {
    guard let origin = Self.origin(of: tab) else { return }
    WebKitHub.shared.permissions.answers(profile: tab.profile, origin: origin, kinds: ["notifications"]) { [weak tab] answers in
      guard let tab, Self.origin(of: tab) == origin else { return }
      WebKitHub.shared.notifications.note(answers["notifications"], profile: tab.profile, origin: origin)
      let value = answers["notifications"].map { $0 ? "granted" : "denied" } ?? "default"
      Self.reply(["type": "permission", "value": value], to: tab)
    }
  }

  private static func scope(_ data: [String: Any], origin: String) -> String? {
    guard let raw = data["scope"] as? String, let url = URL(string: raw), Origins.of(url) == origin else { return nil }
    return url.absoluteString
  }

  private static func shownKey(_ tab: WebKitTab, scope: String) -> String { "\(WebKitHub.shared.stores.id(of: tab.profile).wireKey)|\(scope)" }

  private func remember(_ entry: [String: Any], wireId: String, tag: String, scope: String, origin: String, key: String, tab: WebKitTab) {
    if !tag.isEmpty, let replaced = shown[key]?.first(where: { $0.tag == tag }) {
      forgetShown(replaced.wireId)
      Self.emitClose(replaced.wireId, via: tab)
    }
    var list = (shown[key] ?? []).filter { $0.wireId != wireId }
    list.append(Shown(wireId: wireId, profile: tab.profile, tag: tag, scope: scope, origin: origin, entry: entry))
    shown[key] = Array(list.suffix(Self.shownPerScope))
  }

  @discardableResult
  private func forgetShown(_ wireId: String) -> Shown? {
    var found: Shown?
    for (key, list) in shown where list.contains(where: { $0.wireId == wireId }) {
      found = list.first { $0.wireId == wireId }
      let rest = list.filter { $0.wireId != wireId }
      shown[key] = rest.isEmpty ? nil : rest
    }
    return found
  }

  private func shows(_ wireId: String, for tab: WebKitTab, origin: String) -> Bool {
    let site = "\(WebKitHub.shared.stores.id(of: tab.profile).wireKey)|\(origin)/"
    return shown.contains { key, list in key.hasPrefix(site) && list.contains { $0.wireId == wireId } }
  }

  private func list(_ data: [String: Any], id: String, origin: String, tab: WebKitTab) {
    guard let scope = Self.scope(data, origin: origin) else { return Self.reply(["type": "list", "id": id, "items": []], to: tab) }
    let tag = data["tag"] as? String ?? ""
    let items = (shown[Self.shownKey(tab, scope: scope)] ?? []).filter { tag.isEmpty || $0.tag == tag }.map { shown -> [String: Any] in
      var entry = shown.entry
      entry["id"] = shown.wireId
      return entry
    }
    Self.reply(["type": "list", "id": id, "items": items], to: tab)
  }

  static func senderOrigin(_ sender: WKSecurityOrigin, page: String?) -> String? {
    guard ["http", "https"].contains(sender.protocol.lowercased()), !sender.host.isEmpty else { return nil }
    let origin = Origins.of(sender)
    return origin == page ? origin : nil
  }

  func received(_ data: [String: Any], from tab: WebKitTab, sender: WKSecurityOrigin) {
    guard let type = data["type"] as? String, let id = data["id"] as? String, let origin = Self.senderOrigin(sender, page: Self.origin(of: tab)) else { return }
    switch type {
    case "list": list(data, id: id, origin: origin, tab: tab)
    case "request":
      WebKitHub.shared.permissions.request(browserId: tab.browserId, tabId: tab.transferKey, profile: tab.profile, origin: origin, kinds: ["notifications"]) {
        [weak tab] allowed in
        guard let tab else { return }
        WebKitHub.shared.notifications.note(allowed, profile: tab.profile, origin: origin)
        guard Self.origin(of: tab) == origin else { return }
        Self.reply(["type": "answer", "id": id, "value": allowed ? "granted" : "denied"], to: tab)
      }
    case "show":
      let persistent = data["persistent"] as? Bool == true
      let scope = Self.scope(data, origin: origin)
      if persistent && scope == nil { return }
      let profile = tab.profile
      WebKitHub.shared.permissions.answers(profile: profile, origin: origin, kinds: ["notifications"]) { [weak self, weak tab] answers in
        self?.note(answers["notifications"], profile: profile, origin: origin)
        guard let self, let tab, answers["notifications"] == true, !WebKitStores.isPrivate(tab.profile), Self.origin(of: tab) == origin else { return }
        let wireId = persistent ? self.nextWireId() : Self.pageWireId(id, tab: tab)
        if persistent, let scope {
          let entry: [String: Any] = [
            "title": data["title"] as? String ?? "", "body": data["body"] as? String ?? "", "icon": data["icon"] as? String ?? "",
            "tag": data["tag"] as? String ?? "", "data": data["data"] ?? NSNull(), "silent": data["silent"] as? Bool ?? false,
            "requireInteraction": data["requireInteraction"] as? Bool ?? false, "timestamp": data["timestamp"] ?? Date().timeIntervalSince1970 * 1000,
          ]
          self.remember(entry, wireId: wireId, tag: data["tag"] as? String ?? "", scope: scope, origin: origin, key: Self.shownKey(tab, scope: scope), tab: tab)
        }
        tab.emit("notification", [
          "id": wireId, "title": data["title"] as? String ?? "", "body": data["body"] as? String ?? "",
          "icon": (data["icon"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? NSNull(), "tag": data["tag"] as? String ?? "",
          "silent": data["silent"] as? Bool ?? false, "requireInteraction": data["requireInteraction"] as? Bool ?? false,
          "origin": origin, "tabId": tab.transferKey ?? NSNull(), "isMainFrame": true,
        ])
        ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": persistent ? "workerNotification" : "notification"]))
      }
    case "close":
      let wireId = id.hasPrefix("wk-n") ? id : Self.pageWireId(id, tab: tab)
      if id.hasPrefix("wk-n"), !shows(wireId, for: tab, origin: origin) { return }
      forgetShown(wireId)
      tab.emit("notificationClose", ["id": wireId])
    default: break
    }
  }

  func act(_ wireId: String, action: String, in tab: WebKitTab) { act(wireId, action: action) }

  func act(_ wireId: String, action: String) {
    if let worker = workerShown.removeValue(forKey: wireId) { return deliver(action, worker.notification, to: worker.store) }
    if let page = forgetShown(wireId) {
      guard let made = Self.notificationData(page) else { return }
      return deliver(action, made, to: WebKitHub.shared.stores.dataStore(for: page.profile))
    }
    guard let (tab, id) = Self.livePage(wireId) else { return }
    Self.reply(["type": action == "click" ? "click" : "close", "id": id], to: tab)
  }

  func note(_ allowed: Bool?, profile: String, origin: String) {
    guard let allowed, !WebKitStores.isPrivate(profile) else { return }
    let base = ArdiaHost.baseProfile(of: profile)
    guard granted[base]?[origin] != allowed else { return }
    granted[base, default: [:]][origin] = allowed
    Self.announce(allowed, origin: origin)
  }

  private typealias PolicyUpdate = @convention(c) (UnsafeRawPointer, UnsafeRawPointer, Bool) -> Void
  private typealias MakeString = @convention(c) (UnsafePointer<CChar>) -> UnsafeRawPointer?
  private typealias MakeOrigin = @convention(c) (UnsafeRawPointer) -> UnsafeRawPointer?
  private typealias Release = @convention(c) (UnsafeRawPointer) -> Void
  private typealias ManagerGetter = @convention(c) (AnyObject, Selector) -> UnsafeRawPointer?

  private static let webKitImage = dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", RTLD_LAZY | RTLD_NOLOAD)

  private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
    guard let webKitImage, let found = dlsym(webKitImage, name) else { return nil }
    return unsafeBitCast(found, to: type)
  }

  private static func manager(_ target: AnyObject, _ method: Method?, _ selector: Selector) -> UnsafeRawPointer? {
    guard let method else { return nil }
    return unsafeBitCast(method_getImplementation(method), to: ManagerGetter.self)(target, selector)
  }

  private static func notificationManagers() -> [UnsafeRawPointer] {
    let workers = NSSelectorFromString("_sharedServiceWorkerNotificationManager")
    let pages = NSSelectorFromString("_notificationManagerForTesting")
    let pool = WebKitHub.shared.transfers.views.first?.configuration.processPool
    return [
      manager(WKWebsiteDataStore.self, class_getClassMethod(WKWebsiteDataStore.self, workers), workers),
      pool.flatMap { manager($0, class_getInstanceMethod(WKProcessPool.self, pages), pages) },
    ].compactMap { $0 }
  }

  private static func announce(_ allowed: Bool, origin: String) {
    guard let update = symbol("WKNotificationManagerProviderDidUpdateNotificationPolicy", as: PolicyUpdate.self),
      let makeString = symbol("WKStringCreateWithUTF8CString", as: MakeString.self),
      let makeOrigin = symbol("WKSecurityOriginCreateFromString", as: MakeOrigin.self),
      let release = symbol("WKRelease", as: Release.self),
      let string = origin.withCString(makeString)
    else { return }
    defer { release(string) }
    guard let securityOrigin = makeOrigin(string) else { return }
    defer { release(securityOrigin) }
    for manager in notificationManagers() { update(manager, securityOrigin, allowed) }
  }

  func forgetProfile(_ profile: String) {
    granted.removeValue(forKey: ArdiaHost.baseProfile(of: profile))
    workerShown = workerShown.filter { $0.value.profile != profile }
    workerDelegates = workerDelegates.filter { $0.value.profile != profile }
    shown = shown.compactMapValues { list in
      let kept = list.filter { $0.profile != profile }
      return kept.isEmpty ? nil : kept
    }
  }

  func attachWorkers(to store: WKWebsiteDataStore, profile: String) {
    let setter = NSSelectorFromString("set_delegate:")
    guard !WebKitStores.isPrivate(profile), workerDelegates[ObjectIdentifier(store)] == nil, store.responds(to: setter) else { return }
    let delegate = WebKitWorkerNotifications(profile: profile, owner: self)
    workerDelegates[ObjectIdentifier(store)] = delegate
    store.perform(setter, with: delegate)
    primePermissions(profile)
  }

  private func primePermissions(_ profile: String) {
    ArdiaServices.siteSettingsOrigins(profile: profile) { origins, _ in
      let web = (origins as? [String] ?? []).compactMap(URL.init(string:)).filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
      DispatchQueue.main.async {
        for origin in Set(web.compactMap(Origins.of)) {
          WebKitHub.shared.permissions.answers(profile: profile, origin: origin, kinds: ["notifications"]) { [weak self] answers in
            self?.note(answers["notifications"], profile: profile, origin: origin)
          }
        }
      }
    }
  }

  fileprivate func workerPermissions(_ profile: String) -> [String: NSNumber] {
    (granted[ArdiaHost.baseProfile(of: profile)] ?? [:]).mapValues { NSNumber(value: $0) }
  }

  fileprivate func workerDisplayed(_ profile: String, origin: String) -> [NSDictionary] {
    workerShown.values.filter { $0.profile == profile && $0.origin == origin }.map(\.notification)
  }

  private static func text(_ notification: NSObject, _ key: String) -> String {
    notification.responds(to: NSSelectorFromString(key)) ? notification.value(forKey: key) as? String ?? "" : ""
  }

  fileprivate func workerShow(_ notification: NSObject, store: WKWebsiteDataStore, profile: String) {
    let representation = NSSelectorFromString("dictionaryRepresentation")
    guard notification.responds(to: representation), notification.responds(to: NSSelectorFromString("securityOrigin")),
      let dictionary = notification.perform(representation)?.takeUnretainedValue() as? NSDictionary,
      let url = notification.value(forKey: "securityOrigin") as? URL, let origin = Origins.of(url),
      ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    else { return }
    let title = Self.text(notification, "title")
    let body = Self.text(notification, "body")
    let tag = Self.text(notification, "tag")
    let silent = notification.responds(to: NSSelectorFromString("alert")) && (notification.value(forKey: "alert") as? NSNumber)?.intValue == 1
    WebKitHub.shared.permissions.answers(profile: profile, origin: origin, kinds: ["notifications"]) { [weak self, weak store] answers in
      guard let self, let store else { return }
      self.note(answers["notifications"], profile: profile, origin: origin)
      guard answers["notifications"] == true else { return }
      let tab = Self.liveTab(profile: profile, origin: origin)
      if !tag.isEmpty, let replaced = self.workerShown.values.first(where: { $0.profile == profile && $0.origin == origin && $0.tag == tag }) {
        self.workerShown.removeValue(forKey: replaced.wireId)
        Self.emitClose(replaced.wireId, via: tab)
      }
      self.workerCount += 1
      let wireId = self.nextWireId()
      self.workerShown[wireId] = WorkerShown(
        wireId: wireId, profile: profile, origin: origin, tag: tag, notification: dictionary, order: self.workerCount, store: store)
      if self.workerShown.count > 200, let oldest = self.workerShown.values.min(by: { $0.order < $1.order }) {
        self.workerShown.removeValue(forKey: oldest.wireId)
      }
      let shown: [String: Any] = [
        "id": wireId, "title": title, "body": body, "icon": NSNull(), "tag": tag, "silent": silent, "requireInteraction": false,
        "origin": origin, "tabId": tab?.transferKey ?? NSNull(), "isMainFrame": true,
      ]
      if let tab { tab.emit("notification", shown) } else { ArdiaEvents.emit("webKit.notification", data: ArdiaConsentStamp.begin().onto(["profile": profile, "notification": shown])) }
      ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "workerShownNotification"]))
    }
  }

  fileprivate func openWindow(_ url: URL, store: WKWebsiteDataStore, profile: String, origin: String, done: @escaping (WKWebView?) -> Void) {
    guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return done(nil) }
    let configuration = WebKitHub.shared.configuration(profile: profile)
    guard configuration.websiteDataStore === store else { return done(nil) }
    let view = WebKitWebView(frame: .zero, configuration: configuration)
    let adoptId = WebKitHub.shared.transfers.offer(view)
    WebKitHeldPopup.hold(view, offer: adoptId, opener: Self.liveTab(profile: profile, origin: origin))
    view.load(URLRequest(url: url))
    let request: [String: Any] = ["url": url.absoluteString, "disposition": "foreground", "adoptId": adoptId, "userGesture": true]
    let opener = Self.liveTab(profile: profile, origin: origin) ?? WebKitHub.shared.transfers.liveTabs.first { $0.profile == profile && $0.visible }
    if let opener { opener.emit("openWindow", request) } else {
      ArdiaEvents.emit("webKit.openWindow", data: ArdiaConsentStamp.begin().onto(request.merging(["profile": profile]) { kept, _ in kept }))
    }
    done(view)
  }

  private static func notificationData(_ page: Shown) -> NSDictionary? {
    guard let type = NSClassFromString("_WKMutableNotificationData") as? NSObject.Type, let scope = URL(string: page.scope),
      let origin = URL(string: page.origin)
    else { return nil }
    let made = type.init()
    let values: [String: Any] = [
      "title": page.entry["title"] as? String ?? "", "body": page.entry["body"] as? String ?? "", "tag": page.tag,
      "securityOrigin": origin, "serviceWorkerRegistrationURL": scope, "uuid": UUID(),
    ]
    for (key, value) in values where made.responds(to: NSSelectorFromString("set\(key.prefix(1).uppercased())\(key.dropFirst()):")) {
      made.setValue(value, forKey: key)
    }
    let representation = NSSelectorFromString("dictionaryRepresentation")
    guard made.responds(to: representation) else { return nil }
    return made.perform(representation)?.takeUnretainedValue() as? NSDictionary
  }

  private func deliver(_ action: String, _ notification: NSDictionary, to store: WKWebsiteDataStore?) {
    guard let store else { return }
    let click = action == "click"
    let selector = NSSelectorFromString(click ? "_processPersistentNotificationClick:completionHandler:" : "_processPersistentNotificationClose:completionHandler:")
    guard store.responds(to: selector) else { return }
    let target = store as AnyObject
    let done: (Bool) -> Void = { delivered in
      guard delivered, click else { return }
      DispatchQueue.main.async { ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "workerClick"])) }
    }
    if click { target.processPersistentNotificationClick?(notification, completionHandler: done) } else {
      target.processPersistentNotificationClose?(notification, completionHandler: done)
    }
  }
}

@objc private protocol WebKitPersistentNotificationEvents {
  @objc(_processPersistentNotificationClick:completionHandler:)
  optional func processPersistentNotificationClick(_ notification: NSDictionary, completionHandler: @escaping (Bool) -> Void)
  @objc(_processPersistentNotificationClose:completionHandler:)
  optional func processPersistentNotificationClose(_ notification: NSDictionary, completionHandler: @escaping (Bool) -> Void)
}

final class WebKitWorkerNotifications: NSObject {
  let profile: String
  private weak var owner: WebKitNotifications?

  init(profile: String, owner: WebKitNotifications) {
    self.profile = profile
    self.owner = owner
  }

  @objc(notificationPermissionsForWebsiteDataStore:)
  func notificationPermissions(forWebsiteDataStore store: WKWebsiteDataStore) -> [String: NSNumber] {
    owner?.workerPermissions(profile) ?? [:]
  }

  @objc(websiteDataStore:showNotification:)
  func websiteDataStore(_ store: WKWebsiteDataStore, showNotification notification: NSObject) {
    owner?.workerShow(notification, store: store, profile: profile)
  }

  @objc(websiteDataStore:openWindow:fromServiceWorkerOrigin:completionHandler:)
  func websiteDataStore(_ store: WKWebsiteDataStore, openWindow url: URL, fromServiceWorkerOrigin origin: WKSecurityOrigin, completionHandler: @escaping (WKWebView?) -> Void) {
    guard let owner else { return completionHandler(nil) }
    owner.openWindow(url, store: store, profile: profile, origin: Origins.of(origin), done: completionHandler)
  }

  @objc(websiteDataStore:getDisplayedNotificationsForWorkerOrigin:completionHandler:)
  func websiteDataStore(_ store: WKWebsiteDataStore, displayedNotificationsFor origin: WKSecurityOrigin, completionHandler: @escaping ([NSDictionary]) -> Void) {
    completionHandler(owner?.workerDisplayed(profile, origin: Origins.of(origin)) ?? [])
  }
}
