import Foundation
import Testing

@testable import ArdiaVaultsCore

struct ChromeCryptoTests {
  @Test func `an empty secret derives no key`() {
    #expect(ChromeCrypto.deriveKey(secret: Data()) == nil)
  }

  @Test func `the wrong key decrypts nothing`() throws {
    let key = try Fixture.key
    let other = try #require(ChromeCrypto.deriveKey(secret: Data("some-other-secret".utf8)))
    let sealed = try #require(ChromeCrypto.encrypt("correct horse", key: key))
    #expect(ChromeCrypto.decrypt(sealed, key: other) == nil)
  }

  @Test(arguments: [Data(), Data("v10".utf8), Data("v11abcdefghijklmnop".utf8), Data("v10short".utf8), Data("plain text value".utf8)])
  func `values that are not whole v10 blocks decrypt to nothing`(value: Data) throws {
    #expect(ChromeCrypto.decrypt(value, key: try Fixture.key) == nil)
  }

  @Test func `a key of the wrong length decrypts nothing`() throws {
    let sealed = try #require(ChromeCrypto.encrypt("x", key: try Fixture.key))
    #expect(ChromeCrypto.decrypt(sealed, key: Data(repeating: 1, count: 32)) == nil)
  }

  @Test(arguments: ["", "abc", String(repeating: "g", count: 32), String(repeating: "0", count: 31), String(repeating: "0", count: 34)])
  func `malformed key text is refused`(text: String) {
    #expect(ChromeCrypto.key(hex: text) == nil)
  }

  @Test func `the fixture secret derives Chrome's key`() throws {
    #expect(ChromeCrypto.hex(try Fixture.key) == "1cd38c9a18a23efe534eace571303ee4")
  }

  @Test func `a key survives its text form`() throws {
    let key = try Fixture.key
    #expect(ChromeCrypto.key(hex: ChromeCrypto.hex(key)) == key)
  }

  @Test(arguments: ["correct horse", "pässwörd 🔑", "", String(repeating: "x", count: 16)])
  func `encrypted passwords round trip`(password: String) throws {
    let key = try Fixture.key
    let sealed = try #require(ChromeCrypto.encrypt(password, key: key))
    #expect(sealed.prefix(3) == Data("v10".utf8))
    #expect(ChromeCrypto.decrypt(sealed, key: key) == password)
  }
}

struct ChromeTimeTests {
  @Test(arguments: [Int64(0), -5, ChromeTime.unixEpochOffset, ChromeTime.unixEpochOffset - 1])
  func `times at or before 1970 have no date`(value: Int64) {
    #expect(ChromeTime.milliseconds(value) == nil)
  }

  @Test func `Chrome time converts to Unix milliseconds`() {
    #expect(ChromeTime.milliseconds(13_400_694_400_000_000) == 1_756_220_800_000)
  }

  @Test func `a date round trips through Chrome time`() {
    let date = Date(timeIntervalSince1970: 1_788_220_800)
    #expect(ChromeTime.milliseconds(ChromeTime.chrome(date)) == 1_788_220_800_000)
  }
}
