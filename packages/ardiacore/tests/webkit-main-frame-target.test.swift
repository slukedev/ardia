import Foundation
import Testing

private let elsewhere = URL(string: "https://evil.test/204")!

@Suite struct MainFrameTargetForSignIn {
  @Test func `a navigation that commits keeps its target until the commit`() {
    var target = WebKitMainFrameTarget()
    target.began(elsewhere)
    target.decided(allowed: true)
    target.responded(status: 200, displays: true)
    #expect(target.url == elsewhere)
    target.ended()
    #expect(target.url == nil)
  }

  @Test(arguments: [204, 205])
  func `a main-frame response with no content leaves no target behind`(_ status: Int) {
    var target = WebKitMainFrameTarget()
    target.began(elsewhere)
    target.decided(allowed: true)
    target.responded(status: status, displays: true)
    #expect(target.url == nil)
  }

  @Test func `a cancelled navigation leaves no target behind`() {
    var target = WebKitMainFrameTarget()
    target.began(elsewhere)
    target.decided(allowed: false)
    #expect(target.url == nil)
  }

  @Test func `a response that becomes a download leaves no target behind`() {
    var target = WebKitMainFrameTarget()
    target.began(elsewhere)
    target.decided(allowed: true)
    target.responded(status: 200, displays: false)
    #expect(target.url == nil)
  }
}
