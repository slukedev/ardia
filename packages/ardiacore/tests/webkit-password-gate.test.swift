import Testing

private struct Choice: Sendable, CustomTestStringConvertible {
  let name: String
  let passwordsOn: Bool
  let systemProvider: Bool
  let fill: WebKitPasswordGate.Verdict
  let offerToSave: WebKitPasswordGate.Verdict

  var testDescription: String { name }
}

private let choices = [
  Choice(name: "Ardia", passwordsOn: true, systemProvider: false, fill: .ardia, offerToSave: .ardia),
  Choice(name: "none", passwordsOn: false, systemProvider: false, fill: .ardia, offerToSave: .offerToSaveOff),
  Choice(name: "a plugin filling through the system panel", passwordsOn: false, systemProvider: true, fill: .leftToManager, offerToSave: .leftToManager),
  Choice(name: "a plugin chosen before Offer to save turned off", passwordsOn: true, systemProvider: true, fill: .leftToManager, offerToSave: .leftToManager),
  Choice(name: "a plugin without system fill", passwordsOn: false, systemProvider: false, fill: .ardia, offerToSave: .offerToSaveOff),
]

@Suite struct PasswordManagerChoiceGate {
  @Test(arguments: choices)
  fileprivate func `WebKit fills from Ardia unless a manager fills through the system panel, and offers to save only when the manager is Ardia, like Chromium`(_ choice: Choice) {
    #expect(WebKitPasswordGate.verdict(.fill, passwordsOn: choice.passwordsOn, systemProvider: choice.systemProvider, privateProfile: false) == choice.fill)
    #expect(
      WebKitPasswordGate.verdict(.offerToSave, passwordsOn: choice.passwordsOn, systemProvider: choice.systemProvider, privateProfile: false)
        == choice.offerToSave)
  }

  @Test func `a private window fills from Ardia but never offers to save`() {
    #expect(WebKitPasswordGate.verdict(.fill, passwordsOn: true, systemProvider: false, privateProfile: true) == .ardia)
    #expect(WebKitPasswordGate.verdict(.offerToSave, passwordsOn: true, systemProvider: false, privateProfile: true) == .privateProfile)
  }

  @Test func `turning Offer to Save off keeps filling, as Chromium's IsFillingEnabled does`() {
    #expect(WebKitPasswordGate.verdict(.fill, passwordsOn: false, systemProvider: false, privateProfile: false) == .ardia)
    #expect(WebKitPasswordGate.verdict(.fill, passwordsOn: false, systemProvider: false, privateProfile: true) == .ardia)
  }

  @Test func `a private window still leaves fields to the chosen manager`() {
    #expect(WebKitPasswordGate.verdict(.fill, passwordsOn: true, systemProvider: true, privateProfile: true) == .leftToManager)
  }
}
