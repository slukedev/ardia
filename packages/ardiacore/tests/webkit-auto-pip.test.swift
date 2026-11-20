import Foundation
import Testing

struct AutoPictureInPictureRule {
  typealias Action = WebKitAutoPictureInPicture.Action

  @Test func `leaving a playing tab opens once and returning closes once`() {
    var rule = WebKitAutoPictureInPicture()
    #expect(rule.sight(false, enabled: true, playing: true) == .open)
    #expect(rule.sight(false, enabled: true, playing: true) == .none)
    #expect(rule.sight(true, enabled: true, playing: true) == .close)
    #expect(rule.sight(true, enabled: true, playing: true) == .none)
  }

  @Test func `nothing opens with the setting off or nothing playing`() {
    var off = WebKitAutoPictureInPicture()
    #expect(off.sight(false, enabled: false, playing: true) == .none)
    #expect(off.sight(true, enabled: false, playing: true) == .none)
    var idle = WebKitAutoPictureInPicture()
    #expect(idle.sight(false, enabled: true, playing: false) == .none)
    #expect(idle.sight(true, enabled: true, playing: false) == .none)
  }

  @Test func `a picture in picture the person closed doesn't reopen while away`() {
    var rule = WebKitAutoPictureInPicture()
    #expect(rule.sight(false, enabled: true, playing: true) == .open)
    rule.reported(active: true)
    rule.reported(active: false)
    #expect(rule.sight(false, enabled: true, playing: true) == .none)
    #expect(rule.sight(true, enabled: true, playing: true) == .none)
    #expect(rule.sight(false, enabled: true, playing: true) == .open)
  }

  @Test func `returning ends one the page reports open even with the setting off`() {
    var rule = WebKitAutoPictureInPicture()
    rule.reported(active: true)
    #expect(rule.sight(false, enabled: false, playing: true) == .none)
    #expect(rule.sight(true, enabled: false, playing: true) == .close)
  }

  @Test func `leave and return before the page reports still pair up`() {
    var rule = WebKitAutoPictureInPicture()
    #expect(rule.sight(false, enabled: true, playing: true) == .open)
    #expect(rule.sight(true, enabled: true, playing: true) == .close)
    rule.reported(active: false)
    #expect(rule.sight(false, enabled: true, playing: true) == .open)
  }
}
