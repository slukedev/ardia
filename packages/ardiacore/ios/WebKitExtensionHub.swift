import AppKit
import CryptoKit
import WebKit

@available(macOS 15.4, *)
final class WebKitExtensionHub: NSObject, WKWebExtensionControllerDelegate {
  struct Loaded {
    let id: String
    let context: WKWebExtensionContext
    let signature: String
    let apis: Set<String>
    let nativeMessaging: Bool
    var grants: WebKitExtensionGrants
    var sidePanel: WebKitExtensionSidePanel
  }

  let profile: String
  let store: WebKitStores.StoreID
  let isPrivate: Bool
  let controller: WKWebExtensionController
  private(set) var bridge: WebKitExtensionBridge!
  private var loaded: [String: Loaded] = [:]
  private var windows: [ObjectIdentifier: WebKitExtensionWindow] = [:]
  private var allSites: Set<String> = []

  init(profile: String, store: WebKitStores.StoreID) {
    self.profile = profile
    self.store = store
    isPrivate = WebKitStores.isPrivate(profile)
    let configuration = isPrivate ? WKWebExtensionController.Configuration.nonPersistent() : WKWebExtensionController.Configuration(identifier: Self.identifier(profile))
    configuration.defaultWebsiteDataStore = WebKitHub.shared.stores.dataStore(for: profile)
    controller = WKWebExtensionController(configuration: configuration)
    super.init()
    bridge = WebKitExtensionBridge(hub: self)
    controller.delegate = self
  }

  static func identifier(_ profile: String) -> UUID {
    let scope = LaunchConfig.shared.dataDirectory ?? ""
    var bytes = Array(SHA256.hash(data: Data("ardia.webkit.extensions|\(scope)|\(profile)".utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return bytes.withUnsafeBufferPointer { NSUUID(uuidBytes: $0.baseAddress!) as UUID }
  }

  static func pattern(_ site: String) -> WKWebExtension.MatchPattern? {
    if let pattern = try? WKWebExtension.MatchPattern(string: site) { return pattern }
    let host = site.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !host.isEmpty, !host.contains("://") else { return nil }
    return try? WKWebExtension.MatchPattern(string: "*://\(host)/*")
  }

  func loadedExtension(_ id: String) -> Loaded? { loaded[id] }

  private func grant(_ context: WKWebExtensionContext, _ wanted: WebKitExtensions.Wanted) {
    let webExtension = context.webExtension
    let forever = Date.distantFuture
    let optional = webExtension.optionalPermissions.filter { wanted.grants.apis.contains($0.rawValue) }
    context.grantedPermissions = Dictionary(uniqueKeysWithValues: webExtension.requestedPermissions.union(optional).map { ($0, forever) })
    let withheld = webExtension.optionalPermissionMatchPatterns.filter { !wanted.grants.hosts.contains($0.string) }
    let patterns = wanted.allSites ? webExtension.allRequestedMatchPatterns.subtracting(withheld) : Set(wanted.sites.compactMap(Self.pattern))
    context.grantedPermissionMatchPatterns = Dictionary(uniqueKeysWithValues: patterns.map { ($0, forever) })
    context.hasAccessToPrivateData = isPrivate || wanted.incognito
    if wanted.allSites { allSites.insert(wanted.id) } else { allSites.remove(wanted.id) }
  }

  func sync(_ wanted: [WebKitExtensions.Wanted], done: @escaping ([String], [String]) -> Void) {
    let ids = Set(wanted.map(\.id))
    for id in loaded.keys where !ids.contains(id) { unload(id) }
    Task { @MainActor in
      var ready: [String] = []
      var failed: [String] = []
      for want in wanted {
        if var current = loaded[want.id], current.signature == want.signature {
          grant(current.context, want)
          current.grants = want.grants
          loaded[want.id] = current
          ready.append(want.id)
          continue
        }
        if loaded[want.id] != nil { unload(want.id) }
        do {
          let webExtension = try await WKWebExtension(resourceBaseURL: want.folder)
          let context = WKWebExtensionContext(for: webExtension)
          context.uniqueIdentifier = want.id
          if let base = URL(string: "webkit-extension://\(want.id)/") { context.baseURL = base }
          context.isInspectable = WebKitHub.inspectable && !isPrivate
          context.inspectionName = want.name
          grant(context, want)
          try controller.load(context)
          loaded[want.id] = Loaded(
            id: want.id, context: context, signature: want.signature, apis: want.apis, nativeMessaging: want.nativeMessaging, grants: want.grants,
            sidePanel: WebKitExtensionSidePanel(manifest: webExtension.manifest))
          ready.append(want.id)
          for tab in openTabs() { context.didOpenTab(tab) }
          if isPrivate { ArdiaEvents.emit("webKit.counted", data: ["name": "privateExtensionLoaded"]) }
        } catch {
          NSLog("[webkit] extension %@ didn't load: %@", want.id, error.localizedDescription)
          failed.append(want.id)
        }
      }
      done(ready, failed)
    }
  }

  private func unload(_ id: String) {
    guard let entry = loaded.removeValue(forKey: id) else { return }
    allSites.remove(id)
    bridge.dropExtension(id)
    try? controller.unload(entry.context)
  }

  func unloadAll() {
    loaded.keys.forEach(unload)
    bridge.closeAll()
  }

  func owns(_ tab: WebKitTab) -> Bool {
    guard tab.webView != nil, !tab.closed, tab.transferKey != nil else { return false }
    guard isPrivate else { return tab.profile == profile }
    return WebKitStores.isPrivate(tab.profile) && ArdiaHost.baseProfile(of: tab.profile) == ArdiaHost.baseProfile(of: profile)
  }

  private func openTabs() -> [WebKitTab] { WebKitHub.shared.transfers.liveTabs.filter(owns) }

  var hasTabs: Bool { WebKitHub.shared.transfers.liveTabs.contains(where: owns) }

  func orderedWindows() -> [(window: NSWindow, tabs: [WebKitTab])] {
    var order: [(window: NSWindow, tabs: [WebKitTab])] = []
    var slots: [ObjectIdentifier: Int] = [:]
    for tab in openTabs() {
      guard let window = tab.window else { continue }
      let key = ObjectIdentifier(window)
      if let slot = slots[key] {
        order[slot].tabs.append(tab)
      } else {
        slots[key] = order.count
        order.append((window, [tab]))
      }
    }
    return order
  }

  func windowTabKeys() -> [[String]] { orderedWindows().map { $0.tabs.compactMap(\.transferKey) } }

  func resolve(_ description: [String: Any]?) -> WebKitTab? {
    guard let description else { return nil }
    let windows = orderedWindows()
    let url = description["url"] as? String ?? ""
    let shows = { (tab: WebKitTab) in url.isEmpty || tab.webView?.url?.absoluteString == url }
    if let w = description["window"] as? Int, let i = description["index"] as? Int, windows.indices.contains(w), windows[w].tabs.indices.contains(i),
      shows(windows[w].tabs[i])
    {
      return windows[w].tabs[i]
    }
    guard !url.isEmpty else { return nil }
    return windows.flatMap(\.tabs).first { $0.webView?.url?.absoluteString == url }
  }

  func window(of tab: WebKitTab) -> WebKitExtensionWindow? {
    guard let window = tab.window else { return nil }
    let key = ObjectIdentifier(window)
    windows = windows.filter { $0.value.window != nil }
    if let known = windows[key] { return known }
    let made = WebKitExtensionWindow(window: window, hub: self)
    windows[key] = made
    return made
  }

  func tabs(in window: NSWindow) -> [WebKitTab] { openTabs().filter { $0.window === window } }

  private func shownTab() -> WebKitTab? {
    let tabs = openTabs()
    return tabs.first { $0.visible && $0.window?.isKeyWindow == true } ?? tabs.first { $0.visible } ?? tabs.first
  }

  func tabOpened(_ tab: WebKitTab) {
    guard !loaded.isEmpty, tab.transferKey != nil else { return }
    if let window = window(of: tab) { controller.didOpenWindow(window) }
    controller.didOpenTab(tab)
  }

  func tabClosed(_ tab: WebKitTab) {
    if let key = tab.transferKey { for id in loaded.keys { loaded[id]?.sidePanel.forgetTab(key) } }
    guard !loaded.isEmpty else { return }
    controller.didCloseTab(tab, windowIsClosing: false)
  }

  func tabShown(_ tab: WebKitTab) {
    guard !loaded.isEmpty, tab.visible, tab.webView != nil, tab.transferKey != nil else { return }
    controller.didActivateTab(tab, previousActiveTab: nil)
    if let window = window(of: tab), window.window?.isKeyWindow == true { controller.didFocusWindow(window) }
  }

  func tabChanged(_ tab: WebKitTab) {
    guard !loaded.isEmpty, tab.transferKey != nil else { return }
    controller.didChangeTabProperties([.url, .title, .loading], for: tab)
  }

  func actionStates(_ ids: [String], tab: WebKitTab) -> [String: Any] {
    var states: [String: Any] = [:]
    for id in ids {
      guard let action = loaded[id]?.context.action(for: tab) else { continue }
      states[id] = [
        "title": action.label,
        "badgeText": action.badgeText,
        "badgeColor": NSNull(),
        "badgeTextColor": NSNull(),
        "popup": "",
        "enabled": action.isEnabled,
        "icon": action.icon(for: CGSize(width: 16, height: 16))?.pngDataURL(points: 16, scale: 2) ?? "",
      ]
    }
    return states
  }

  func performAction(_ id: String, tab: WebKitTab) -> String? {
    guard let entry = loaded[id] else { return nil }
    ArdiaEvents.emit("webKit.counted", data: ["name": "extensionAction"])
    if entry.sidePanel.opensOnAction, entry.sidePanel.page(tab: tab.transferKey) != nil { return "sidePanel" }
    entry.context.userGesturePerformed(in: tab)
    entry.context.performAction(for: tab)
    return "none"
  }

  func sidePanelURL(_ id: String, tab: WebKitTab) -> String? {
    guard let entry = loaded[id], let page = entry.sidePanel.page(tab: tab.transferKey) else { return nil }
    return entry.context.baseURL.absoluteString + page
  }

  func pageConfiguration(for url: URL) -> WKWebViewConfiguration? {
    guard url.scheme == "webkit-extension", let host = url.host, let entry = loaded[host] else { return nil }
    return entry.context.webViewConfiguration
  }

  private func panelChanged(_ id: String) {
    ArdiaEvents.emit("extensions.action", data: ["profile": ArdiaHost.baseProfile(of: profile), "id": id, "kind": "sidePanel"])
  }

  func sidePanelCall(_ method: String, args: [Any], tabs: [WebKitTab?], extensionId: String) -> [String: Any] {
    guard var entry = loaded[extensionId] else { return ["error": "The extension isn't loaded."] }
    let options = args.first as? [String: Any] ?? [:]
    let asksTab = options["tabId"] != nil
    let tab = ((options["tabId"] as? [String: Any])?["__tab"] as? Int).flatMap { tabs.indices.contains($0) ? tabs[$0] : nil }
    if asksTab, tab == nil { return ["error": "No tab with the given id."] }
    let windows = orderedWindows()
    let windowTab = ((options["windowId"] as? [String: Any])?["__window"] as? Int).flatMap { at -> WebKitTab? in
      guard windows.indices.contains(at) else { return nil }
      return windows[at].tabs.first { $0.visible } ?? windows[at].tabs.first
    }
    switch method {
    case "getOptions":
      let shown = entry.sidePanel.options(tab: tab?.transferKey)
      var result: [String: Any] = ["enabled": shown.enabled ?? true]
      if let path = shown.path { result["path"] = path }
      return ["result": result]
    case "setOptions":
      entry.sidePanel.set(options, tab: tab?.transferKey)
      loaded[extensionId] = entry
      panelChanged(extensionId)
      return ["result": NSNull()]
    case "setPanelBehavior":
      if let opens = options["openPanelOnActionClick"] as? Bool { entry.sidePanel.opensOnAction = opens }
      loaded[extensionId] = entry
      return ["result": NSNull()]
    case "getPanelBehavior":
      return ["result": ["openPanelOnActionClick": entry.sidePanel.opensOnAction]]
    case "getLayout":
      return ["result": ["side": "right"]]
    case "open", "close":
      guard let target = tab ?? windowTab ?? shownTab(), let key = target.transferKey else { return ["error": "No window to show the side panel in."] }
      if method == "open", entry.sidePanel.page(tab: key) == nil { return ["error": "No active side panel for this tab."] }
      ArdiaEvents.emit("extensions.sidePanel", data: ["tabId": key, "extensionId": extensionId, "open": method == "open"])
      return ["result": NSNull()]
    default:
      return ["error": "sidePanel.\(method) isn't supported."]
    }
  }

  func startDownload(_ options: [String: Any]) -> [String: Any]? {
    guard let text = options["url"] as? String, let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https", "data"].contains(scheme) else {
      return nil
    }
    var request = URLRequest(url: url)
    if (options["method"] as? String)?.uppercased() == "POST" { request.httpMethod = "POST" }
    for header in options["headers"] as? [[String: Any]] ?? [] {
      if let name = header["name"] as? String, let value = header["value"] as? String { request.setValue(value, forHTTPHeaderField: name) }
    }
    if let body = options["body"] as? String { request.httpBody = Data(body.utf8) }
    let view: WKWebView = openTabs().first?.webView ?? WebKitHub.shared.resumeHost(for: profile)
    let owner = profile
    view.startDownload(using: request) { [weak view] download in WebKitHub.shared.downloads.adopt(download, profile: owner, webView: view) }
    var started: [String: Any] = ["url": url.absoluteString]
    if let filename = options["filename"] as? String { started["filename"] = filename }
    return started
  }

  func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
    orderedWindows().compactMap { $0.tabs.first.flatMap(window(of:)) }
  }

  func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
    shownTab().flatMap(window(of:))
  }

  func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                              for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
    let source = (configuration.parentTab as? WebKitTab) ?? shownTab()
    if let url = configuration.url, let source {
      source.emit("openWindow", ["url": url.absoluteString, "disposition": configuration.shouldBeActive ? "foreground" : "background", "userGesture": true])
    }
    completionHandler(nil, nil)
  }

  func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext,
                              completionHandler: @escaping ((any Error)?) -> Void) {
    if let url = extensionContext.optionsPageURL, let source = shownTab() {
      source.emit("openWindow", ["url": url.absoluteString, "disposition": "foreground", "userGesture": true])
    }
    completionHandler(nil)
  }

  func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                              in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                              completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
    let granted = loaded[extensionContext.uniqueIdentifier]?.grants.apis ?? []
    let allowed = extensionContext.webExtension.requestedPermissions.union(extensionContext.webExtension.optionalPermissions.filter { granted.contains($0.rawValue) })
    completionHandler(permissions.intersection(allowed), nil)
  }

  func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?,
                              for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<URL>, Date?) -> Void) {
    completionHandler(allSites.contains(extensionContext.uniqueIdentifier) ? urls : [], nil)
  }

  func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                              in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                              completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
    let granted = loaded[extensionContext.uniqueIdentifier]?.grants.hosts ?? []
    let everything = allSites.contains(extensionContext.uniqueIdentifier)
    completionHandler(everything ? matchPatterns.filter { granted.contains($0.string) || extensionContext.webExtension.requestedPermissionMatchPatterns.contains($0) } : [], nil)
  }

  func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?,
                              for extensionContext: WKWebExtensionContext, replyHandler: @escaping (Any?, (any Error)?) -> Void) {
    bridge.sendMessage(message, to: applicationIdentifier, from: extensionContext, reply: replyHandler)
  }

  func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort, for extensionContext: WKWebExtensionContext,
                              completionHandler: @escaping ((any Error)?) -> Void) {
    bridge.connect(port, from: extensionContext, completion: completionHandler)
  }

  func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
                              forExtensionContext context: WKWebExtensionContext) {
    ArdiaEvents.emit("extensions.action", data: ["profile": ArdiaHost.baseProfile(of: profile), "id": context.uniqueIdentifier, "kind": "action"])
  }

  func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                              for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
    guard let popover = action.popupPopover, let tab = (action.associatedTab as? WebKitTab) ?? shownTab(), tab.window != nil else {
      return completionHandler(nil)
    }
    if LaunchConfig.shared.background {
      NSLog("[webkit] extension popup for %@ (background mode, not shown)", context.uniqueIdentifier)
      action.closePopup()
      return completionHandler(nil)
    }
    let anchor = NSRect(x: tab.bounds.maxX - 24, y: tab.bounds.minY, width: 1, height: 1)
    popover.show(relativeTo: anchor, of: tab, preferredEdge: .minY)
    completionHandler(nil)
  }
}
