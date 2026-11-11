import CryptoKit
import Foundation

struct GoogleImportSelectors: Codable, Equatable, Sendable {
  var importButtons = ["button[jsname=\"Pr7Yme\"]", "[jsname=\"Pr7Yme\"]"]
  var importButtonText = "Import"
  var exportButtons = ["button[aria-label=\"Export\"]", "[role=button][aria-label=\"Export\"]"]
  var exportDialogText = "export passwords"
  var confirmExportText = "Export"
  var dialogs = "[role=dialog], [role=alertdialog]"
  var fileInputs = "input[type=file]"
  var preparing = "[aria-label^=\"Preparing passwords\"]"
  var buttons = "button, [role=button]"
  var selectFileText = "Select file"
  var confirmImportText = "Import"
  var doneText = "Done"
  var passwordFields = "input[type=password]"
  var nextButtons = ["#passwordNext button", "#passwordNext"]
  var nextText = "Next"
  var captchaFrames = "iframe[src*=\"recaptcha\"], #captchaimg, [data-sitekey]"
  var invalidFields = "input[type=password][aria-invalid=\"true\"]"

  static let current = GoogleImportSelectors()
}

struct GoogleImportText: Sendable {
  static let imported = #"(\d+)\s+passwords?\s+imported"#
  static let importDialog = ["import passwords"]
  static let importFailures = ["couldn't import", "could not import", "can't import", "wasn't imported", "weren't imported", "something went wrong", "file isn't valid", "invalid file"]
  static let wrongPassword = ["wrong password", "incorrect password", "password was changed", "try again or click forgot password"]
  static let insecureBrowser = ["this browser or app may not be secure", "couldn't sign you in"]
  static let captcha = ["not a robot", "type the text you hear or see", "confirm you're not a robot"]
  static let onDeviceEncryption = ["on-device encryption", "unlock your passwords", "password manager pin", "enter your pin"]
  static let unusualActivity = ["unusual activity", "suspicious activity", "something seems different"]
  static let twoStep = ["2-step verification", "verify it's you with", "check your phone", "enter a verification code", "use your passkey"]
}

struct GoogleImportSite: Equatable, Sendable {
  static let googlePasswords = "https://passwords.google.com"
  static let googleAccounts = "https://accounts.google.com"
  static let importPath = "/options?import=1"
  static let optionsPath = "/options"

  var passwords: String
  var accounts: String

  static let google = GoogleImportSite(passwords: googlePasswords, accounts: googleAccounts)

  var importURL: String { passwords + Self.importPath }
  var optionsURL: String { passwords + Self.optionsPath }
  var signInURL: String {
    let next = optionsURL.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? optionsURL
    return accounts + "/ServiceLogin?continue=" + next
  }

  static func origin(of url: String) -> String? {
    guard let parts = URLComponents(string: url), let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased(), !host.isEmpty
    else { return nil }
    let port = parts.port.map { ":\($0)" } ?? ""
    return "\(scheme)://\(host)\(port)"
  }

  func isPasswords(_ url: String) -> Bool { Self.origin(of: url) == Self.origin(of: passwords) }
  func isAccounts(_ url: String) -> Bool { Self.origin(of: url) == Self.origin(of: accounts) }
}

struct GoogleImportSnapshot: Codable, Equatable, Sendable {
  var url: String
  var text: String = ""
  var dialog: String? = nil
  var dialogButtons: [String] = []
  var importButton: Bool = false
  var exportButton: Bool? = nil
  var fileInput: Bool = false
  var preparing: Bool = false
  var passwordField: Bool = false
  var passwordInvalid: Bool = false
  var captcha: Bool = false
  var ready: Bool = true

  static func parse(_ json: String?) -> GoogleImportSnapshot? {
    guard let data = json?.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(GoogleImportSnapshot.self, from: data)
  }
}

enum GoogleImportStage: Equatable, Sendable {
  case loading
  case options(importButton: Bool)
  case confirmExport
  case preparing
  case selectFile
  case readyToImport
  case imported(Int)
  case importFailed
  case passwordChallenge(rejected: Bool)
  case signIn
  case twoStep
  case captcha
  case unusualActivity
  case insecureBrowser
  case onDeviceEncryption
  case elsewhere

  var needsPerson: GoogleImportError? {
    switch self {
    case .signIn: return .signIn
    case .twoStep: return .twoStep
    case .captcha: return .captcha
    case .unusualActivity: return .unusualActivity
    default: return nil
    }
  }
}

enum GoogleImportError: String, Error, CaseIterable, Codable, Sendable {
  case noPassword
  case wrongPassword
  case signIn
  case twoStep
  case captcha
  case unusualActivity
  case insecureBrowser
  case onDeviceEncryption
  case checkTooSoon
  case pageChanged
  case network
  case timeout
  case importFailed
  case cancelled
  case notAllowed
  case unavailable

  var message: String {
    switch self {
    case .noPassword: return "Ardia needs your Google password to save to Google."
    case .wrongPassword: return "Google didn't accept the saved password."
    case .signIn: return "Sign in to Google in Ardia to save to it."
    case .twoStep: return "Google wants a second step to confirm it's you."
    case .captcha: return "Google wants to check you're not a robot."
    case .unusualActivity: return "Google noticed unusual activity and wants you to confirm it's you."
    case .insecureBrowser: return "Google says this browser may not be secure."
    case .onDeviceEncryption: return "Your Google passwords use on-device encryption, so Ardia can't import into them."
    case .checkTooSoon: return "Google asked for your password again too soon. Ardia will try later."
    case .pageChanged: return "Google's import page changed, so Ardia couldn't finish the save."
    case .network: return "Ardia couldn't reach Google. Check your connection."
    case .timeout: return "Google took too long to save the password."
    case .importFailed: return "Google couldn't import the password."
    case .cancelled: return "The save to Google was cancelled."
    case .notAllowed: return "Ardia needs your OK to use your Google password."
    case .unavailable: return "Ardia isn't ready to save to Google yet."
    }
  }

  var needsPerson: Bool { self == .signIn || self == .twoStep || self == .captcha || self == .unusualActivity }

  var action: String? {
    switch self {
    case .noPassword, .wrongPassword: return "updatePassword"
    case .signIn, .twoStep, .captcha, .unusualActivity: return "confirm"
    default: return nil
    }
  }
}

enum GoogleImportClassifier {
  static func classify(_ snapshot: GoogleImportSnapshot, site: GoogleImportSite, selectors: GoogleImportSelectors = .current) -> GoogleImportStage {
    let text = snapshot.text.lowercased()
    let dialog = snapshot.dialog?.lowercased()
    let path = URLComponents(string: snapshot.url)?.path.lowercased() ?? ""
    if site.isAccounts(snapshot.url) { return accountsStage(path: path, text: text, snapshot: snapshot) }
    guard site.isPasswords(snapshot.url) else { return snapshot.url.isEmpty || snapshot.url == "about:blank" ? .loading : .elsewhere }
    if !snapshot.ready { return .loading }
    if let dialog {
      if let count = importedCount(dialog) { return count > 0 ? .imported(count) : .importFailed }
      if contains(dialog, GoogleImportText.importFailures) { return .importFailed }
      if contains(dialog, GoogleImportText.onDeviceEncryption) { return .onDeviceEncryption }
      let buttons = Set(snapshot.dialogButtons)
      if dialog.contains(selectors.exportDialogText), buttons.contains(selectors.confirmExportText) { return .confirmExport }
      if buttons.contains(selectors.confirmImportText) { return .readyToImport }
      if buttons.contains(selectors.selectFileText) { return .selectFile }
      if contains(dialog, GoogleImportText.importDialog) { return snapshot.preparing ? .preparing : .selectFile }
    }
    if snapshot.preparing { return .preparing }
    return .options(importButton: snapshot.importButton)
  }

  static func importedCount(_ text: String) -> Int? {
    guard let pattern = try? NSRegularExpression(pattern: GoogleImportText.imported, options: [.caseInsensitive]),
      let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges > 1,
      let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return Int(text[range])
  }

  private static func accountsStage(path: String, text: String, snapshot: GoogleImportSnapshot) -> GoogleImportStage {
    if path.contains("/signin/rejected") || contains(text, GoogleImportText.insecureBrowser) { return .insecureBrowser }
    if path.contains("/challenge/recaptcha") || snapshot.captcha || contains(text, GoogleImportText.captcha) { return .captcha }
    if contains(text, GoogleImportText.unusualActivity) { return .unusualActivity }
    if path.contains("/challenge/pwd") || (path.contains("/challenge/") && snapshot.passwordField) {
      return .passwordChallenge(rejected: snapshot.passwordInvalid || contains(text, GoogleImportText.wrongPassword))
    }
    if path.contains("/challenge/") { return .twoStep }
    if !snapshot.ready { return .loading }
    return .signIn
  }

  private static func contains(_ text: String, _ needles: [String]) -> Bool { needles.contains { text.contains($0) } }
}

enum GoogleImportAction: Equatable, Sendable {
  case wait
  case clickImport
  case fillPassword
  case clickSelectFile
  case clickConfirmImport
  case finish(Int)
  case needPerson(GoogleImportError)
  case fail(GoogleImportError)
}

struct GoogleImportFlow: Sendable {
  static let overallTimeout: TimeInterval = 60
  static let stepTimeout: TimeInterval = 20
  static let personTimeout: TimeInterval = 300
  static let clickSpacing: TimeInterval = 4
  static let selectFileDelay: TimeInterval = 2
  static let resubmitAfter: TimeInterval = 10

  let started: Date
  var stage: GoogleImportStage = .loading
  var stageSince: Date
  var passwordSubmissions = 0
  var lastSubmission: Date?
  var importClicks = 0
  var lastImportClick: Date?
  var selectFileClicks = 0
  var lastSelectFileClick: Date?
  var confirmClicks = 0
  var lastConfirmClick: Date?
  var person: Date?

  init(started: Date) {
    self.started = started
    stageSince = started
  }

  mutating func personStarted(_ now: Date) {
    if person == nil { person = now }
  }

  mutating func step(_ next: GoogleImportStage, now: Date) -> GoogleImportAction {
    if next != stage {
      stage = next
      stageSince = now
    }
    let deadline = person.map { $0.addingTimeInterval(Self.personTimeout) } ?? started.addingTimeInterval(Self.overallTimeout)
    if now >= deadline { return .fail(.timeout) }
    if let error = next.needsPerson { return .needPerson(error) }
    let stuck = person == nil && now.timeIntervalSince(stageSince) >= Self.stepTimeout
    switch next {
    case .loading:
      return stuck ? .fail(.network) : .wait
    case .elsewhere:
      return stuck ? .fail(.pageChanged) : .wait
    case .options(let button):
      if button, importClicks < 2, spaced(lastImportClick, now) {
        importClicks += 1
        lastImportClick = now
        return .clickImport
      }
      return stuck ? .fail(.pageChanged) : .wait
    case .preparing:
      return stuck ? .fail(.timeout) : .wait
    case .selectFile:
      if now.timeIntervalSince(stageSince) >= Self.selectFileDelay, selectFileClicks < 2, spaced(lastSelectFileClick, now) {
        selectFileClicks += 1
        lastSelectFileClick = now
        return .clickSelectFile
      }
      return stuck ? .fail(.pageChanged) : .wait
    case .readyToImport:
      if confirmClicks < 2, spaced(lastConfirmClick, now) {
        confirmClicks += 1
        lastConfirmClick = now
        return .clickConfirmImport
      }
      return stuck ? .fail(.pageChanged) : .wait
    case .imported(let count):
      return .finish(count)
    case .importFailed:
      return .fail(.importFailed)
    case .passwordChallenge(let rejected):
      if rejected, passwordSubmissions > 0 { return .fail(.wrongPassword) }
      if passwordSubmissions == 0 || (passwordSubmissions == 1 && lastSubmission.map { now.timeIntervalSince($0) >= Self.resubmitAfter } == true) {
        passwordSubmissions += 1
        lastSubmission = now
        return .fillPassword
      }
      if passwordSubmissions >= 2, lastSubmission.map({ now.timeIntervalSince($0) >= Self.resubmitAfter }) == true { return .fail(.wrongPassword) }
      return .wait
    case .insecureBrowser:
      return .fail(.insecureBrowser)
    case .onDeviceEncryption:
      return .fail(.onDeviceEncryption)
    case .confirmExport:
      return stuck ? .fail(.pageChanged) : .wait
    case .signIn, .twoStep, .captcha, .unusualActivity:
      return .wait
    }
  }

  private func spaced(_ last: Date?, _ now: Date) -> Bool {
    last.map { now.timeIntervalSince($0) >= Self.clickSpacing } ?? true
  }
}

enum GoogleImportCSV {
  static let header = "name,url,username,password,note"
  static let fileName = "Ardia.csv"

  static func make(name: String, url: String, username: String, password: String) -> String {
    let row = [name, url, username, password, ""].map(field).joined(separator: ",")
    return "\(header)\n\(row)\n"
  }

  static func field(_ value: String) -> String {
    "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
  }

  static func dedupeKey(url: String, username: String, password: String) -> String {
    let joined = [url, username, password].map { "\($0.utf8.count):\($0)" }.joined()
    return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
