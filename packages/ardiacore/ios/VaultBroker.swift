import Foundation

enum VaultRefreshReason {
  @TaskLocal static var current: GoogleWebTrigger = .use
}

actor VaultBroker {
  static let shared = VaultBroker()
  static let syncingDelay: UInt64 = 150_000_000

  let sessions = VaultSessionStore.shared
  private var lanes: [String: VaultLane] = [:]
  var states: [String: VaultProviderState] = [:]
  var cachedItems: [String: [VaultItem]] = [:]
  var listedItems: [String: [VaultItem]] = [:]
  var pendingSaves: [String: [VaultPendingSave]] = [:]
  var syncWork: [String: Set<UUID>] = [:]
  var syncShown: Set<String> = []
  private var epochs: [String: Int] = [:]
  var quiet = false
  var fetchedAt: [String: Date] = [:]
  var loading: [String: Task<[VaultItem], Error>] = [:]
  private var versions: [String: String] = [:]
  private var refreshing: Task<Void, Never>?
  private var ownerNeededForPasswords = true
  var loadPasswordsWhenUsed = false
  var syncSchedule = VaultSyncSchedule.automatic
  var cachedPasswords: [String: [String: VaultCacheSnapshot.Password]] = [:]

  func providerStates() -> [VaultProviderState] {
    if refreshing == nil {
      refreshing = Task { await self.refreshAll() }
    }
    return VaultRegistry.providers.map { states[$0.id] ?? placeholder($0) }
  }

  func refresh(_ id: String, explicit: Bool = false) async -> VaultProviderState? {
    guard let provider = VaultRegistry.provider(id) else { return nil }
    if explicit {
      sessions.clearScratch(id)
      if id == GooglePasswordManagerVault.providerId, GooglePasswordManagerVault.usesWeb {
        await GoogleWebImporter.shared.personConfirmed()
        if sessions.session(id) != nil {
          await VaultRefreshReason.$current.withValue(.person) { _ = await fetchItems(provider) }
        }
        return await currentState(provider)
      }
      dropItems(id, announce: false)
    }
    return await currentState(provider)
  }

  func items(_ id: String?) async -> [VaultItem] {
    let providers = VaultRegistry.providers.filter { id == nil || $0.id == id }
    let lists = await withTaskGroup(of: (String, [VaultItem]).self, returning: [String: [VaultItem]].self) { group in
      for provider in providers {
        group.addTask {
          let list = await self.items(of: provider)
          return (provider.id, list)
        }
      }
      var collected: [String: [VaultItem]] = [:]
      for await (providerId, list) in group { collected[providerId] = list }
      return collected
    }
    return providers.flatMap { lists[$0.id] ?? [] }
  }

  func lock(_ id: String) async -> VaultProviderState? {
    guard let provider = VaultRegistry.provider(id) else { return nil }
    if sessions.session(id) != nil, let cli = VaultCLI.make(for: provider, sessions: sessions) {
      await lane(id).run { await provider.lock(cli) }
    }
    sessions.forget(id, keepStored: sessions.touchID)
    dropItems(id, announce: true, forgetPending: true)
    return await currentState(provider)
  }

  func lockAll() async {
    for id in sessions.unlockedProviders { _ = await lock(id) }
  }

  func lockIdle() async {
    for id in sessions.idleProviders() { _ = await lock(id) }
  }

  func syncDue() async {
    guard !quiet else { return }
    let now = Date()
    let due = VaultRegistry.providers.filter { provider in
      syncSchedule.refreshes(
        .timer, fetchedAt: fetchedAt[provider.id], now: now,
        unlocked: sessions.session(provider.id) != nil && states[provider.id]?.state == .unlocked,
        inFlight: loading[provider.id] != nil)
    }
    await withTaskGroup(of: Void.self) { group in
      for provider in due {
        group.addTask { await VaultRefreshReason.$current.withValue(.schedule) { _ = await self.fetchItems(provider, byPerson: false) } }
      }
    }
  }

  func signOut(_ id: String) async -> VaultProviderState? {
    guard let provider = VaultRegistry.provider(id) else { return nil }
    sessions.cancelRunning(id)
    if let cli = VaultCLI.make(for: provider, sessions: sessions) {
      await lane(id).run { await provider.signOut(cli) }
    }
    sessions.signedOut(id)
    dropItems(id, announce: true, forgetPending: true)
    VaultCache.delete(id)
    return await currentState(provider)
  }

  func configure(_ id: String, server: String?) async -> VaultProviderState? {
    guard let provider = VaultRegistry.provider(id) else { return nil }
    guard let cli = VaultCLI.make(for: provider, sessions: sessions) else { return await currentState(provider) }
    let problem = await lane(id).run { await provider.configure(cli, server: server) }
    if problem == nil { dropItems(id, announce: true, forgetPending: true) }
    var state = await currentState(provider)
    if let problem { state.message = problem }
    return state
  }

  func signIn(_ id: String, fields: VaultSignInFields) async -> VaultSignInResult? {
    guard let provider = VaultRegistry.provider(id) else { return nil }
    guard let cli = VaultCLI.make(for: provider, sessions: sessions) else { return await missingTool(provider) }
    let result = await lane(id).run { await provider.signIn(cli, fields: fields) }
    return await settle(provider, result)
  }

  func unlock(_ id: String, password: String?) async -> VaultSignInResult? {
    guard let provider = VaultRegistry.provider(id) else { return nil }
    guard let cli = VaultCLI.make(for: provider, sessions: sessions) else { return await missingTool(provider) }
    let result = await lane(id).run { await provider.unlock(cli, password: password) }
    return await settle(provider, result)
  }

  func cancelSignIn(_ id: String) async -> VaultProviderState? {
    guard let provider = VaultRegistry.provider(id) else { return nil }
    sessions.cancelRunning(id)
    return await currentState(provider)
  }

  func copy(_ id: String, item: String, field: VaultField) async -> Bool? {
    guard let provider = VaultRegistry.provider(id) else { return false }
    if field == .password, !(await ownerAllows("copy your password")) { return nil }
    let outcome = await secret(provider, item: item, field: field)
    guard case .success(let value) = outcome else { return false }
    return await VaultClipboard.copy(value)
  }

  func totp(_ id: String, item: String) async -> VaultTotp? {
    guard let provider = VaultRegistry.provider(id) else { return nil }
    let outcome = await secret(provider, item: item, field: .totp)
    guard case .success(let code) = outcome else { return nil }
    let period = cachedItems[id]?.first(where: { $0.id == item })?.totpPeriod ?? VaultTotp.defaultPeriod
    return VaultTotp.make(code: code, period: period)
  }

  private func ownerAllows(_ reason: String) async -> Bool {
    guard ownerNeededForPasswords else { return true }
    return await VaultOwnerCheck.confirm(reason)
  }

  func setOptions(idleLockMinutes: Int, touchID: Bool, askBeforeFilling: Bool, loadPasswordsWhenUsed whenUsed: Bool, syncIntervalSeconds: Double?) {
    syncSchedule = VaultSyncSchedule(seconds: syncIntervalSeconds)
    ownerNeededForPasswords = askBeforeFilling
    loadPasswordsWhenUsed = whenUsed
    if whenUsed {
      cachedPasswords = [:]
      for provider in VaultRegistry.providers {
        if cachedItems[provider.id] != nil { persist(provider.id) } else { VaultCache.stripPasswords(provider.id) }
      }
    }
    sessions.setOptions(idleLockMinutes: idleLockMinutes, touchID: touchID)
    guard !touchID else { return }
    for provider in VaultRegistry.providers { sessions.dropStored(provider.id) }
  }

  func fillValues(provider providerId: String, id itemId: String, fields: [String], origin: String, userChose: Bool) async
    -> Result<[String: String], VaultFillError>
  {
    guard let provider = VaultRegistry.provider(providerId) else { return .failure(.notFound) }
    guard VaultOriginMatch.isSecure(origin) else { return .failure(.insecure) }
    guard sessions.session(provider.id) != nil else { return .failure(.locked) }
    guard let item = await freshItem(provider, itemId) else {
      return .failure(sessions.session(provider.id) == nil ? .locked : .notFound)
    }
    guard userChose || VaultOriginMatch.matches(item.urls, origin: origin) else { return .failure(.originMismatch) }
    var wanted: [VaultField] = []
    for name in fields {
      let field: VaultField? = name == "otp" ? .totp : VaultField(rawValue: name)
      if let field, !wanted.contains(field) { wanted.append(field) }
    }
    if wanted.contains(.password), !(await ownerAllows("fill your password")) { return .failure(.notAuthorized) }
    var values: [String: String] = [:]
    for field in wanted {
      if field == .username && !item.username.isEmpty {
        values["username"] = item.username
        continue
      }
      let outcome = await secret(provider, item: item.id, field: field)
      switch outcome {
      case .success(let value):
        values[field == .totp ? "otp" : field.rawValue] = value
      case .failure(let error):
        if error == .notFound && field != .password && wanted.count > 1 { continue }
        return .failure(error)
      }
    }
    return values.isEmpty ? .failure(.notFound) : .success(values)
  }

  func save(provider providerId: String, origin: String, username: String, password: String, title: String?) async
    -> Result<VaultItem, VaultFillError>
  {
    guard let provider = VaultRegistry.provider(providerId) else { return .failure(.notFound) }
    guard provider.capabilities.save, !password.isEmpty else { return .failure(.failed) }
    guard VaultOriginMatch.isSecure(origin) else { return .failure(.insecure) }
    guard sessions.session(provider.id) != nil, let cli = VaultCLI.make(for: provider, sessions: sessions) else { return .failure(.locked) }
    let named = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let host = VaultOriginMatch.host(of: origin) ?? origin
    let fallback = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    let login = VaultNewLogin(title: named.isEmpty ? fallback : named, username: username, password: password, url: origin)
    do {
      let item = try await lane(provider.id).run { try await provider.save(cli, login: login) }
      sessions.touch(provider.id)
      let shown = insertPending(provider.id, item: item, password: password)
      Task { _ = await self.fetchItems(provider, byPerson: false) }
      return .success(shown)
    } catch {
      await fail(provider, error)
      return .failure(Self.fillError(error))
    }
  }

  private func refreshAll() async {
    await withTaskGroup(of: Void.self) { group in
      for provider in VaultRegistry.providers {
        group.addTask { _ = await self.refresh(provider.id) }
      }
    }
    refreshing = nil
  }

  private func placeholder(_ provider: any VaultProvider) -> VaultProviderState {
    provider.locate() == nil ? provider.makeState(.notInstalled) : provider.makeState(.locked)
  }

  private func lane(_ id: String) -> VaultLane {
    if let lane = lanes[id] { return lane }
    let lane = VaultLane()
    lanes[id] = lane
    return lane
  }

  private func currentState(_ provider: any VaultProvider) async -> VaultProviderState {
    guard let cli = VaultCLI.make(for: provider, sessions: sessions) else {
      if sessions.session(provider.id) != nil { sessions.forget(provider.id, keepStored: true) }
      dropItems(provider.id, announce: true, forgetPending: true)
      stopSync(provider.id)
      return publish(provider.makeState(.notInstalled))
    }
    let installedVersion = await version(of: cli)
    var state = await lane(provider.id).run { await provider.state(cli) }
    state.cliPath = cli.path
    state.cliVersion = installedVersion
    reconcile(provider.id, with: state.state)
    if state.state != .unlocked && state.state != .unavailable {
      dropItems(provider.id, announce: true, forgetPending: true)
      stopSync(provider.id)
    }
    return publish(state)
  }

  private func reconcile(_ id: String, with state: VaultState) {
    guard sessions.session(id) != nil else { return }
    switch state {
    case .signedOut: sessions.signedOut(id)
    case .locked: sessions.forget(id, keepStored: false)
    default: break
    }
  }

  private func version(of cli: VaultCLI) async -> String? {
    guard let path = cli.path else { return nil }
    let key = (path as NSString).resolvingSymlinksInPath
    if let known = versions[key] { return known }
    guard let found = await cli.version() else { return nil }
    versions[key] = found
    return found
  }

  private func missingTool(_ provider: any VaultProvider) async -> VaultSignInResult {
    let state = await currentState(provider)
    return VaultSignInResult(ok: false, state: state, error: provider.notInstalledMessage)
  }

  private func settle(_ provider: any VaultProvider, _ outcome: VaultSignInResult) async -> VaultSignInResult {
    var result = outcome
    if result.ok {
      sessions.touch(provider.id)
      dropItems(provider.id, announce: false, forgetPending: true)
      if provider.id == GooglePasswordManagerVault.providerId, GooglePasswordManagerVault.usesWeb {
        restoreFromDisk(provider.id)
        Task { await VaultRefreshReason.$current.withValue(.unlock) { _ = await self.fetchItems(provider, byPerson: false) } }
      }
    }
    result.state = await currentState(provider)
    result.ok = result.ok && result.state.state == .unlocked
    return result
  }

  func cacheAccount(_ id: String) -> String {
    let state = states[id]
    return "\(state?.account ?? "")@\(state?.server ?? "")"
  }

  func persist(_ id: String) {
    guard let items = listedItems[id] else { return }
    let pending = (pendingSaves[id] ?? []).map { save in
      var kept = save
      if loadPasswordsWhenUsed { kept.password = nil }
      return kept
    }
    let snapshot = VaultCacheSnapshot(
      account: cacheAccount(id), savedAt: (fetchedAt[id] ?? Date()).timeIntervalSince1970,
      entries: items.map { VaultCacheSnapshot.Entry(item: $0, totpPeriod: $0.totpPeriod) },
      passwords: loadPasswordsWhenUsed ? [:] : cachedPasswords[id] ?? [:], pending: pending.isEmpty ? nil : pending)
    VaultCache.save(id, snapshot)
  }

  func restoreFromDisk(_ id: String) {
    guard listedItems[id] == nil, let snapshot = VaultCache.load(id, account: cacheAccount(id)) else { return }
    listedItems[id] = snapshot.items.filter { $0.pending != true }
    cachedPasswords[id] = loadPasswordsWhenUsed ? [:] : snapshot.passwords
    fetchedAt[id] = Date(timeIntervalSince1970: snapshot.savedAt)
    var pending = snapshot.pending ?? []
    for save in pendingSaves[id] ?? [] { pending = VaultPendingItems.adding(save, to: pending) }
    pendingSaves[id] = pending.isEmpty ? nil : pending
    remerge(id)
  }

  private func items(of provider: any VaultProvider) async -> [VaultItem] {
    let id = provider.id
    guard sessions.session(id) != nil else { return [] }
    restoreFromDisk(id)
    if listedItems[id] != nil, let cached = cachedItems[id] {
      if syncSchedule.refreshes(.use, fetchedAt: fetchedAt[id], now: Date(), unlocked: true, inFlight: loading[id] != nil) {
        Task { _ = await self.fetchItems(provider) }
      }
      return cached
    }
    return await fetchItems(provider)
  }

  func fetchItems(_ provider: any VaultProvider, byPerson: Bool = true) async -> [VaultItem] {
    let id = provider.id
    if let inFlight = loading[id] {
      _ = try? await inFlight.value
      return cachedItems[id] ?? []
    }
    guard let cli = VaultCLI.make(for: provider, sessions: sessions) else { return [] }
    let queue = lane(id)
    let epoch = epochs[id, default: 0]
    let listing = Task { try await queue.run { try await provider.itemsAndPasswords(cli) } }
    let task = Task { try await listing.value.items }
    loading[id] = task
    let token = beginSync(id)
    defer {
      loading[id] = nil
      endSync(id, token)
    }
    do {
      let fresh = try await listing.value
      guard sessions.session(id) != nil, epochs[id, default: 0] == epoch else { return [] }
      let previous = cachedItems[id]
      listedItems[id] = fresh.items
      fetchedAt[id] = Date()
      mergePasswords(id, fresh)
      remerge(id, passwords: fresh.passwords)
      persist(id)
      if byPerson { sessions.touch(id) }
      let merged = cachedItems[id] ?? []
      if previous != merged { announceItems(id) }
      if id == GooglePasswordManagerVault.providerId { _ = await currentState(provider) }
      return merged
    } catch {
      await fail(provider, error)
      if id == GooglePasswordManagerVault.providerId { _ = await currentState(provider) }
      return cachedItems[id] ?? []
    }
  }

  private func mergePasswords(_ id: String, _ fresh: VaultItemList) {
    guard !loadPasswordsWhenUsed else { return cachedPasswords[id] = [:] }
    let old = cachedPasswords[id] ?? [:]
    var kept: [String: VaultCacheSnapshot.Password] = [:]
    for item in fresh.items {
      if let password = fresh.passwords[item.id] {
        kept[item.id] = VaultCacheSnapshot.Password(value: password, itemUpdatedAt: item.updatedAt)
      } else if let cached = old[item.id], cached.itemUpdatedAt == item.updatedAt {
        kept[item.id] = cached
      }
    }
    cachedPasswords[id] = kept
  }

  private func freshItem(_ provider: any VaultProvider, _ itemId: String) async -> VaultItem? {
    if let found = await items(of: provider).first(where: { $0.id == itemId }) { return found }
    return await fetchItems(provider).first { $0.id == itemId }
  }

  private func secret(_ provider: any VaultProvider, item: String, field: VaultField) async -> Result<String, VaultFillError> {
    let id = provider.id
    guard sessions.session(id) != nil, let cli = VaultCLI.make(for: provider, sessions: sessions) else { return .failure(.locked) }
    let listed = cachedItems[id]?.first { $0.id == item }
    if field == .password, let password = pendingPassword(id, item: item) {
      sessions.touch(id)
      return .success(password)
    }
    if field == .password, !loadPasswordsWhenUsed, let listed, let hit = cachedPasswords[id]?[item], hit.itemUpdatedAt == listed.updatedAt {
      sessions.touch(id)
      return .success(hit.value)
    }
    let reachesGoogle = id == GooglePasswordManagerVault.providerId && GooglePasswordManagerVault.usesWeb
    let token = reachesGoogle ? beginSync(id) : nil
    defer { if let token { endSync(id, token) } }
    do {
      let value = try await lane(id).run { try await provider.secret(cli, id: item, field: field) }
      sessions.touch(id)
      if field == .password, !loadPasswordsWhenUsed, let listed, listed.pending != true {
        cachedPasswords[id, default: [:]][item] = VaultCacheSnapshot.Password(value: value, itemUpdatedAt: listed.updatedAt)
        persist(id)
      }
      return .success(value)
    } catch {
      await fail(provider, error)
      return .failure(Self.fillError(error))
    }
  }

  private func fail(_ provider: any VaultProvider, _ error: Error) async {
    guard let error = error as? VaultError else { return }
    switch error {
    case .locked:
      sessions.forget(provider.id, keepStored: sessions.touchID)
      dropItems(provider.id, announce: true, forgetPending: true)
      _ = await currentState(provider)
    case .signedOut:
      sessions.signedOut(provider.id)
      dropItems(provider.id, announce: true, forgetPending: true)
      VaultCache.delete(provider.id)
      _ = await currentState(provider)
    default:
      break
    }
  }

  private func dropItems(_ id: String, announce: Bool, forgetPending: Bool = false) {
    cachedPasswords[id] = nil
    listedItems[id] = nil
    let had = !(cachedItems.removeValue(forKey: id) ?? []).isEmpty
    fetchedAt[id] = nil
    if forgetPending {
      pendingSaves[id] = nil
      epochs[id, default: 0] += 1
    } else {
      remerge(id)
    }
    if announce && had { announceItems(id) }
  }

  func publish(_ fresh: VaultProviderState) -> VaultProviderState {
    var state = fresh
    state.touchUnlock = state.state == .locked && sessions.hasStoredSession(state.id)
    state.syncing = state.state == .unlocked && syncShown.contains(state.id)
    guard states[state.id] != state else { return state }
    states[state.id] = state
    let payload: [String: Any] = ["provider": state.jsonObject()]
    DispatchQueue.main.async { ArdiaEvents.emit("vaults.changed", data: payload) }
    return state
  }

  func googleListChanged() async {
    let id = GooglePasswordManagerVault.providerId
    guard let provider = VaultRegistry.provider(id), sessions.session(id) != nil else { return }
    _ = await fetchItems(provider, byPerson: false)
    _ = await currentState(provider)
  }

  func storeChanged(_ id: String) async {
    guard let provider = VaultRegistry.provider(id), sessions.session(id) != nil else { return }
    _ = await fetchItems(provider, byPerson: false)
  }

  func announceItems(_ id: String) {
    DispatchQueue.main.async { ArdiaEvents.emit("vaults.itemsChanged", data: ["provider": id]) }
  }

  private static func fillError(_ error: Error) -> VaultFillError {
    switch error as? VaultError {
    case .locked?, .signedOut?: return .locked
    case .notFound?: return .notFound
    default: return .failed
    }
  }
}
