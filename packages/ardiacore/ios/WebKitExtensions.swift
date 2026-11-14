import AppKit
import WebKit

final class WebKitExtensions {
  struct Wanted {
    let id: String
    let folder: URL
    let name: String
    let sites: [String]
    let allSites: Bool
    let incognito: Bool
  }

  static let shared = WebKitExtensions()

  private var hubs: [String: AnyObject] = [:]

  func attach(_ configuration: WKWebViewConfiguration, profile: String) {
    guard #available(macOS 15.4, *), !WebKitStores.isPrivate(profile) else { return }
    configuration.webExtensionController = hub(for: profile).controller
  }

  @available(macOS 15.4, *)
  private func hub(for profile: String) -> WebKitExtensionHub {
    if let hub = hubs[profile] as? WebKitExtensionHub { return hub }
    let hub = WebKitExtensionHub(profile: profile)
    hubs[profile] = hub
    return hub
  }

  @available(macOS 15.4, *)
  private func liveHub(_ profile: String) -> WebKitExtensionHub? { hubs[profile] as? WebKitExtensionHub }

  static func wanted(_ entries: [[String: Any]], profile: String) -> [Wanted] {
    entries.compactMap { entry in
      guard let id = entry["id"] as? String, !id.isEmpty, id.allSatisfy({ $0.isLetter && $0.isASCII }) else { return nil }
      let path = (entry["path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        ?? (entry["version"] as? String).flatMap { ArdiaServices.storeExtensionFolder(profile: profile, extension: id, version: $0) }
      guard let path, FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("manifest.json")) else { return nil }
      return Wanted(
        id: id, folder: URL(fileURLWithPath: path, isDirectory: true), name: entry["name"] as? String ?? id,
        sites: entry["sites"] as? [String] ?? [], allSites: entry["allSites"] as? Bool ?? false, incognito: entry["incognito"] as? Bool ?? false)
    }
  }

  func sync(profile: String, entries: [[String: Any]], done: @escaping ([String: Any]) -> Void) {
    guard #available(macOS 15.4, *), !WebKitStores.isPrivate(profile) else {
      return done(["available": false, "loaded": [String](), "failed": [String]()])
    }
    let wanted = Self.wanted(entries, profile: profile)
    let missing = Set(entries.compactMap { $0["id"] as? String }).subtracting(wanted.map(\.id))
    hub(for: profile).sync(wanted) { loaded, failed in
      done(["available": true, "loaded": loaded, "failed": failed + missing.sorted()])
    }
  }

  func actionStates(tabId: String, ids: [String]) -> [String: Any]? {
    guard let tab = WebKitHub.shared.transfers.liveTab(tabId), tab.webView != nil else { return nil }
    guard #available(macOS 15.4, *), let hub = liveHub(tab.profile) else { return [:] }
    return hub.actionStates(ids, tab: tab)
  }

  func performAction(_ id: String, tab: WebKitTab) -> String? {
    guard #available(macOS 15.4, *), let hub = liveHub(tab.profile) else { return nil }
    return hub.performAction(id, tab: tab)
  }

  func tabOpened(_ tab: WebKitTab) {
    guard #available(macOS 15.4, *) else { return }
    liveHub(tab.profile)?.tabOpened(tab)
  }

  func tabClosed(_ tab: WebKitTab) {
    guard #available(macOS 15.4, *) else { return }
    liveHub(tab.profile)?.tabClosed(tab)
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
    guard #available(macOS 15.4, *), let hub = liveHub(profile) else { return }
    hub.unloadAll()
    hubs.removeValue(forKey: profile)
  }
}
