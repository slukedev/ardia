import Foundation

struct WebKitMainFrameTarget: Sendable {
  static let statusesWithoutPage: Set<Int> = [204, 205]

  private(set) var url: URL?

  mutating func began(_ url: URL) { self.url = url }

  mutating func decided(allowed: Bool) {
    if !allowed { url = nil }
  }

  mutating func responded(status: Int, displays: Bool) {
    if !displays || Self.statusesWithoutPage.contains(status) { url = nil }
  }

  mutating func ended() { url = nil }
}
