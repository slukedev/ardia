import Foundation

extension VaultBroker {
  func setGoogleSource(_ choice: GoogleSourceChoice) async -> VaultProviderState? {
    let id = GooglePasswordManagerVault.providerId
    GooglePasswordManagerVault.setSource(choice)
    _ = await refresh(id)
    guard let text = sessions.session(id), let session = GoogleSession(text), let source = GooglePasswordManagerVault.plan().source,
      session.has(source)
    else { return await lock(id) }
    await storeChanged(id)
    return await refresh(id)
  }
}
