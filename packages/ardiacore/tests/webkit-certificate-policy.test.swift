import Foundation
import Testing

struct CertificateExceptions {
  let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func `a proceed covers the same host, certificate and errors`() {
    var policy = WebKitCertificatePolicy()
    policy.allow(host: "Self-Signed.example", fingerprint: "AA", errors: ["authorityInvalid"], now: now)
    let result1 = policy.admits(host: "self-signed.example", fingerprint: "AA", errors: ["authorityInvalid"], now: now)
    #expect(result1)
    let result2 = policy.admits(host: "self-signed.example", fingerprint: "BB", errors: ["authorityInvalid"], now: now)
    #expect(!result2)
    let result3 = policy.admits(host: "other.example", fingerprint: "AA", errors: ["authorityInvalid"], now: now)
    #expect(!result3)
  }

  @Test func `a new error on the same certificate asks again`() {
    var policy = WebKitCertificatePolicy()
    policy.allow(host: "a.example", fingerprint: "AA", errors: ["nameMismatch"], now: now)
    let result4 = policy.admits(host: "a.example", fingerprint: "AA", errors: ["nameMismatch", "dateInvalid"], now: now)
    #expect(!result4)
    let result5 = policy.admits(host: "a.example", fingerprint: "AA", errors: ["nameMismatch", "revoked"], now: now)
    #expect(!result5)
  }

  @Test(arguments: [["revoked"], ["invalid"], ["authorityInvalid", "revoked"], []])
  func `fatal errors can never be bypassed`(errors: [String]) {
    var policy = WebKitCertificatePolicy()
    policy.allow(host: "a.example", fingerprint: "AA", errors: errors, now: now)
    #expect(!WebKitCertificatePolicy.overridable(errors))
    #expect(!policy.hasException(host: "a.example", now: now))
    let result6 = policy.admits(host: "a.example", fingerprint: "AA", errors: errors, now: now)
    #expect(!result6)
  }

  @Test func `a proceed expires after a week like Chromium's`() {
    var policy = WebKitCertificatePolicy()
    policy.allow(host: "a.example", fingerprint: "AA", errors: ["dateInvalid"], now: now)
    let later = now.addingTimeInterval(WebKitCertificatePolicy.exceptionLifetime + 1)
    let result7 = policy.admits(host: "a.example", fingerprint: "AA", errors: ["dateInvalid"], now: later)
    #expect(!result7)
  }

  @Test func `a page loaded through a proceed keeps its errors after the proceed expires`() {
    var policy = WebKitCertificatePolicy()
    #expect(policy.bypassedErrors(host: "a.example", fingerprint: "AA") == nil)
    policy.allow(host: "a.example", fingerprint: "AA", errors: ["nameMismatch"], now: now)
    let result8 = policy.admits(host: "a.example", fingerprint: "AA", errors: ["nameMismatch"], now: now)
    #expect(result8)
    let later = now.addingTimeInterval(WebKitCertificatePolicy.exceptionLifetime + 1)
    let result9 = policy.admits(host: "a.example", fingerprint: "AA", errors: ["nameMismatch"], now: later)
    #expect(!result9)
    #expect(policy.bypassedErrors(host: "A.example", fingerprint: "AA") == ["nameMismatch"])
    #expect(policy.bypassedErrors(host: "a.example", fingerprint: nil) == ["nameMismatch"])
    #expect(policy.bypassedErrors(host: "a.example", fingerprint: "BB") == nil)
    #expect(policy.hasException(host: "a.example", now: later))
  }
}

struct DynamicTransportSecurity {
  let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func `a header covers its host and, with includeSubDomains, the hosts below it`() {
    var policy = WebKitCertificatePolicy()
    let result10 = policy.noteHeader("max-age=31536000; includeSubDomains", host: "Bank.example", now: now)
    #expect(result10)
    let result11 = policy.noteHeader("max-age=600", host: "shop.example", now: now)
    #expect(result11)
    #expect(policy.requiresHTTPS(host: "bank.example", now: now))
    #expect(policy.requiresHTTPS(host: "login.bank.example", now: now))
    #expect(policy.requiresHTTPS(host: "shop.example", now: now))
    #expect(!policy.requiresHTTPS(host: "www.shop.example", now: now))
    #expect(!policy.requiresHTTPS(host: "example", now: now))
  }

  @Test func `a trailing dot names the same host for recording and checking`() {
    var policy = WebKitCertificatePolicy()
    let recorded = policy.noteHeader("max-age=600", host: "Example.com.", now: now)
    #expect(recorded)
    #expect(policy.requiresHTTPS(host: "example.com", now: now))
    #expect(policy.requiresHTTPS(host: "EXAMPLE.COM.", now: now))
    let again = policy.noteHeader("max-age=600", host: "example.com", now: now)
    #expect(!again)
  }

  @Test func `a header on a connection trusted without a bypass is recorded even while an exception exists`() {
    var policy = WebKitCertificatePolicy()
    policy.allow(host: "shop.example", fingerprint: "OLD", errors: ["authorityInvalid"], now: now)
    let admitted = policy.admits(host: "shop.example", fingerprint: "OLD", errors: ["authorityInvalid"], now: now)
    #expect(admitted)
    let throughBypass = policy.noteHeader("max-age=600", host: "shop.example", fingerprint: "OLD", now: now)
    #expect(!throughBypass)
    #expect(!policy.requiresHTTPS(host: "shop.example", now: now))
    let onFixedCertificate = policy.noteHeader("max-age=600", host: "shop.example", fingerprint: "FIXED", now: now)
    #expect(onFixedCertificate)
    #expect(policy.requiresHTTPS(host: "shop.example", now: now))
  }

  @Test func `max-age 0 removes the host and entries expire`() {
    var policy = WebKitCertificatePolicy()
    _ = policy.noteHeader("max-age=600", host: "a.example", now: now)
    #expect(!policy.requiresHTTPS(host: "a.example", now: now.addingTimeInterval(601)))
    _ = policy.noteHeader("max-age=600", host: "a.example", now: now)
    let result12 = policy.noteHeader("max-age=0", host: "a.example", now: now)
    #expect(result12)
    #expect(!policy.requiresHTTPS(host: "a.example", now: now))
  }

  @Test(arguments: ["", "includeSubDomains", "max-age", "max-age=abc", "max-age=-5", "max-age=5; max-age=6", "max-age=5; includeSubDomains=1"])
  func `malformed headers are ignored`(header: String) {
    var policy = WebKitCertificatePolicy()
    let result13 = policy.noteHeader(header, host: "a.example", now: now)
    #expect(!result13)
    #expect(!policy.requiresHTTPS(host: "a.example", now: now))
  }

  @Test func `a quoted max-age counts and is capped at a year`() {
    let parsed = WebKitCertificatePolicy.parse("max-age=\"99999999999\"")
    #expect(parsed?.maxAge == WebKitCertificatePolicy.maxAgeLimit)
  }

  @Test func `saved entries survive a reload and expired ones are dropped`() {
    var policy = WebKitCertificatePolicy()
    _ = policy.noteHeader("max-age=600", host: "short.example", now: now)
    _ = policy.noteHeader("max-age=86400; includeSubDomains", host: "long.example", now: now)
    let saved = policy.savedTransportSecurity(now: now.addingTimeInterval(700))
    #expect(saved.keys.sorted() == ["long.example"])
    let reloaded = WebKitCertificatePolicy(transportSecurity: saved)
    #expect(reloaded.requiresHTTPS(host: "www.long.example", now: now.addingTimeInterval(700)))
  }

  @Test func `the list keeps the hosts that expire last when it is full`() {
    var policy = WebKitCertificatePolicy()
    for index in 0...WebKitCertificatePolicy.dynamicHostLimit {
      _ = policy.noteHeader("max-age=\(1000 + index)", host: "h\(index).example", now: now)
    }
    #expect(policy.transportSecurity.count == WebKitCertificatePolicy.dynamicHostLimit)
    #expect(!policy.requiresHTTPS(host: "h0.example", now: now))
    #expect(policy.requiresHTTPS(host: "h\(WebKitCertificatePolicy.dynamicHostLimit).example", now: now))
  }
}
