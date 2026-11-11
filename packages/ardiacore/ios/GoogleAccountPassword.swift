import Foundation
import Security

enum GoogleAccountPassword {
  static let service = "dev.ardia.vaults.google-account"
  private static let reason = "save a password to Google"
  private static let fileLock = NSLock()

  private static var sandboxFile: URL? {
    VaultSandbox.directory.map {
      URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("Password Managers/google/account.json")
    }
  }

  static func email() -> String? {
    if let file = sandboxFile { return locked { load(file).keys.sorted().first } }
    var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var found: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let attributes = found as? [String: Any] else { return nil }
    return attributes[kSecAttrAccount as String] as? String
  }

  @discardableResult
  static func save(email: String, password: String) -> Bool {
    let account = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard account.contains("@"), !password.isEmpty, password.utf8.count <= 4096 else { return false }
    if let file = sandboxFile { return locked { store(file, [account: password]) } }
    forget()
    var add: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
      kSecValueData as String: Data(password.utf8), kSecAttrLabel as String: "Ardia: Google Account password",
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    if SecItemAdd(add as CFDictionary, nil) == errSecSuccess { return true }
    add.removeValue(forKey: kSecAttrAccessible as String)
    return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
  }

  static func read(ownerConfirmed: Bool = false) async -> Result<(email: String, password: String), GoogleImportError> {
    guard let email = email() else { return .failure(.noPassword) }
    if !ownerConfirmed {
      guard await VaultOwnerCheck.confirm(reason) else { return .failure(.notAllowed) }
    }
    if let file = sandboxFile {
      guard let password = locked({ load(file)[email] }) else { return .failure(.noPassword) }
      return .success((email, password))
    }
    var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: email]
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var found: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let data = found as? Data,
      let password = String(data: data, encoding: .utf8), !password.isEmpty
    else { return .failure(.noPassword) }
    return .success((email, password))
  }

  static func forget() {
    if let file = sandboxFile {
      _ = locked { store(file, [:]) }
      return
    }
    SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
  }

  private static func locked<T>(_ body: () -> T) -> T {
    fileLock.lock()
    defer { fileLock.unlock() }
    return body()
  }

  private static func load(_ file: URL) -> [String: String] {
    guard let data = try? Data(contentsOf: file) else { return [:] }
    return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
  }

  private static func store(_ file: URL, _ entries: [String: String]) -> Bool {
    do {
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try JSONEncoder().encode(entries).write(to: file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      return true
    } catch {
      return false
    }
  }
}
