import AppKit
import WebKit

final class WebKitExtensions {
  struct Wanted {
    let id: String
    let source: URL
    let name: String
    let sites: [String]
    let allSites: Bool
    let incognito: Bool
    var folder: URL
    var signature: String
    var apis: Set<String> = []
    var nativeMessaging = false
    var grants = WebKitExtensionGrants.none
  }

  static let shared = WebKitExtensions()

  private var hubs: [String: AnyObject] = [:]
  private var wantedByProfile: [String: [Wanted]] = [:]
  private var asked: Set<String> = []

  func attach(_ configuration: WKWebViewConfiguration, profile: String) {
    guard #available(macOS 15.4, *) else { return }
    configuration.webExtensionController = hub(for: profile).controller
  }

  private static func key(_ profile: String) -> String {
    WebKitStores.isPrivate(profile) ? WebKitHub.shared.stores.id(of: profile).wireKey : profile
  }

  @available(macOS 15.4, *)
  private func allHubs() -> [WebKitExtensionHub] { hubs.values.compactMap { $0 as? WebKitExtensionHub } }

  @available(macOS 15.4, *)
  private func pruneEndedSessions() {
    for (key, hub) in hubs {
      guard let hub = hub as? WebKitExtensionHub, hub.isPrivate, !WebKitHub.shared.stores.isLive(hub.store) else { continue }
      hub.unloadAll()
      hubs.removeValue(forKey: key)
    }
  }

  @available(macOS 15.4, *)
  private func hub(for profile: String) -> WebKitExtensionHub {
    pruneEndedSessions()
    let key = Self.key(profile)
    if let hub = hubs[key] as? WebKitExtensionHub { return hub }
    let hub = WebKitExtensionHub(profile: profile, store: WebKitHub.shared.stores.id(of: profile))
    hubs[key] = hub
    if hub.isPrivate { fillPrivate(hub) }
    return hub
  }

  @available(macOS 15.4, *)
  private func fillPrivate(_ hub: WebKitExtensionHub) {
    let base = ArdiaHost.baseProfile(of: hub.profile)
    guard let wanted = wantedByProfile[base] else {
      if asked.insert(base).inserted { ArdiaEvents.emit("webKit.extensionsWanted", data: ["profile": base]) }
      return
    }
    hub.sync(wanted.filter(\.incognito)) { _, _ in }
  }

  @available(macOS 15.4, *)
  private func liveHub(_ profile: String) -> WebKitExtensionHub? { hubs[Self.key(profile)] as? WebKitExtensionHub }

  static func wanted(_ entries: [[String: Any]], profile: String) -> [Wanted] {
    entries.compactMap { entry in
      guard let id = entry["id"] as? String, !id.isEmpty, id.allSatisfy({ $0.isLetter && $0.isASCII }) else { return nil }
      let path = (entry["path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        ?? (entry["version"] as? String).flatMap { ArdiaServices.storeExtensionFolder(profile: profile, extension: id, version: $0) }
      guard let path, FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("manifest.json")) else { return nil }
      let source = URL(fileURLWithPath: path, isDirectory: true)
      return Wanted(
        id: id, source: source, name: entry["name"] as? String ?? id, sites: entry["sites"] as? [String] ?? [],
        allSites: entry["allSites"] as? Bool ?? false, incognito: entry["incognito"] as? Bool ?? false, folder: source, signature: source.path)
    }
  }

  static func staged(_ wanted: [Wanted], profile: String) -> [Wanted] {
    let grants = WebKitExtensionGrants.read(profile: profile)
    let result = wanted.map { want -> Wanted in
      var want = want
      want.grants = grants[want.id] ?? .none
      let staged = WebKitExtensionStaging.stage(id: want.id, source: want.source, profile: profile, grants: want.grants)
      want.folder = staged.folder
      want.signature = staged.signature
      want.apis = staged.apis
      want.nativeMessaging = staged.nativeMessaging
      return want
    }
    WebKitExtensionStaging.forgetAll(except: Set(result.filter { $0.folder != $0.source }.map(\.id)), profile: profile)
    return result
  }

  func sync(profile: String, entries: [[String: Any]], done: @escaping ([String: Any]) -> Void) {
    guard #available(macOS 15.4, *), !WebKitStores.isPrivate(profile) else {
      return done(["available": false, "loaded": [String](), "failed": [String]()])
    }
    let wanted = Self.wanted(entries, profile: profile)
    let missing = Set(entries.compactMap { $0["id"] as? String }).subtracting(wanted.map(\.id))
    DispatchQueue.global(qos: .userInitiated).async {
      let staged = Self.staged(wanted, profile: profile)
      DispatchQueue.main.async {
        self.wantedByProfile[profile] = staged
        self.asked.remove(profile)
        self.pruneEndedSessions()
        for hub in self.allHubs() where hub.isPrivate && ArdiaHost.baseProfile(of: hub.profile) == profile {
          hub.sync(staged.filter(\.incognito)) { _, _ in }
        }
        self.hub(for: profile).sync(staged) { loaded, failed in
          done(["available": true, "loaded": loaded, "failed": failed + missing.sorted()])
        }
      }
    }
  }

  func actionStates(tabId: String, ids: [String]) -> [String: Any]? {
    guard let tab = WebKitHub.shared.transfers.liveTab(tabId), tab.webView != nil else { return nil }
    guard #available(macOS 15.4, *), let hub = liveHub(tab.profile) else { return [:] }
    return hub.actionStates(ids, tab: tab)
  }

  func sidePanelURL(tabId: String, extensionId: String) -> String?? {
    guard let tab = WebKitHub.shared.transfers.liveTab(tabId), tab.webView != nil else { return nil }
    guard #available(macOS 15.4, *), let hub = liveHub(tab.profile) else { return .some(nil) }
    return .some(hub.sidePanelURL(extensionId, tab: tab))
  }

  func pageConfiguration(for address: String?, profile: String) -> WKWebViewConfiguration? {
    guard #available(macOS 15.4, *), let address, address.hasPrefix("webkit-extension:"), let url = URL(string: address) else { return nil }
    return liveHub(profile)?.pageConfiguration(for: url)
  }

  func performAction(_ id: String, tab: WebKitTab) -> String? {
    guard #available(macOS 15.4, *), let hub = liveHub(tab.profile) else { return nil }
    return hub.performAction(id, tab: tab)
  }

  func reply(_ id: String, payload: [String: Any]) {
    guard #available(macOS 15.4, *) else { return }
    WebKitExtensionBridge.answer(id, payload)
  }

  func event(profile: String, payload: [String: Any]) {
    guard #available(macOS 15.4, *), let api = payload["api"] as? String, let name = payload["event"] as? String else { return }
    let args = payload["args"] as? [Any] ?? []
    for hub in allHubs() where hub.profile == profile { hub.bridge.event(api: api, name: name, args: args) }
  }

  func tabOpened(_ tab: WebKitTab) {
    guard #available(macOS 15.4, *) else { return }
    liveHub(tab.profile)?.tabOpened(tab)
  }

  func tabClosed(_ tab: WebKitTab) {
    guard #available(macOS 15.4, *), let hub = liveHub(tab.profile) else { return }
    hub.tabClosed(tab)
    guard hub.isPrivate else { return }
    DispatchQueue.main.async { [weak self, weak hub] in
      guard let self, let hub, !hub.hasTabs, let key = self.hubs.first(where: { $0.value === hub })?.key else { return }
      hub.unloadAll()
      self.hubs.removeValue(forKey: key)
    }
  }

  func tabShown(_ tab: WebKitTab) {
    guard #available(macOS 15.4, *) else { return }
    liveHub(tab.profile)?.tabShown(tab)
  }

  func tabChanged(_ tab: WebKitTab) {
    guard #available(macOS 15.4, *) else { return }
    liveHub(tab.profile)?.tabChanged(tab)
  }

  func forgetProfile(_ profile: String) {
    wantedByProfile.removeValue(forKey: profile)
    guard #available(macOS 15.4, *), let hub = liveHub(profile) else { return }
    hub.unloadAll()
    hubs.removeValue(forKey: profile)
  }
}
