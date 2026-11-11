struct VaultProviderState: Codable, Equatable, Sendable {
  var id: String
  var name: String
  var state: VaultState
  var account: String? = nil
  var server: String? = nil
  var cliPath: String? = nil
  var cliVersion: String? = nil
  var message: String? = nil
  var settingsURL: String? = nil
  var capabilities: VaultCapabilities
  var install: VaultInstall
  var setup: VaultSetup? = nil
  var touchUnlock = false
  var refreshedAt: Double? = nil
  var syncAgainAt: Double? = nil
  var hold: String? = nil
  var syncing = false

  func jsonObject() -> [String: Any] { VaultJSON.object(self) }
}
