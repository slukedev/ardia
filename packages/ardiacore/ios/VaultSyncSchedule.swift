import Foundation

enum VaultSyncSchedule: Equatable, Sendable {
  case automatic
  case every(TimeInterval)
  case manual

  enum Trigger: Sendable {
    case use
    case timer
  }

  static let automaticLifetime: TimeInterval = 60
  static let longestInterval: TimeInterval = 86_400

  init(seconds: Double?) {
    guard let seconds, seconds.isFinite else {
      self = .automatic
      return
    }
    guard seconds > 0 else {
      self = .manual
      return
    }
    self = .every(min(max(seconds, Self.automaticLifetime), Self.longestInterval))
  }

  var lifetime: TimeInterval? {
    switch self {
    case .automatic: Self.automaticLifetime
    case .every(let interval): interval
    case .manual: nil
    }
  }

  var runsOnTimer: Bool {
    if case .every = self { return true }
    return false
  }

  func refreshes(_ trigger: Trigger, fetchedAt: Date?, now: Date, unlocked: Bool, inFlight: Bool) -> Bool {
    guard unlocked, !inFlight, let lifetime else { return false }
    guard trigger == .use || runsOnTimer else { return false }
    guard let fetchedAt else { return true }
    return now.timeIntervalSince(fetchedAt) >= lifetime
  }
}
