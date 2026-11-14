import Foundation

struct WebKitExtensionGrants: Equatable {
  var apis: Set<String> = []
  var hosts: Set<String> = []

  static let none = WebKitExtensionGrants()

  static func read(profile: String) -> [String: WebKitExtensionGrants] {
    let directory = URL(fileURLWithPath: ArdiaServices.profileDirectory(profile), isDirectory: true)
    var grants: [String: WebKitExtensionGrants] = [:]
    for file in ["Secure Preferences", "Preferences"] {
      for (id, found) in parse(directory.appendingPathComponent(file)) { grants[id, default: .none].merge(found) }
    }
    return grants
  }

  static func parse(_ file: URL) -> [String: WebKitExtensionGrants] {
    guard let data = try? Data(contentsOf: file),
      let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let settings = (root["extensions"] as? [String: Any])?["settings"] as? [String: Any]
    else { return [:] }
    var grants: [String: WebKitExtensionGrants] = [:]
    for (id, value) in settings {
      guard let entry = value as? [String: Any] else { continue }
      var found = WebKitExtensionGrants()
      for key in ["granted_permissions", "runtime_granted_permissions"] {
        guard let set = entry[key] as? [String: Any] else { continue }
        found.apis.formUnion(names(set["api"]))
        found.apis.formUnion(names(set["manifest_permissions"]))
        found.hosts.formUnion(names(set["explicit_host"]))
        found.hosts.formUnion(names(set["scriptable_host"]))
      }
      if !found.apis.isEmpty || !found.hosts.isEmpty { grants[id] = found }
    }
    return grants
  }

  private static func names(_ value: Any?) -> [String] {
    (value as? [Any] ?? []).compactMap { item in
      if let name = item as? String { return name }
      return (item as? [String: Any])?.keys.first
    }
  }

  mutating func merge(_ other: WebKitExtensionGrants) {
    apis.formUnion(other.apis)
    hosts.formUnion(other.hosts)
  }
}
