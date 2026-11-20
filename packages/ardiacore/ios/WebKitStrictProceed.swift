import Foundation

enum WebKitStrictProceed {
  enum Decision: Equatable, Sendable {
    case notAPass
    case reloadAsNewLoad(URL)
  }

  static func decide(shown: URL?, showingError: Bool, target: URL, fromMainFrame: Bool, linkActivated: Bool) -> Decision {
    guard let shown, showingError, shown == target, fromMainFrame, linkActivated else { return .notAPass }
    return .reloadAsNewLoad(target)
  }
}
