import Foundation

struct WebKitExtensionSidePanel: Equatable {
  struct Options: Equatable {
    var path: String?
    var enabled: Bool?
  }

  var defaults: Options
  var tabs: [String: Options] = [:]
  var opensOnAction = false

  init(manifest: [String: Any]) {
    let path = (manifest["side_panel"] as? [String: Any])?["default_path"] as? String
    defaults = Options(path: path.flatMap { $0.isEmpty ? nil : $0 }, enabled: true)
  }

  func options(tab: String?) -> Options {
    let own = tab.flatMap { tabs[$0] }
    return Options(path: own?.path ?? defaults.path, enabled: own?.enabled ?? defaults.enabled ?? true)
  }

  func page(tab: String?) -> String? {
    let shown = options(tab: tab)
    guard shown.enabled != false, let path = shown.path else { return nil }
    return String(path.drop { $0 == "/" })
  }

  mutating func set(_ request: [String: Any], tab: String?) {
    var options = tab.flatMap { tabs[$0] } ?? (tab == nil ? defaults : Options())
    if let path = request["path"] as? String { options.path = path.isEmpty ? nil : path }
    if let enabled = request["enabled"] as? Bool { options.enabled = enabled }
    if let tab { tabs[tab] = options } else { defaults = options }
  }

  mutating func forgetTab(_ tab: String) { tabs.removeValue(forKey: tab) }
}
