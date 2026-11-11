import Foundation
import Testing

@testable import ArdiaVaultsCore

struct ChromeProfilesTests {
  @Test(arguments: ["", "not json", "[]", #"{"browser":{}}"#, #"{"profile":"x"}"#])
  func `a Local State without profiles doesn't parse`(text: String) {
    #expect(ChromeProfiles.parse(Data(text.utf8)) == nil)
  }

  @Test(arguments: ["", ".", "..", "../Default", "Default/../x", ".hidden", "-flag", "Profile\n1", String(repeating: "a", count: 65)])
  func `unsafe directory names are refused`(name: String) {
    #expect(ChromeProfiles.isDirectoryName(name) == false)
  }

  @Test func `profiles with unsafe directory names are left out`() throws {
    let text = #"{"profile":{"info_cache":{"../evil":{"name":"x","user_name":"a@b.c"},"Default":{"name":"Me"}}}}"#
    let state = try #require(ChromeProfiles.parse(Data(text.utf8)))
    #expect(state.profiles.map(\.directory) == ["Default"])
  }

  @Test func `the fixture lists both profiles in Chrome's order`() throws {
    let state = try #require(ChromeProfiles.parse(Data(contentsOf: Fixture.chrome.appendingPathComponent("Local State"))))
    #expect(state.lastUsed == "Default")
    #expect(state.profiles == [
      ChromeProfile(directory: "Default", name: "Person 1", email: "test@example.com", gaiaName: "Test User"),
      ChromeProfile(directory: "Profile 1", name: "Work", email: nil, gaiaName: nil),
    ])
  }

  @Test func `profiles missing from the order follow it, Default first`() throws {
    let text = #"{"profile":{"info_cache":{"Profile 10":{},"Profile 2":{},"Default":{}},"profiles_order":["Profile 10"]}}"#
    let state = try #require(ChromeProfiles.parse(Data(text.utf8)))
    #expect(state.profiles.map(\.directory) == ["Profile 10", "Default", "Profile 2"])
    #expect(state.profiles.map(\.name) == ["Profile 10", "Default", "Profile 2"])
  }

  private func state(lastUsed: String?) -> ChromeLocalState {
    ChromeLocalState(profiles: [
      ChromeProfile(directory: "Default", name: "Home"),
      ChromeProfile(directory: "Profile 1", name: "Work", email: "work@example.com"),
      ChromeProfile(directory: "Profile 2", name: "School", email: "school@example.com"),
    ], lastUsed: lastUsed)
  }

  @Test func `nothing is chosen from no profiles`() {
    #expect(ChromeProfiles.choose(ChromeLocalState(profiles: [], lastUsed: "Default"), preferred: "Default") == nil)
  }

  @Test func `a preference for a profile that's gone falls back`() {
    #expect(ChromeProfiles.choose(state(lastUsed: "Profile 2"), preferred: "Profile 9")?.directory == "Profile 2")
  }

  @Test func `the chosen profile wins`() {
    #expect(ChromeProfiles.choose(state(lastUsed: "Profile 2"), preferred: "Profile 1")?.directory == "Profile 1")
  }

  @Test func `the last used profile wins when it has a Google account`() {
    #expect(ChromeProfiles.choose(state(lastUsed: "Profile 2"), preferred: nil)?.directory == "Profile 2")
  }

  @Test func `a last used profile without an account gives way to one with an account`() {
    #expect(ChromeProfiles.choose(state(lastUsed: "Default"), preferred: nil)?.directory == "Profile 1")
  }

  @Test func `with no account anywhere the last used profile is chosen`() {
    let local = ChromeLocalState(profiles: [ChromeProfile(directory: "Default", name: "A"), ChromeProfile(directory: "Profile 1", name: "B")],
                                 lastUsed: "Profile 1")
    #expect(ChromeProfiles.choose(local, preferred: nil)?.directory == "Profile 1")
  }
}
