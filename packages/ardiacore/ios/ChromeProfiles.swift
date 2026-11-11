import Foundation

struct ChromeProfile: Codable, Equatable, Sendable {
  var directory: String
  var name: String
  var email: String?
  var gaiaName: String?

  var signedIn: Bool { email != nil }
}

struct ChromeLocalState: Equatable, Sendable {
  var profiles: [ChromeProfile]
  var lastUsed: String?
}

enum ChromeProfiles {
  static func parse(_ data: Data) -> ChromeLocalState? {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let section = root["profile"] as? [String: Any]
    else { return nil }
    let cache = section["info_cache"] as? [String: Any] ?? [:]
    let order = (section["profiles_order"] as? [Any])?.compactMap { $0 as? String } ?? []
    let directories = order.filter { cache[$0] != nil } + cache.keys.filter { !order.contains($0) }.sorted(by: directoryOrder)
    let profiles = directories.compactMap { directory -> ChromeProfile? in
      guard isDirectoryName(directory), let info = cache[directory] as? [String: Any] else { return nil }
      let name = nonEmpty(info["name"]) ?? nonEmpty(info["gaia_name"]) ?? directory
      return ChromeProfile(directory: directory, name: name, email: nonEmpty(info["user_name"]), gaiaName: nonEmpty(info["gaia_name"]))
    }
    let lastUsed = nonEmpty(section["last_used"]).flatMap { isDirectoryName($0) ? $0 : nil }
    return ChromeLocalState(profiles: profiles, lastUsed: lastUsed)
  }

  static func choose(_ state: ChromeLocalState, preferred: String?) -> ChromeProfile? {
    let profiles = state.profiles
    if let preferred, let chosen = profiles.first(where: { $0.directory == preferred }) { return chosen }
    let lastUsed = profiles.first { $0.directory == state.lastUsed }
    if let lastUsed, lastUsed.signedIn { return lastUsed }
    return profiles.first(where: \.signedIn) ?? lastUsed ?? profiles.first
  }

  static func isDirectoryName(_ text: String) -> Bool {
    guard !text.isEmpty, text.count <= 64, !text.hasPrefix("."), !text.hasPrefix("-") else { return false }
    return text.unicodeScalars.allSatisfy { scalar in
      scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == " " || scalar == "_" || scalar == "-")
    }
  }

  private static func directoryOrder(_ first: String, _ second: String) -> Bool {
    if first == "Default" { return second != "Default" }
    if second == "Default" { return false }
    return first.localizedStandardCompare(second) == .orderedAscending
  }

  private static func nonEmpty(_ value: Any?) -> String? {
    guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
    return text
  }
}
