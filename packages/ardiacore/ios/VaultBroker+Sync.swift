import Foundation

extension VaultBroker {
  func setQuiet(_ value: Bool) { quiet = value }

  func appBecameActive() async {
    guard !quiet else { return }
    let now = Date()
    let stale = VaultRegistry.providers.filter { provider in
      sessions.session(provider.id) != nil && states[provider.id]?.state == .unlocked
        && syncSchedule.refreshes(.use, fetchedAt: fetchedAt[provider.id], now: now, unlocked: true, inFlight: loading[provider.id] != nil)
    }
    await withTaskGroup(of: Void.self) { group in
      for provider in stale {
        group.addTask { _ = await self.fetchItems(provider, byPerson: false) }
      }
    }
  }

  func beginSync(_ id: String) -> UUID {
    let token = UUID()
    syncWork[id, default: []].insert(token)
    Task {
      try? await Task.sleep(nanoseconds: Self.syncingDelay)
      self.showSyncing(id, token)
    }
    return token
  }

  func showSyncing(_ id: String, _ token: UUID) {
    guard syncWork[id]?.contains(token) == true, !syncShown.contains(id) else { return }
    syncShown.insert(id)
    republish(id)
  }

  func endSync(_ id: String, _ token: UUID) {
    syncWork[id]?.remove(token)
    guard syncWork[id]?.isEmpty ?? true else { return }
    syncWork[id] = nil
    if syncShown.remove(id) != nil { republish(id) }
  }

  func stopSync(_ id: String) {
    syncWork[id] = nil
    if syncShown.remove(id) != nil { republish(id) }
  }

  func republish(_ id: String) {
    guard let state = states[id] else { return }
    _ = publish(state)
  }
}
