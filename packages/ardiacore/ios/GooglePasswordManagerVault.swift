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
  private static let unlockReason = "unlock Google Password Manager"
  private static let webSessionPrefix = "web:"
  private static let webSignInMessage = "Sign in to Google and add your Google password to read your passwords."
  private static let webLocation = "passwords.google.com"

  static var usesWeb: Bool { GoogleAccountPassword.email() != nil }

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
    if Self.usesWeb { return await webState(cli) }
    guard let context = context(cli) else { return makeState(.signedOut, message: Self.webSignInMessage) }
    return makeState(cli.session == nil ? .locked : .unlocked, account: context.profile.email, server: context.profile.name)
  }

  @MainActor
  private func webState(_ cli: VaultCLI) -> VaultProviderState {
    let importer = GoogleWebImporter.shared
    var state = makeState(webPassword(cli) == nil ? .locked : .unlocked, account: GoogleAccountPassword.email())
    state.refreshedAt = importer.lastRefresh.map { $0.timeIntervalSince1970 * 1000 }
    if let held = importer.heldBy {
      state.hold = held.rawValue
      state.message = held.message
    }
    return state
  }

  private func webPassword(_ cli: VaultCLI) -> String? {
    cli.session.flatMap(Self.webPassword(session:))
  }

  static func webPassword(session: String) -> String? {
    guard session.hasPrefix(webSessionPrefix) else { return nil }
    let password = String(session.dropFirst(webSessionPrefix.count))
    return password.isEmpty ? nil : password
  }

  func signIn(_ cli: VaultCLI, fields: VaultSignInFields) async -> VaultSignInResult {
    await unlock(cli, password: nil)
  }

  func unlock(_ cli: VaultCLI, password: String?) async -> VaultSignInResult {
    if Self.usesWeb {
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
    guard let context = context(cli) else { return failed(Self.webSignInMessage, state: .signedOut) }
    if cli.touchID, cli.hasStoredSession {
      guard let stored = await cli.storedSession(Self.unlockReason) else { return failed("Google Password Manager stayed locked.") }
      let verdict = ChromeCrypto.key(hex: stored).map { verdict($0, context) } ?? .wrongKey
      switch verdict {
      case .fits:
        cli.remember(session: stored)
        return signedIn()
      case .unknown(let message):
        return failed(message)
      case .wrongKey:
        cli.dropStoredSession()
      }
    }
    switch ChromeSafeStorage.readKey() {
    case .key(let key, let askedPerson):
      switch verdict(key, context) {
      case .fits: break
      case .wrongKey: return failed("Chrome's passwords didn't open with its keychain key.")
      case .unknown(let message): return failed(message)
      }
      if !askedPerson, !(await cli.confirmOwner(Self.unlockReason)) { return failed("Google Password Manager stayed locked.") }
      cli.remember(session: ChromeCrypto.hex(key), persistent: ChromeInstallation.testAccount == nil)
      return signedIn()
    case .denied:
      return failed("Chrome's keychain access was denied.")
    case .missing:
      return failed("Chrome's key isn't in your keychain. Open Chrome once, then try again.")
    case .failed(let status):
      return failed("Ardia couldn't read Chrome's keychain key (error \(status)).")
    }
  }

  func lock(_ cli: VaultCLI) async {
    await GoogleWebImporter.shared.dropLatest()
  }

  func signOut(_ cli: VaultCLI) async {
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
    if Self.usesWeb { return GoogleExportCSV.list(try await webRows(cli, trigger: VaultRefreshReason.current), provider: id) }
    let (key, context) = try unlocked(cli)
    let list = ChromeLoginMapping.list(try logins(context), key: key, provider: id)
    guard list.keyFits else { throw VaultError.locked }
    return VaultItemList(items: list.items, passwords: list.passwords)
  }

  func secret(_ cli: VaultCLI, id itemId: String, field: VaultField) async throws -> String {
    if Self.usesWeb {
      guard field != .totp, GoogleExportCSV.isValidId(itemId) else { throw VaultError.notFound }
      var rows = await GoogleWebImporter.shared.latestRows
      if rows == nil { rows = try await webRows(cli, trigger: .person) }
      guard let row = rows?.first(where: { GoogleExportCSV.itemId(url: $0.url, username: $0.username) == itemId }) else { throw VaultError.notFound }
      let value = field == .username ? row.username : row.password
      guard !value.isEmpty else { throw VaultError.notFound }
      return value
    }
    let (key, context) = try unlocked(cli)
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
    guard !Self.usesWeb, let context = context(cli) else { return }
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

  private func context(_ cli: VaultCLI) -> Context? {
    guard let root = cli.dataFolder.map({ URL(fileURLWithPath: $0, isDirectory: true) }), let state = ChromeInstallation.localState(root)
    else { return nil }
    let profiles = ChromeInstallation.profiles(root)
    guard let profile = ChromeProfiles.choose(ChromeLocalState(profiles: profiles, lastUsed: state.lastUsed), preferred: cli.preference(Self.profilePreference))
    else { return nil }
    let context = Context(root: root, profile: profile, folder: root.appendingPathComponent(profile.directory, isDirectory: true))
    return Self.isUsable(context) ? context : nil
  }

  private static func isUsable(_ context: Context) -> Bool {
    let stores: [ChromeStore] = context.profile.signedIn ? ChromeStore.allCases : [.device]
    return stores.contains { FileManager.default.fileExists(atPath: context.file($0).path) }
  }

  private func unlocked(_ cli: VaultCLI) throws -> (Data, Context) {
    guard let session = cli.session, let key = ChromeCrypto.key(hex: session) else { throw VaultError.locked }
    guard let context = context(cli) else { throw VaultError.signedOut }
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
