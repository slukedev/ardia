import AppKit
import Foundation

enum ChromeInstallation {
  static let bundleIdentifier = "com.google.Chrome"
  static let sandboxSecretAccount = "google-safe-storage"

  static var testAccount: String? {
    let config = LaunchConfig.shared
    guard config.background, VaultSandbox.directory != nil,
      let account = config.testValue("googleChromeAccount")?.trimmingCharacters(in: .whitespacesAndNewlines), account.contains("@")
    else { return nil }
    return account.lowercased()
  }

  static var usesFixture: Bool { VaultSandbox.directory != nil && testAccount == nil }

  static var fixtureRoot: URL? {
    guard usesFixture, let data = VaultSandbox.directory else { return nil }
    return URL(fileURLWithPath: data, isDirectory: true).appendingPathComponent("Password Managers/google/Chrome", isDirectory: true)
  }

  static var app: URL? {
    guard !usesFixture else { return nil }
    if let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) { return found }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return ["/Applications/Google Chrome.app", "\(home)/Applications/Google Chrome.app"]
      .first { FileManager.default.fileExists(atPath: $0) }
      .map { URL(fileURLWithPath: $0, isDirectory: true) }
  }

  static func userDataRoot() -> URL? {
    if let fixtureRoot {
      return FileManager.default.fileExists(atPath: fixtureRoot.appendingPathComponent("Local State").path) ? fixtureRoot : nil
    }
    guard app != nil else { return nil }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
  }

  static func localState(_ root: URL) -> ChromeLocalState? {
    guard let data = try? Data(contentsOf: root.appendingPathComponent("Local State")), var state = ChromeProfiles.parse(data) else { return nil }
    if let testAccount {
      state.profiles = state.profiles.filter { $0.email?.lowercased() == testAccount }
      if !state.profiles.contains(where: { $0.directory == state.lastUsed }) { state.lastUsed = nil }
    }
    return state
  }

  static func profiles(_ root: URL) -> [ChromeProfile] {
    guard let state = localState(root) else { return [] }
    return state.profiles.filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0.directory).path) }
  }
}
