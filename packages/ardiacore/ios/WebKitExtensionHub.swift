import AppKit
import CryptoKit
import WebKit

@available(macOS 15.4, *)
final class WebKitExtensionHub: NSObject, WKWebExtensionControllerDelegate {
  private struct Loaded {
    let context: WKWebExtensionContext
    let folder: URL
  }

  let profile: String
  let controller: WKWebExtensionController
  private var loaded: [String: Loaded] = [:]
  private var windows: [ObjectIdentifier: WebKitExtensionWindow] = [:]
  private var allSites: Set<String> = []

  init(profile: String) {
    self.profile = profile
    let configuration = WKWebExtensionController.Configuration(identifier: Self.identifier(profile))
    configuration.defaultWebsiteDataStore = WebKitHub.shared.stores.dataStore(for: profile)
    controller = WKWebExtensionController(configuration: configuration)
    super.init()
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

  private func grant(_ context: WKWebExtensionContext, _ wanted: WebKitExtensions.Wanted) {
    let webExtension = context.webExtension
    let forever = Date.distantFuture
    context.grantedPermissions = Dictionary(uniqueKeysWithValues: webExtension.requestedPermissions.map { ($0, forever) })
    let patterns = wanted.allSites ? webExtension.allRequestedMatchPatterns : Set(wanted.sites.compactMap(Self.pattern))
    context.grantedPermissionMatchPatterns = Dictionary(uniqueKeysWithValues: patterns.map { ($0, forever) })
    context.hasAccessToPrivateData = wanted.incognito
    if wanted.allSites { allSites.insert(wanted.id) } else { allSites.remove(wanted.id) }
  }

  func sync(_ wanted: [WebKitExtensions.Wanted], done: @escaping ([String], [String]) -> Void) {
    let ids = Set(wanted.map(\.id))
    for id in loaded.keys where !ids.contains(id) { unload(id) }
    Task { @MainActor in
      var ready: [String] = []
      var failed: [String] = []
      for want in wanted {
        if let current = loaded[want.id], current.folder == want.folder {
          grant(current.context, want)
          ready.append(want.id)
          continue
        }
        if loaded[want.id] != nil { unload(want.id) }
        do {
          let webExtension = try await WKWebExtension(resourceBaseURL: want.folder)
          let context = WKWebExtensionContext(for: webExtension)
          context.uniqueIdentifier = want.id
          if let base = URL(string: "webkit-extension://\(want.id)/") { context.baseURL = base }
          context.isInspectable = WebKitHub.inspectable
          context.inspectionName = want.name
          grant(context, want)
          try controller.load(context)
          loaded[want.id] = Loaded(context: context, folder: want.folder)
          ready.append(want.id)
          for tab in openTabs() { context.didOpenTab(tab) }
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
    try? controller.unload(entry.context)
  }

  func unloadAll() { loaded.keys.forEach(unload) }

  private func openTabs() -> [WebKitTab] {
    WebKitHub.shared.transfers.liveTabs.filter { $0.profile == profile && $0.webView != nil && !$0.closed }
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
    guard !loaded.isEmpty else { return }
    if let window = window(of: tab) { controller.didOpenWindow(window) }
    controller.didOpenTab(tab)
  }

  func tabClosed(_ tab: WebKitTab) {
    guard !loaded.isEmpty else { return }
    controller.didCloseTab(tab, windowIsClosing: false)
  }

  func tabShown(_ tab: WebKitTab) {
    guard !loaded.isEmpty, tab.visible, tab.webView != nil else { return }
    controller.didActivateTab(tab, previousActiveTab: nil)
    if let window = window(of: tab), window.window?.isKeyWindow == true { controller.didFocusWindow(window) }
  }

  func tabChanged(_ tab: WebKitTab) {
    guard !loaded.isEmpty else { return }
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
    guard let context = loaded[id]?.context else { return nil }
    context.userGesturePerformed(in: tab)
    context.performAction(for: tab)
    ArdiaEvents.emit("webKit.counted", data: ["name": "extensionAction"])
    return "none"
  }

  func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
    var seen = Set<ObjectIdentifier>()
    return openTabs().compactMap { tab in
      guard let window = window(of: tab), let shown = window.window, seen.insert(ObjectIdentifier(shown)).inserted else { return nil }
      return window
    }
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
    completionHandler(permissions.intersection(extensionContext.webExtension.requestedPermissions), nil)
  }

  func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?,
                              for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<URL>, Date?) -> Void) {
    completionHandler(allSites.contains(extensionContext.uniqueIdentifier) ? urls : [], nil)
  }

  func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                              in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                              completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
    completionHandler(allSites.contains(extensionContext.uniqueIdentifier) ? matchPatterns : [], nil)
  }

  func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
                              forExtensionContext context: WKWebExtensionContext) {
    ArdiaEvents.emit("extensions.action", data: ["profile": profile, "id": context.uniqueIdentifier, "kind": "action"])
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
