import Foundation

extension VaultBroker {
  func saveToGoogle(origin: String, username: String, password: String, title: String?) async -> [String: Any] {
    let provider = GooglePasswordManagerVault()
    guard !password.isEmpty else { return ["saved": false, "error": VaultFillError.failed.rawValue] }
    guard VaultOriginMatch.isSecure(origin) else { return ["saved": false, "error": VaultFillError.insecure.rawValue] }
    guard let session = sessions.session(provider.id), let cli = VaultCLI.make(for: provider, sessions: sessions) else {
      return ["saved": false, "error": VaultFillError.locked.rawValue]
    }
    let named = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let host = VaultOriginMatch.host(of: origin) ?? origin
    let login = VaultNewLogin(title: named.isEmpty ? (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host) : named, username: username, password: password, url: origin)
    sessions.touch(provider.id)
    let chrome = GooglePasswordManagerVault.plan().source == .chrome
    let accountPassword = GooglePasswordManagerVault.webPassword(session: session)
    let importId = await GoogleWebImporter.shared.enqueue(
      url: login.url, username: login.username, password: login.password, title: login.title, accountPassword: accountPassword)
    let item = insertPending(provider.id, item: provider.savedItem(login), password: login.password)
    let token = beginSync(provider.id)
    Task { await self.followImport(importId, itemId: item.id, token: token, watching: chrome ? (provider, cli, login) : nil) }
    return ["saved": true, "item": item.jsonObject(), "importId": importId]
  }

  func followImport(_ importId: String, itemId: String, token: UUID, watching: (GooglePasswordManagerVault, VaultCLI, VaultNewLogin)? = nil) async {
    let id = GooglePasswordManagerVault.providerId
    let reply = await GoogleWebImporter.shared.finalReply(importId)
    endSync(id, token)
    if case .saved = reply {
      if let (provider, cli, login) = watching { await provider.watchForSync(cli, login: login) }
      return
    }
    discardPending(id, itemId: itemId)
  }

  func reconcileGoogle() async -> TimeInterval? {
    let id = GooglePasswordManagerVault.providerId
    guard !quiet, let provider = VaultRegistry.provider(id), sessions.session(id) != nil, pendingSaves[id]?.isEmpty == false else { return nil }
    _ = await VaultRefreshReason.$current.withValue(.afterSave) { await fetchItems(provider, byPerson: false) }
    guard sessions.session(id) != nil, pendingSaves[id]?.isEmpty == false else { return nil }
    return GoogleWebLimits.afterSaveSpacing + 5
  }

  func insertPending(_ id: String, item: VaultItem, password: String) -> VaultItem {
    restoreFromDisk(id)
    let save = VaultPendingSave(item: item, password: password, since: Date().timeIntervalSince1970)
    pendingSaves[id] = VaultPendingItems.adding(save, to: pendingSaves[id] ?? [])
    remerge(id)
    persist(id)
    announceItems(id)
    var shown = item
    shown.pending = pendingSaves[id]?.contains { $0.item.id == item.id } == true ? true : nil
    return shown
  }

  func discardPending(_ id: String, itemId: String) {
    if pendingSaves[id]?.contains(where: { $0.item.id == itemId }) == true {
      pendingSaves[id] = VaultPendingItems.removing(itemId, from: pendingSaves[id] ?? [])
      remerge(id)
      persist(id)
      announceItems(id)
      return
    }
    guard sessions.session(id) == nil, var snapshot = VaultCache.load(id, account: cacheAccount(id)),
      snapshot.pending?.contains(where: { $0.item.id == itemId }) == true
    else { return }
    snapshot.pending = VaultPendingItems.removing(itemId, from: snapshot.pending ?? [])
    VaultCache.save(id, snapshot)
  }

  func knownPasswords(_ id: String) -> [String: String] {
    (cachedPasswords[id] ?? [:]).mapValues(\.value)
  }

  func remerge(_ id: String, passwords extra: [String: String] = [:]) {
    let result = VaultPendingItems.reconcile(
      listedItems[id] ?? [], passwords: extra.merging(knownPasswords(id)) { fresh, _ in fresh }, pending: pendingSaves[id] ?? [], now: Date())
    pendingSaves[id] = result.pending.isEmpty ? nil : result.pending
    if listedItems[id] != nil || !result.items.isEmpty { cachedItems[id] = result.items } else { cachedItems[id] = nil }
    guard !loadPasswordsWhenUsed else { return }
    for (itemId, password) in result.carried {
      let updated = result.items.first { $0.id == itemId }?.updatedAt
      cachedPasswords[id, default: [:]][itemId] = VaultCacheSnapshot.Password(value: password, itemUpdatedAt: updated)
    }
  }

  func pendingPassword(_ id: String, item: String) -> String? {
    pendingSaves[id]?.first { $0.item.id == item }?.password
  }
}
