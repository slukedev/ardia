import Foundation

enum WebKitPasswordGate {
  enum Use: Sendable {
    case fill
    case offerToSave
  }

  enum Verdict: Equatable, Sendable {
    case ardia
    case offerToSaveOff
    case leftToManager
    case privateProfile
  }

  static func verdict(_ use: Use, passwordsOn: Bool, systemProvider: Bool, privateProfile: Bool) -> Verdict {
    if systemProvider { return .leftToManager }
    guard use == .offerToSave else { return .ardia }
    if !passwordsOn { return .offerToSaveOff }
    if privateProfile { return .privateProfile }
    return .ardia
  }
}
