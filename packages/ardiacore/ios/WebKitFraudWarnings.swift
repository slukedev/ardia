import WebKit

enum WebKitFraudWarnings {
  private(set) static var enabled = false

  static func set(_ on: Bool) {
    enabled = on
    guard WebKitHub.started else { return }
    for view in WebKitHub.shared.transfers.views {
      view.configuration.preferences.isFraudulentWebsiteWarningEnabled = on
    }
  }
}
