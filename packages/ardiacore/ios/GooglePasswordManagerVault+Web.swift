import Foundation

extension VaultRefreshReason {
  @TaskLocal static var readOnly = false
}

extension GooglePasswordManagerVault {
  func webSync(_ cli: VaultCLI) async throws -> VaultItemList {
    guard let password = Self.session(cli)?.webPassword else { throw VaultError.locked }
    let importer = GoogleWebImporter.shared
    if let fresh = await importer.takeFreshRows() { return GoogleExportCSV.list(fresh, provider: id) }
    let trigger = VaultRefreshReason.current
    let plan = GoogleSyncPlan(trigger: trigger, readOnly: VaultRefreshReason.readOnly)
    if plan.mayExport {
      let reply = await importer.export(trigger: trigger, password: password)
      switch reply {
      case .list(let rows):
        _ = await importer.takeFreshRows()
        return GoogleExportCSV.list(rows, provider: id)
      case .failed(.wrongPassword), .failed(.noPassword):
        throw VaultError.failed(GoogleImportError.wrongPassword.message)
      default:
        guard plan.mayRead else { throw Self.problem(reply) }
      }
    }
    switch await importer.list(byPerson: plan.readByPerson) {
    case .sites(let sites):
      let previous = await VaultBroker.shared.listedItems(Self.providerId)
      guard let merged = GoogleListRows.reconcile(previous: previous, sites: sites, provider: id) else {
        NSLog("[vaults] google read kept the list: %d site(s) against %d login(s) looked wrong", sites.count, previous.count)
        throw VaultError.failed(GoogleImportError.pageChanged.message)
      }
      NSLog("[vaults] google read: %d new site(s), %d login(s) gone", merged.added, merged.dropped)
      return VaultItemList(items: merged.items)
    case .failed(let error):
      throw VaultError.failed(error.message)
    case .refused(.busy):
      throw VaultError.failed(Self.busyMessage)
    case .refused:
      throw VaultError.failed("Google Password Manager synced a moment ago.")
    }
  }

  func webSecret(_ cli: VaultCLI, id itemId: String, field: VaultField) async throws -> String {
    guard field != .totp, GoogleExportCSV.isValidId(itemId) else { throw VaultError.notFound }
    let importer = GoogleWebImporter.shared
    if let rows = await importer.latestRows, let row = GoogleListRows.row(for: itemId, in: rows) { return try Self.value(row, field) }
    guard let password = Self.session(cli)?.webPassword else { throw VaultError.locked }
    let reply = await importer.export(trigger: .personAnyway, password: password)
    switch reply {
    case .list(let rows):
      Task { await VaultBroker.shared.googleListChanged() }
      guard let row = GoogleListRows.row(for: itemId, in: rows) else { throw VaultError.notFound }
      return try Self.value(row, field)
    case .failed(.wrongPassword), .failed(.noPassword):
      throw VaultError.failed(GoogleImportError.wrongPassword.message)
    case .refused(.busy), .refused(.notDue):
      throw VaultError.notDownloaded
    default:
      throw Self.problem(reply)
    }
  }

  private static let busyMessage = "Ardia is already talking to Google. Try again in a moment."

  private static func value(_ row: GoogleExportRow, _ field: VaultField) throws -> String {
    let value = field == .username ? row.username : row.password
    guard !value.isEmpty else { throw VaultError.notFound }
    return value
  }

  private static func problem(_ reply: GoogleExportReply) -> VaultError {
    switch reply {
    case .failed(let error), .confirm(_, let error), .refused(.held(let error)): return .failed(error.message)
    case .refused(.busy): return .failed(busyMessage)
    default: return .failed("Google Password Manager downloads your passwords at most once an hour.")
    }
  }
}
