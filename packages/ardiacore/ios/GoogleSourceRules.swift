import Foundation

enum GoogleSource: String, Sendable {
  case chrome
  case web
}

enum GoogleSourceChoice: String, CaseIterable, Sendable {
  case automatic
  case chrome
  case web

  init(preference: String?) { self = preference.flatMap(Self.init(rawValue:)) ?? .automatic }
}

enum ChromeReadiness: Equatable, Sendable {
  case notInstalled
  case unreadable
  case noProfile
  case deviceOnly
  case account
}

enum ChromeFailure: String, Error, Equatable, Sendable {
  case keychainDenied
  case keyMissing
  case keychainFailed
  case wrongKey
  case unreadable
  case signedOut
  case syncOff

  var message: String {
    switch self {
    case .keychainDenied: return "Chrome's keychain access was denied."
    case .keyMissing: return "Chrome's key isn't in your keychain. Open Chrome once, then try again."
    case .keychainFailed: return "Ardia couldn't read Chrome's keychain key."
    case .wrongKey: return "Chrome's passwords didn't open with its keychain key."
    case .unreadable: return "macOS didn't let Ardia read Chrome's passwords."
    case .signedOut: return "Chrome isn't signed in to Google."
    case .syncOff: return "Chrome isn't saving passwords to your Google Account."
    }
  }
}

struct GoogleSourcePlan: Equatable, Sendable {
  var source: GoogleSource?
  var chromeProblem: ChromeFailure?
}

enum GoogleSourceRules {
  static func plan(choice: GoogleSourceChoice, chrome: ChromeReadiness, failure: ChromeFailure?, webReady: Bool) -> GoogleSourcePlan {
    let problem = failure ?? (chrome == .unreadable ? .unreadable : nil)
    let healthy = failure == nil
    switch choice {
    case .web:
      return GoogleSourcePlan(source: webReady ? .web : nil)
    case .chrome:
      let usable = healthy && (chrome == .account || chrome == .deviceOnly)
      return GoogleSourcePlan(source: usable ? .chrome : nil, chromeProblem: usable ? nil : problem)
    case .automatic:
      if healthy, chrome == .account { return GoogleSourcePlan(source: .chrome) }
      if webReady { return GoogleSourcePlan(source: .web, chromeProblem: problem) }
      if healthy, chrome == .deviceOnly { return GoogleSourcePlan(source: .chrome) }
      return GoogleSourcePlan(source: nil, chromeProblem: problem)
    }
  }

  static func failure(afterReading accountRows: Int, signedIn: Bool, webReady: Bool) -> ChromeFailure? {
    guard signedIn, webReady, accountRows == 0 else { return nil }
    return .syncOff
  }
}

struct GoogleSession: Equatable, Sendable {
  private static let chromePrefix = "chrome:"
  private static let webPrefix = "web:"
  private static let separator = ";"
  private static let keyLength = 32

  var chromeKey: String?
  var webPassword: String?

  init(chromeKey: String? = nil, webPassword: String? = nil) {
    self.chromeKey = chromeKey.flatMap(Self.validKey)
    self.webPassword = webPassword.flatMap { $0.isEmpty ? nil : $0 }
  }

  init?(_ text: String) {
    if text.hasPrefix(Self.webPrefix) {
      self.init(webPassword: String(text.dropFirst(Self.webPrefix.count)))
    } else if text.hasPrefix(Self.chromePrefix) {
      let rest = text.dropFirst(Self.chromePrefix.count)
      let key = String(rest.prefix(Self.keyLength))
      let tail = rest.dropFirst(Self.keyLength)
      guard Self.validKey(key) != nil, tail.hasPrefix(Self.separator + Self.webPrefix) else { return nil }
      self.init(chromeKey: key, webPassword: String(tail.dropFirst(Self.separator.count + Self.webPrefix.count)))
    } else {
      self.init(chromeKey: text)
    }
    guard chromeKey != nil || webPassword != nil else { return nil }
  }

  var text: String? {
    switch (chromeKey, webPassword) {
    case (let key?, let password?): return Self.chromePrefix + key + Self.separator + Self.webPrefix + password
    case (let key?, nil): return key
    case (nil, let password?): return Self.webPrefix + password
    case (nil, nil): return nil
    }
  }

  func has(_ source: GoogleSource) -> Bool { source == .chrome ? chromeKey != nil : webPassword != nil }

  private static func validKey(_ key: String) -> String? {
    let lowered = key.lowercased()
    guard lowered.count == keyLength, lowered.allSatisfy(\.isHexDigit) else { return nil }
    return lowered
  }
}
