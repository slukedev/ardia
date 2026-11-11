import AppKit
import Foundation

actor ChromeStoreWatcher {
  static let shared = ChromeStoreWatcher()
  static let interval: UInt64 = 2_000_000_000
  private static let oldHandoffFolder = "Ardia Chrome Handoff"

  private var pending: [String: ChromeHandoff] = [:]
  private var stores: [String: [URL]] = [:]
  private var polling: Task<Void, Never>?
  private var swept = false

  @MainActor
  static func start() {
    Task { await shared.sweepOnce() }
  }

  func sweepOnce() {
    guard !swept else { return }
    swept = true
    ChromeLoginReader.sweepStaleCopies()
    let base = LaunchConfig.shared.dataDirectory ?? NSTemporaryDirectory()
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent(Self.oldHandoffFolder, isDirectory: true))
  }

  func watch(_ handoff: ChromeHandoff, stores files: [URL]) {
    pending[handoff.id] = handoff
    stores[handoff.id] = files
    guard polling == nil else { return }
    polling = Task { await self.poll() }
  }

  private func poll() async {
    while !pending.isEmpty {
      try? await Task.sleep(nanoseconds: Self.interval)
      for id in Array(pending.keys) { check(id) }
    }
    polling = nil
  }

  private func check(_ id: String) {
    guard let handoff = pending[id], let files = stores[id] else { return }
    let key = VaultSessionStore.shared.session(GooglePasswordManagerVault.providerId).flatMap(GoogleSession.init)?.chromeKey.flatMap(ChromeCrypto.key(hex:))
    let modified = files.compactMap(ChromeLoginReader.modified).max()
    let step = ChromeHandoffRules.step(handoff, now: Date(), modified: modified, key: key) {
      var rows: [ChromeLogin] = []
      var readAny = false
      for (file, store) in zip(files, ChromeStore.allCases) {
        do {
          rows += try ChromeLoginReader.read(file, store: store)
          readAny = true
        } catch ChromeReadError.missing {
          continue
        } catch {
          return nil
        }
      }
      return readAny ? rows : nil
    }
    switch step {
    case .waiting(let next): pending[id] = next
    case .saved:
      drop(id)
      Task { await VaultBroker.shared.storeChanged(GooglePasswordManagerVault.providerId) }
    case .expired: drop(id)
    }
  }

  private func drop(_ id: String) {
    pending[id] = nil
    stores[id] = nil
  }
}
