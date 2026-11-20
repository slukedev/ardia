import Foundation
import Testing

private let blocked = URL(string: "http://127.0.0.1:9342/?usid=1&utid=2")!

@Suite struct StrictBlockProceed {
  @Test func `Proceed on the block page starts a new load, so the error page and its title end like a certificate Proceed`() {
    let decision = WebKitStrictProceed.decide(shown: blocked, showingError: true, target: blocked, fromMainFrame: true, linkActivated: true)
    #expect(decision == .reloadAsNewLoad(blocked))
  }

  @Test func `only a main-frame link click to the blocked address on the showing block page is a pass`() {
    let other = URL(string: "http://127.0.0.1:9342/other")!
    #expect(WebKitStrictProceed.decide(shown: nil, showingError: true, target: blocked, fromMainFrame: true, linkActivated: true) == .notAPass)
    #expect(WebKitStrictProceed.decide(shown: blocked, showingError: false, target: blocked, fromMainFrame: true, linkActivated: true) == .notAPass)
    #expect(WebKitStrictProceed.decide(shown: blocked, showingError: true, target: other, fromMainFrame: true, linkActivated: true) == .notAPass)
    #expect(WebKitStrictProceed.decide(shown: blocked, showingError: true, target: blocked, fromMainFrame: false, linkActivated: true) == .notAPass)
    #expect(WebKitStrictProceed.decide(shown: blocked, showingError: true, target: blocked, fromMainFrame: true, linkActivated: false) == .notAPass)
  }
}
