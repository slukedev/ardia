import Foundation
import Security

enum ChromeSafeStorage {
  enum Outcome: Sendable {
    case key(Data, askedPerson: Bool)
    case denied
    case missing
    case failed(OSStatus)
  }

  private static let service = "Chrome Safe Storage"
  private static let account = "Chrome"

  static func readKey() -> Outcome {
    if ChromeInstallation.usesFixture {
      guard let secret = VaultKeychain.read(ChromeInstallation.sandboxSecretAccount),
        let key = ChromeCrypto.deriveKey(secret: Data(secret.utf8))
      else { return .missing }
      return .key(key, askedPerson: false)
    }
    let silent = copySecret(interactive: false)
    if let secret = silent.secret {
      return ChromeCrypto.deriveKey(secret: secret).map { .key($0, askedPerson: false) } ?? .missing
    }
    guard silent.status == errSecInteractionNotAllowed || silent.status == errSecAuthFailed else { return outcome(silent.status) }
    let asked = copySecret(interactive: true)
    guard let secret = asked.secret else { return outcome(asked.status) }
    return ChromeCrypto.deriveKey(secret: secret).map { .key($0, askedPerson: true) } ?? .missing
  }

  private static func outcome(_ status: OSStatus) -> Outcome {
    switch status {
    case errSecItemNotFound: return .missing
    case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed: return .denied
    default: return .failed(status)
    }
  }

  private static func copySecret(interactive: Bool) -> (secret: Data?, status: OSStatus) {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
      kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    if !interactive { query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess else { return (nil, status) }
    guard let data = item as? Data, !data.isEmpty else { return (nil, errSecItemNotFound) }
    return (data, status)
  }
}
