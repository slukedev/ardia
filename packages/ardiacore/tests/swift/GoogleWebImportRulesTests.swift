import Foundation
import Testing

@testable import ArdiaVaultsCore

struct GoogleImportClassifierTests {
  let site = GoogleImportSite.google
  let importURL = "https://passwords.google.com/options?import=1&rapt=abc"
  let challengeURL = "https://accounts.google.com/v3/signin/challenge/pwd?TL=x&continue=https%3A%2F%2Fpasswords.google.com%2Foptions%3Fimport%3D1"

  func stage(_ snapshot: GoogleImportSnapshot) -> GoogleImportStage { GoogleImportClassifier.classify(snapshot, site: site) }

  @Test func `the options page with its Import button asks to click it`() {
    #expect(stage(GoogleImportSnapshot(url: "https://passwords.google.com/options", text: "Import passwords On-device encryption", importButton: true)) == .options(importButton: true))
  }

  @Test func `the on-device encryption row on the options page alone isn't a refusal`() {
    let page = GoogleImportSnapshot(url: importURL, text: "On-device encryption Set up", importButton: true)
    #expect(stage(page) == .options(importButton: true))
  }

  @Test func `Google's verify-it's-you page is the password challenge`() {
    let page = GoogleImportSnapshot(url: challengeURL, text: "To continue, first verify it's you", passwordField: true)
    #expect(stage(page) == .passwordChallenge(rejected: false))
  }

  @Test(arguments: [
    GoogleImportSnapshot(url: "https://accounts.google.com/v3/signin/challenge/pwd?x=1", text: "Wrong password. Try again", passwordField: true),
    GoogleImportSnapshot(url: "https://accounts.google.com/v3/signin/challenge/pwd?x=1", text: "Enter your password", passwordField: true, passwordInvalid: true),
  ])
  func `a rejected password reads as rejected`(page: GoogleImportSnapshot) {
    #expect(stage(page) == .passwordChallenge(rejected: true))
  }

  @Test(arguments: [
    ("https://accounts.google.com/v3/signin/identifier?continue=x", GoogleImportStage.signIn),
    ("https://accounts.google.com/ServiceLogin?continue=x", .signIn),
    ("https://accounts.google.com/v3/signin/challenge/totp?x=1", .twoStep),
    ("https://accounts.google.com/v3/signin/challenge/ipp?x=1", .twoStep),
    ("https://accounts.google.com/v3/signin/challenge/recaptcha?x=1", .captcha),
    ("https://accounts.google.com/v3/signin/rejected?x=1", .insecureBrowser),
  ])
  func `accounts pages map to what Google wants`(url: String, expected: GoogleImportStage) {
    #expect(stage(GoogleImportSnapshot(url: url)) == expected)
  }

  @Test func `a captcha frame on a sign-in page is a captcha`() {
    #expect(stage(GoogleImportSnapshot(url: "https://accounts.google.com/v3/signin/identifier", captcha: true)) == .captcha)
  }

  @Test func `an insecure-browser message is caught even on another accounts path`() {
    let page = GoogleImportSnapshot(url: "https://accounts.google.com/v3/signin/identifier", text: "Couldn't sign you in. This browser or app may not be secure.")
    #expect(stage(page) == .insecureBrowser)
  }

  @Test func `the import dialog walks select file, ready, imported`() {
    let dialog = "Import passwords\nTo import passwords to your Google Account, select a CSV file."
    #expect(stage(GoogleImportSnapshot(url: importURL, dialog: dialog, dialogButtons: ["Cancel", "Select file"], fileInput: true)) == .selectFile)
    let chosen = "Import passwords\nArdia.csv"
    #expect(stage(GoogleImportSnapshot(url: importURL, dialog: chosen, dialogButtons: ["Select new file", "Cancel", "Import"])) == .readyToImport)
    #expect(stage(GoogleImportSnapshot(url: importURL, dialog: "Import passwords\n1 password imported\nDone", dialogButtons: ["Done"])) == .imported(1))
    #expect(stage(GoogleImportSnapshot(url: importURL, dialog: "Import passwords\n12 passwords imported", dialogButtons: ["Done"])) == .imported(12))
  }

  @Test func `zero imported or an error in the dialog is a failure`() {
    #expect(stage(GoogleImportSnapshot(url: importURL, dialog: "0 passwords imported", dialogButtons: ["Done"])) == .importFailed)
    #expect(stage(GoogleImportSnapshot(url: importURL, dialog: "Something went wrong", dialogButtons: ["Done"])) == .importFailed)
  }

  @Test func `on-device encryption inside the dialog refuses the import`() {
    let page = GoogleImportSnapshot(url: importURL, dialog: "Unlock your passwords. Enter your Password Manager PIN", dialogButtons: ["Cancel", "Next"])
    #expect(stage(page) == .onDeviceEncryption)
  }

  @Test func `the preparing spinner waits`() {
    #expect(stage(GoogleImportSnapshot(url: importURL, preparing: true)) == .preparing)
  }

  @Test func `a page still loading, blank or elsewhere waits`() {
    #expect(stage(GoogleImportSnapshot(url: importURL, ready: false)) == .loading)
    #expect(stage(GoogleImportSnapshot(url: "about:blank")) == .loading)
    #expect(stage(GoogleImportSnapshot(url: "https://myaccount.google.com/")) == .elsewhere)
  }

  @Test func `a test site swaps both origins and nothing else`() {
    let fixture = GoogleImportSite(passwords: "http://127.0.0.1:8790", accounts: "http://localhost:8790")
    #expect(GoogleImportClassifier.classify(GoogleImportSnapshot(url: "http://localhost:8790/v3/signin/challenge/pwd?x=1", passwordField: true), site: fixture) == .passwordChallenge(rejected: false))
    #expect(GoogleImportClassifier.classify(GoogleImportSnapshot(url: "https://passwords.google.com/options", importButton: true), site: fixture) == .elsewhere)
    #expect(fixture.importURL == "http://127.0.0.1:8790/options?import=1")
  }

  @Test func `snapshots parse from the page's JSON and junk doesn't`() {
    let parsed = GoogleImportSnapshot.parse(#"{"url":"https://passwords.google.com/options","text":"","dialog":null,"dialogButtons":[],"importButton":true,"fileInput":false,"preparing":false,"passwordField":false,"passwordInvalid":false,"captcha":false,"ready":true}"#)
    #expect(parsed?.importButton == true)
    #expect(GoogleImportSnapshot.parse("nope") == nil)
    #expect(GoogleImportSnapshot.parse(nil) == nil)
  }
}

struct GoogleImportFlowTests {
  let start = Date(timeIntervalSince1970: 1_800_000_000)

  func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

  @Test func `a clean run clicks Import, fills once, picks the file, imports and finishes`() {
    var flow = GoogleImportFlow(started: start)
    #expect(flow.step(.loading, now: at(0.3)) == .wait)
    #expect(flow.step(.options(importButton: true), now: at(1)) == .clickImport)
    #expect(flow.step(.options(importButton: true), now: at(2)) == .wait)
    #expect(flow.step(.passwordChallenge(rejected: false), now: at(3)) == .fillPassword)
    #expect(flow.step(.passwordChallenge(rejected: false), now: at(4)) == .wait)
    #expect(flow.step(.preparing, now: at(5)) == .wait)
    #expect(flow.step(.selectFile, now: at(5.5)) == .wait)
    #expect(flow.step(.readyToImport, now: at(6)) == .clickConfirmImport)
    #expect(flow.step(.imported(1), now: at(7)) == .finish(1))
  }

  @Test func `the select file button is pressed only when the page's own chooser didn't come`() {
    var flow = GoogleImportFlow(started: start)
    #expect(flow.step(.selectFile, now: at(1)) == .wait)
    #expect(flow.step(.selectFile, now: at(3.1)) == .clickSelectFile)
    #expect(flow.step(.selectFile, now: at(4)) == .wait)
    #expect(flow.step(.selectFile, now: at(7.2)) == .clickSelectFile)
    #expect(flow.step(.selectFile, now: at(12)) == .wait)
  }

  @Test func `a rejected password fails at once and is never filled again`() {
    var flow = GoogleImportFlow(started: start)
    #expect(flow.step(.passwordChallenge(rejected: false), now: at(1)) == .fillPassword)
    #expect(flow.step(.passwordChallenge(rejected: true), now: at(2)) == .fail(.wrongPassword))
  }

  @Test func `an ignored submit is retried once, then counts as wrong`() {
    var flow = GoogleImportFlow(started: start)
    #expect(flow.step(.passwordChallenge(rejected: false), now: at(1)) == .fillPassword)
    #expect(flow.step(.passwordChallenge(rejected: false), now: at(11)) == .fillPassword)
    #expect(flow.step(.passwordChallenge(rejected: false), now: at(15)) == .wait)
    #expect(flow.step(.passwordChallenge(rejected: false), now: at(21.5)) == .fail(.wrongPassword))
  }

  @Test(arguments: [(GoogleImportStage.signIn, GoogleImportError.signIn), (.twoStep, .twoStep), (.captcha, .captcha)])
  func `human-only pages ask for the person and get five minutes`(stage: GoogleImportStage, error: GoogleImportError) {
    var flow = GoogleImportFlow(started: start)
    #expect(flow.step(stage, now: at(1)) == .needPerson(error))
    flow.personStarted(at(1))
    #expect(flow.step(.readyToImport, now: at(120)) == .clickConfirmImport)
    #expect(flow.step(.readyToImport, now: at(290)) == .clickConfirmImport)
    #expect(flow.step(.selectFile, now: at(302)) == .fail(.timeout))
  }

  @Test(arguments: [(GoogleImportStage.insecureBrowser, GoogleImportError.insecureBrowser), (.onDeviceEncryption, .onDeviceEncryption), (.importFailed, .importFailed)])
  func `dead ends fail with their own code`(stage: GoogleImportStage, error: GoogleImportError) {
    var flow = GoogleImportFlow(started: start)
    #expect(flow.step(stage, now: at(1)) == .fail(error))
  }

  @Test func `a page stuck on one step fails with its reason`() {
    var loading = GoogleImportFlow(started: start)
    #expect(loading.step(.loading, now: at(1)) == .wait)
    #expect(loading.step(.loading, now: at(21)) == .fail(.network))
    var missing = GoogleImportFlow(started: start)
    #expect(missing.step(.options(importButton: false), now: at(1)) == .wait)
    #expect(missing.step(.options(importButton: false), now: at(21.5)) == .fail(.pageChanged))
  }

  @Test func `nothing runs past sixty seconds`() {
    var flow = GoogleImportFlow(started: start)
    #expect(flow.step(.preparing, now: at(50)) == .wait)
    #expect(flow.step(.selectFile, now: at(60)) == .fail(.timeout))
  }

  @Test func `Import is clicked at most twice, four seconds apart`() {
    var flow = GoogleImportFlow(started: start)
    #expect(flow.step(.options(importButton: true), now: at(1)) == .clickImport)
    #expect(flow.step(.options(importButton: true), now: at(3)) == .wait)
    #expect(flow.step(.options(importButton: true), now: at(5)) == .clickImport)
    #expect(flow.step(.options(importButton: true), now: at(10)) == .wait)
  }
}

struct GoogleImportCSVTests {
  @Test func `the CSV has Google's header and one row`() {
    let csv = GoogleImportCSV.make(name: "github.com", url: "https://github.com", username: "octo", password: "p4ss")
    #expect(csv == "name,url,username,password,note\n\"github.com\",\"https://github.com\",\"octo\",\"p4ss\",\"\"\n")
  }

  @Test(arguments: [("a\"b", "\"a\"\"b\""), ("a,b", "\"a,b\""), ("line\nbreak", "\"line\nbreak\""), ("", "\"\""), ("=SUM(A1)", "\"=SUM(A1)\"")])
  func `fields are quoted and quotes doubled`(value: String, expected: String) {
    #expect(GoogleImportCSV.field(value) == expected)
  }

  @Test func `the same login dedupes, any change doesn't`() {
    let key = GoogleImportCSV.dedupeKey(url: "https://github.com", username: "octo", password: "p")
    #expect(key == GoogleImportCSV.dedupeKey(url: "https://github.com", username: "octo", password: "p"))
    #expect(key != GoogleImportCSV.dedupeKey(url: "https://github.com", username: "octo", password: "q"))
    #expect(GoogleImportCSV.dedupeKey(url: "a", username: "bc", password: "") != GoogleImportCSV.dedupeKey(url: "ab", username: "c", password: ""))
  }
}

struct GoogleImportErrorTests {
  @Test func `every code has a one-line message`() {
    for error in GoogleImportError.allCases {
      #expect(!error.message.isEmpty)
      #expect(!error.message.contains("\n"))
    }
  }

  @Test func `only human checks need the person, and passwords offer an update`() {
    #expect(GoogleImportError.allCases.filter(\.needsPerson) == [.signIn, .twoStep, .captcha, .unusualActivity])
    #expect(GoogleImportError.wrongPassword.action == "updatePassword")
    #expect(GoogleImportError.noPassword.action == "updatePassword")
    #expect(GoogleImportError.twoStep.action == "confirm")
    #expect(GoogleImportError.network.action == nil)
    #expect(GoogleImportError.wrongPassword.message == "Google didn't accept the saved password.")
  }

  @Test func `human pages say which error they are`() {
    #expect(GoogleImportStage.captcha.needsPerson == .captcha)
    #expect(GoogleImportStage.selectFile.needsPerson == nil)
  }
}
