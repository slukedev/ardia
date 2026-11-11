import Foundation

struct GooglePasswordManagerVault: VaultProvider {
  static let providerId = "google"

  let id = Self.providerId
  let name = "Google Password Manager"
  let binaryName = ""
  let capabilities = VaultCapabilities(totp: false, save: true, selfHosted: false, masterPassword: false, touchID: true)
  let install = VaultInstall(command: "", url: "https://passwords.google.com/")
  let notInstalledMessage = "Sign in to Google in Ardia to use Google Password Manager."

  private static let profilePreference = "profile"
  private static let sourcePreference = "source"
  private static let unlockReason = "unlock Google Password Manager"
  private static let webSessionPrefix = "web:"
  private static let webSignInMessage = "Sign in to Google and add your Google password to read your passwords."
  private static let webLocation = "passwords.google.com"

  static var usesWeb: Bool { plan().source == .web }

  static var choice: GoogleSourceChoice {
    GoogleSourceChoice(preference: VaultSessionStore.shared.preference(providerId, sourcePreference))
  }

  static func plan() -> GoogleSourcePlan {
    GoogleSourceRules.plan(
      choice: choice, chrome: chromeReadiness().readiness, failure: ChromeFailures.current, webReady: GoogleAccountPassword.email() != nil)
  }

  static func setSource(_ choice: GoogleSourceChoice) {
    VaultSessionStore.shared.setPreference(providerId, sourcePreference, choice == .automatic ? nil : choice.rawValue)
    ChromeFailures.clear()
  }

  static func session(_ cli: VaultCLI) -> GoogleSession? { cli.session.flatMap(GoogleSession.init) }

  static func chromeReadiness() -> (readiness: ChromeReadiness, context: Context?) {
    guard let root = ChromeInstallation.userDataRoot() else { return (.notInstalled, nil) }
    guard let state = ChromeInstallation.localState(root) else {
      let exists = FileManager.default.fileExists(atPath: root.appendingPathComponent("Local State").path)
      return (exists && ChromeInstallation.testAccount == nil ? .unreadable : .noProfile, nil)
    }
    let profiles = ChromeInstallation.profiles(root)
    let preferred = VaultSessionStore.shared.preference(providerId, profilePreference)
    guard let profile = ChromeProfiles.choose(ChromeLocalState(profiles: profiles, lastUsed: state.lastUsed), preferred: preferred)
    else { return (.noProfile, nil) }
    let context = Context(root: root, profile: profile, folder: root.appendingPathComponent(profile.directory, isDirectory: true))
    let exists = { (store: ChromeStore) in FileManager.default.fileExists(atPath: context.file(store).path) }
    if profile.signedIn, exists(.account) { return (.account, context) }
    return exists(.device) ? (.deviceOnly, context) : (.noProfile, nil)
  }

  var setup: VaultSetup? {
    VaultSetup(kind: .chrome, appURL: ChromeInstallation.app?.absoluteString ?? "https://passwords.google.com/")
  }

  struct Context {
    var root: URL
    var profile: ChromeProfile
    var folder: URL

    func file(_ store: ChromeStore) -> URL { folder.appendingPathComponent(store.fileName) }
  }

  func locate() -> VaultLocation? { .dataFolder(ChromeInstallation.userDataRoot()?.path ?? Self.webLocation) }

  func state(_ cli: VaultCLI) async -> VaultProviderState {
    let plan = Self.plan()
    var state: VaultProviderState
    switch plan.source {
    case .web?:
      state = await webState(cli)
      state.fallback = plan.chromeProblem?.message
    case .chrome?:
      let context = Self.chromeReadiness().context
      let open = Self.session(cli)?.has(.chrome) == true
      state = makeState(open ? .unlocked : .locked, account: context?.profile.email, server: context?.profile.name)
    case nil:
      state = makeState(plan.chromeProblem == nil ? .signedOut : .locked, message: plan.chromeProblem?.message ?? Self.webSignInMessage)
    }
    state.source = plan.source?.rawValue
    state.sourceChoice = Self.choice.rawValue
    return state
  }

  @MainActor
  private func webState(_ cli: VaultCLI) -> VaultProviderState {
    let importer = GoogleWebImporter.shared
    var state = makeState(webPassword(cli) == nil ? .locked : .unlocked, account: GoogleAccountPassword.email())
    state.refreshedAt = importer.lastRefresh.map { $0.timeIntervalSince1970 * 1000 }
    state.syncAgainAt = importer.limits.personSyncAgainAt(now: Date()).map { $0.timeIntervalSince1970 * 1000 }
    if let held = importer.heldBy {
      state.hold = held.rawValue
      state.message = held.message
    } else if let failed = importer.failedWith {
      state.message = failed.message
    }
    return state
  }

  private func webPassword(_ cli: VaultCLI) -> String? { Self.session(cli)?.webPassword }

  static func webPassword(session: String) -> String? { GoogleSession(session)?.webPassword }

  func signIn(_ cli: VaultCLI, fields: VaultSignInFields) async -> VaultSignInResult {
    await unlock(cli, password: nil)
  }

  func unlock(_ cli: VaultCLI, password: String?) async -> VaultSignInResult {
    var plan = Self.plan()
    if plan.source == nil, plan.chromeProblem != nil {
      ChromeFailures.clear()
      plan = Self.plan()
    }
    if plan.source == .chrome {
      switch await unlockChrome(cli) {
      case .opened:
        return signedIn()
      case .refused(let message):
        return failed(message)
      case .broken(let failure):
        ChromeFailures.record(failure)
        plan = Self.plan()
        guard plan.source == .web else { return failed(failure.message) }
      }
    }
    guard plan.source == .web else { return failed(Self.webSignInMessage, state: .signedOut) }
    switch await GoogleAccountPassword.read() {
    case .success(let stored):
      cli.remember(session: Self.webSessionPrefix + stored.password, persistent: false)
      return signedIn()
    case .failure(.notAllowed):
      return failed("Google Password Manager stayed locked.")
    case .failure(let error):
      return failed(error.message)
    }
  }

  private enum ChromeUnlock {
    case opened
    case refused(String)
    case broken(ChromeFailure)
  }

  private func unlockChrome(_ cli: VaultCLI) async -> ChromeUnlock {
    guard let context = Self.chromeReadiness().context else { return .broken(.signedOut) }
    if cli.touchID, cli.hasStoredSession {
      guard let stored = await cli.storedSession(Self.unlockReason) else { return .refused("Google Password Manager stayed locked.") }
      let verdict = ChromeCrypto.key(hex: stored).map { verdict($0, context) } ?? .wrongKey
      switch verdict {
      case .fits:
        await rememberChrome(cli, keyHex: stored, persistent: false, ownerConfirmed: true)
        return .opened
      case .unknown(let message):
        return .refused(message)
      case .wrongKey:
        cli.dropStoredSession()
      }
    }
    switch ChromeSafeStorage.readKey() {
    case .key(let key, let askedPerson):
      switch verdict(key, context) {
      case .fits: break
      case .wrongKey: return .broken(.wrongKey)
      case .unknown(let message): return .refused(message)
      }
      if !askedPerson, !(await cli.confirmOwner(Self.unlockReason)) { return .refused("Google Password Manager stayed locked.") }
      await rememberChrome(cli, keyHex: ChromeCrypto.hex(key), persistent: ChromeInstallation.testAccount == nil, ownerConfirmed: !askedPerson)
      return .opened
    case .denied:
      return .broken(.keychainDenied)
    case .missing:
      return .broken(.keyMissing)
    case .failed:
      return .broken(.keychainFailed)
    }
  }

  private func rememberChrome(_ cli: VaultCLI, keyHex: String, persistent: Bool, ownerConfirmed: Bool) async {
    cli.remember(session: keyHex, persistent: persistent)
    guard ownerConfirmed, GoogleAccountPassword.email() != nil, case .success(let stored) = await GoogleAccountPassword.read(ownerConfirmed: true),
      let combined = GoogleSession(chromeKey: keyHex, webPassword: stored.password).text
    else { return }
    cli.remember(session: combined, persistent: false)
  }

  func lock(_ cli: VaultCLI) async {
    await GoogleWebImporter.shared.dropLatest()
  }

  func signOut(_ cli: VaultCLI) async {
    ChromeFailures.clear()
    GoogleAccountPassword.forget()
    await GoogleWebImporter.shared.forget()
  }

  func configure(_ cli: VaultCLI, server: String?) async -> String? {
    let wanted = server?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !wanted.isEmpty else {
      cli.setPreference(Self.profilePreference, nil)
      return nil
    }
    guard let root = cli.dataFolder.map({ URL(fileURLWithPath: $0, isDirectory: true) }), ChromeProfiles.isDirectoryName(wanted),
      let profile = ChromeInstallation.profiles(root).first(where: { $0.directory == wanted })
    else { return "Chrome has no profile called \(wanted)." }
    let folder = root.appendingPathComponent(profile.directory, isDirectory: true)
    guard Self.isUsable(Context(root: root, profile: profile, folder: folder)) else {
      return "\(profile.name) isn't signed in to Google in Chrome and has no passwords on this Mac."
    }
    cli.setPreference(Self.profilePreference, wanted)
    return nil
  }

  func items(_ cli: VaultCLI) async throws -> [VaultItem] { try await itemsAndPasswords(cli).items }

  func itemsAndPasswords(_ cli: VaultCLI) async throws -> VaultItemList {
    if Self.usesWeb { return try await webList(cli) }
    do {
      return try chromeList(cli)
    } catch let failure as ChromeFailure {
      ChromeFailures.record(failure)
      if Self.usesWeb, webPassword(cli) != nil { return try await webList(cli) }
      throw failure == .wrongKey ? VaultError.locked : VaultError.failed(failure.message)
    }
  }

  private func webList(_ cli: VaultCLI) async throws -> VaultItemList {
    GoogleExportCSV.list(try await webRows(cli, trigger: VaultRefreshReason.current), provider: id)
  }

  private func chromeList(_ cli: VaultCLI) throws -> VaultItemList {
    let (key, context) = try unlocked(cli)
    let rows: [ChromeLogin]
    do {
      rows = try logins(context)
    } catch VaultError.signedOut {
      throw ChromeFailure.signedOut
    }
    let list = ChromeLoginMapping.list(rows, key: key, provider: id)
    guard list.keyFits else { throw ChromeFailure.wrongKey }
    if Self.choice == .automatic, let failure = GoogleSourceRules.failure(
      afterReading: rows.filter { $0.store == .account }.count, signedIn: context.profile.signedIn, webReady: GoogleAccountPassword.email() != nil)
    {
      throw failure
    }
    return VaultItemList(items: list.items, passwords: list.passwords)
  }

  func secret(_ cli: VaultCLI, id itemId: String, field: VaultField) async throws -> String {
    if Self.usesWeb {
      guard field != .totp, GoogleExportCSV.isValidId(itemId) else { throw VaultError.notFound }
      var rows = await GoogleWebImporter.shared.latestRows
      if rows == nil { rows = try await webRows(cli, trigger: .personAnyway) }
      guard let row = rows?.first(where: { GoogleExportCSV.itemId(url: $0.url, username: $0.username) == itemId }) else { throw VaultError.notFound }
      let value = field == .username ? row.username : row.password
      guard !value.isEmpty else { throw VaultError.notFound }
      return value
    }
    let key: Data
    let context: Context
    do {
      (key, context) = try unlocked(cli)
    } catch let failure as ChromeFailure {
      throw VaultError.failed(failure.message)
    }
    guard field != .totp, ChromeLoginMapping.isValidId(itemId) else { throw VaultError.notFound }
    guard let login = ChromeLoginMapping.merged(try logins(context)).first(where: { $0.id == itemId }) else { throw VaultError.notFound }
    if field == .username {
      guard !login.username.isEmpty else { throw VaultError.notFound }
      return login.username
    }
    guard let password = ChromeCrypto.decrypt(login.encryptedPassword, key: key) else { throw VaultError.locked }
    guard !password.isEmpty else { throw VaultError.notFound }
    return password
  }

  func save(_ cli: VaultCLI, login: VaultNewLogin) async throws -> VaultItem { throw VaultError.unsupported }

  func savedItem(_ login: VaultNewLogin) -> VaultItem {
    if Self.usesWeb {
      return VaultItem(
        provider: id, id: GoogleExportCSV.itemId(url: login.url, username: login.username), title: login.title, username: login.username,
        urls: [login.url], hasTotp: false, vault: GoogleExportCSV.vaultName)
    }
    let placeholder = ChromeLogin(store: .account, originURL: login.url, username: login.username, signonRealm: login.url, encryptedPassword: Data())
    return VaultItem(
      provider: id, id: "imported" + placeholder.id.dropFirst(ChromeStore.account.rawValue.count), title: login.title, username: login.username,
      urls: [login.url], hasTotp: false, vault: ChromeStore.account.vaultName)
  }

  func watchForSync(_ cli: VaultCLI, login: VaultNewLogin) async {
    guard !Self.usesWeb, let context = Self.chromeReadiness().context else { return }
    let handoff = ChromeHandoff(
      id: UUID().uuidString.lowercased(), host: VaultOriginMatch.host(of: login.url) ?? login.title, url: login.url, username: login.username,
      passwordDigest: ChromeHandoffRules.digest(login.password), started: Date())
    await ChromeStoreWatcher.shared.watch(handoff, stores: ChromeStore.allCases.map(context.file))
  }

  static func profileList(_ sessions: VaultSessionStore) -> [[String: Any]] {
    guard let root = ChromeInstallation.userDataRoot() else { return [] }
    let profiles = ChromeInstallation.profiles(root)
    let chosen = ChromeInstallation.localState(root).flatMap { state in
      ChromeProfiles.choose(ChromeLocalState(profiles: profiles, lastUsed: state.lastUsed), preferred: sessions.preference(providerId, profilePreference))
    }
    return profiles.map { profile in
      var entry: [String: Any] = ["directory": profile.directory, "name": profile.name, "selected": profile.directory == chosen?.directory]
      entry["email"] = profile.email ?? NSNull()
      return entry
    }
  }

  private func webRows(_ cli: VaultCLI, trigger: GoogleWebTrigger) async throws -> [GoogleExportRow] {
    guard let password = webPassword(cli) else { throw VaultError.locked }
    let reply = await GoogleWebImporter.shared.export(trigger: trigger, password: password)
    switch reply {
    case .list(let rows):
      return rows
    case .failed(.wrongPassword), .failed(.noPassword):
      throw VaultError.failed(GoogleImportError.wrongPassword.message)
    default:
      if let latest = await GoogleWebImporter.shared.latestRows { return latest }
      switch reply {
      case .failed(let error), .confirm(_, let error), .refused(.held(let error)): throw VaultError.failed(error.message)
      case .refused(.busy): throw VaultError.failed("Ardia is already talking to Google. Try again in a moment.")
      default: throw VaultError.failed("Google Password Manager refreshes at most once an hour.")
      }
    }
  }

  private static func isUsable(_ context: Context) -> Bool {
    let stores: [ChromeStore] = context.profile.signedIn ? ChromeStore.allCases : [.device]
    return stores.contains { FileManager.default.fileExists(atPath: context.file($0).path) }
  }

  private func unlocked(_ cli: VaultCLI) throws -> (Data, Context) {
    guard let hex = Self.session(cli)?.chromeKey, let key = ChromeCrypto.key(hex: hex) else { throw VaultError.locked }
    guard let context = Self.chromeReadiness().context else { throw ChromeFailure.signedOut }
    return (key, context)
  }

  private func logins(_ context: Context) throws -> [ChromeLogin] {
    var logins: [ChromeLogin] = []
    var found = false
    for store in ChromeStore.allCases {
      do {
        logins += try ChromeLoginReader.read(context.file(store), store: store)
        found = true
      } catch .missing {
        continue
      } catch .busy {
        throw VaultError.failed("Chrome is busy with its passwords. Try again in a moment.")
      } catch .unreadable(let message) {
        throw VaultError.failed(message)
      }
    }
    guard found else { throw VaultError.signedOut }
    return logins
  }

  private func verdict(_ key: Data, _ context: Context) -> ChromeKeyVerdict {
    ChromeHandoffRules.verdict(Result { try logins(context) }, key: key)
  }
}

enum ChromeFailures {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var recorded: ChromeFailure?

  static var current: ChromeFailure? {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  static func record(_ failure: ChromeFailure) {
    lock.lock()
    recorded = failure
    lock.unlock()
  }

  static func clear() {
    lock.lock()
    recorded = nil
    lock.unlock()
  }
}
