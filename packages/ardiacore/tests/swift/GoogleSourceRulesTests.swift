import Foundation
import Testing

@testable import ArdiaVaultsCore

struct GoogleSourceRulesTests {
  struct Case: CustomTestStringConvertible, Sendable {
    var choice: GoogleSourceChoice
    var chrome: ChromeReadiness
    var failure: ChromeFailure?
    var webReady: Bool
    var source: GoogleSource?
    var problem: ChromeFailure?
    var testDescription: String { "\(choice) \(chrome) \(failure?.rawValue ?? "-") web:\(webReady)" }
  }

  static let cases: [Case] = [
    Case(choice: .automatic, chrome: .account, webReady: true, source: .chrome),
    Case(choice: .automatic, chrome: .account, webReady: false, source: .chrome),
    Case(choice: .automatic, chrome: .account, failure: .keychainDenied, webReady: true, source: .web, problem: .keychainDenied),
    Case(choice: .automatic, chrome: .account, failure: .wrongKey, webReady: false, source: nil, problem: .wrongKey),
    Case(choice: .automatic, chrome: .unreadable, webReady: true, source: .web, problem: .unreadable),
    Case(choice: .automatic, chrome: .notInstalled, webReady: true, source: .web),
    Case(choice: .automatic, chrome: .notInstalled, webReady: false, source: nil),
    Case(choice: .automatic, chrome: .noProfile, webReady: true, source: .web),
    Case(choice: .automatic, chrome: .deviceOnly, webReady: true, source: .web),
    Case(choice: .automatic, chrome: .deviceOnly, webReady: false, source: .chrome),
    Case(choice: .automatic, chrome: .account, failure: .syncOff, webReady: true, source: .web, problem: .syncOff),
    Case(choice: .chrome, chrome: .account, webReady: true, source: .chrome),
    Case(choice: .chrome, chrome: .deviceOnly, webReady: true, source: .chrome),
    Case(choice: .chrome, chrome: .account, failure: .keychainDenied, webReady: true, source: nil, problem: .keychainDenied),
    Case(choice: .chrome, chrome: .notInstalled, webReady: true, source: nil),
    Case(choice: .web, chrome: .account, webReady: true, source: .web),
    Case(choice: .web, chrome: .account, webReady: false, source: nil),
  ]

  @Test(arguments: cases)
  func `the source follows the choice, Chrome first and the web as the backup`(c: Case) {
    let plan = GoogleSourceRules.plan(choice: c.choice, chrome: c.chrome, failure: c.failure, webReady: c.webReady)
    #expect(plan == GoogleSourcePlan(source: c.source, chromeProblem: c.problem))
  }

  @Test func `an unknown or missing preference means automatic`() {
    #expect(GoogleSourceChoice(preference: nil) == .automatic)
    #expect(GoogleSourceChoice(preference: "bogus") == .automatic)
    #expect(GoogleSourceChoice(preference: "web") == .web)
  }

  @Test func `an empty account store falls back only when signed in and the web is ready`() {
    #expect(GoogleSourceRules.failure(afterReading: 0, signedIn: true, webReady: true) == .syncOff)
    #expect(GoogleSourceRules.failure(afterReading: 3, signedIn: true, webReady: true) == nil)
    #expect(GoogleSourceRules.failure(afterReading: 0, signedIn: true, webReady: false) == nil)
    #expect(GoogleSourceRules.failure(afterReading: 0, signedIn: false, webReady: true) == nil)
  }
}

struct GoogleSessionTests {
  static let key = String(repeating: "ab", count: 16)

  @Test(arguments: [
    GoogleSession(chromeKey: key),
    GoogleSession(webPassword: "hunter2"),
    GoogleSession(chromeKey: key, webPassword: "a;web:b\nc"),
  ])
  func `a session survives its text form`(session: GoogleSession) throws {
    let text = try #require(session.text)
    #expect(GoogleSession(text) == session)
  }

  @Test func `sessions written before Chrome came first still read`() {
    #expect(GoogleSession(Self.key) == GoogleSession(chromeKey: Self.key))
    #expect(GoogleSession("web:pw") == GoogleSession(webPassword: "pw"))
    #expect(GoogleSession(Self.key)?.has(.web) == false)
  }

  @Test(arguments: ["", "web:", "nothex", "chrome:\(key)", "chrome:\(key);pw", "chrome:zz;web:pw"])
  func `malformed sessions are refused`(text: String) {
    #expect(GoogleSession(text) == nil)
  }
}
