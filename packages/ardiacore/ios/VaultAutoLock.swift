import AppKit

final class VaultAutoLock {
  static let shared = VaultAutoLock()
  static let screenLocked = Notification.Name("com.apple.screenIsLocked")
  static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")
  static let idleCheckInterval: TimeInterval = 60
  static let awayBeforeRefresh: TimeInterval = 300

  private var observers: [NSObjectProtocol] = []
  private var timer: Timer?
  private var inactiveSince: Date?

  func start() {
    DispatchQueue.main.async { self.begin() }
  }

  private func begin() {
    guard timer == nil else { return }
    timer = Timer.scheduledTimer(withTimeInterval: Self.idleCheckInterval, repeats: true) { _ in
      Task {
        await VaultBroker.shared.lockIdle()
        await VaultBroker.shared.syncDue()
      }
    }
    guard !LaunchConfig.shared.background else { return }
    let workspace = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
      observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in VaultAutoLock.lockEverything() })
    }
    for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
      observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in VaultAutoLock.setQuiet(false) })
    }
    let distributed = DistributedNotificationCenter.default()
    observers.append(distributed.addObserver(forName: Self.screenLocked, object: nil, queue: .main) { _ in VaultAutoLock.lockEverything() })
    observers.append(distributed.addObserver(forName: Self.screenUnlocked, object: nil, queue: .main) { _ in VaultAutoLock.setQuiet(false) })
    let app = NotificationCenter.default
    observers.append(app.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
      self?.inactiveSince = Date()
    })
    observers.append(app.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      guard let self else { return }
      let away = self.inactiveSince.map { Date().timeIntervalSince($0) } ?? 0
      self.inactiveSince = nil
      guard away >= Self.awayBeforeRefresh else { return }
      Task { await VaultBroker.shared.appBecameActive() }
    })
  }

  private static func setQuiet(_ quiet: Bool) {
    Task { await VaultBroker.shared.setQuiet(quiet) }
  }

  private static func lockEverything() {
    ArdiaWebView.wipeVaultCaptures()
    Task {
      await VaultBroker.shared.setQuiet(true)
      await VaultBroker.shared.lockAll()
    }
  }
}
