import Foundation
import Testing

@testable import ArdiaVaultsCore

struct VaultPendingItemsTests {
  let now = Date(timeIntervalSince1970: 5_000_000)

  func item(_ id: String, url: String = "https://example.com", username: String = "bob", pending: Bool? = nil) -> VaultItem {
    var item = VaultItem(provider: "google", id: id, title: "example.com", username: username, urls: [url])
    item.pending = pending
    return item
  }

  func save(_ id: String, url: String = "https://example.com", username: String = "bob", password: String? = "new-pass", age: TimeInterval = 10)
    -> VaultPendingSave
  {
    VaultPendingSave(item: item(id, url: url, username: username), password: password, since: now.addingTimeInterval(-age).timeIntervalSince1970)
  }

  @Test func `a save the list doesn't show yet stays at the end of the list, marked pending`() {
    let listed = [item("web.other", url: "https://other.example", username: "ann")]
    let result = VaultPendingItems.reconcile(listed, passwords: ["web.other": "x"], pending: [save("web.saved")], now: now)
    #expect(result.items.map(\.id) == ["web.other", "web.saved"])
    #expect(result.items.map(\.pending) == [nil, true])
    #expect(result.pending.map(\.item.id) == ["web.saved"])
    #expect(result.carried.isEmpty)
  }

  @Test func `the same id in the list ends the pending state and carries the password the list lacks`() {
    let listed = [item("op.123")]
    let result = VaultPendingItems.reconcile(listed, passwords: [:], pending: [save("op.123")], now: now)
    #expect(result.items == listed)
    #expect(result.pending.isEmpty)
    #expect(result.carried == ["op.123": "new-pass"])
  }

  @Test func `the same id with a listed password keeps the list's password`() {
    let result = VaultPendingItems.reconcile([item("bw.1")], passwords: ["bw.1": "from-list"], pending: [save("bw.1")], now: now)
    #expect(result.pending.isEmpty)
    #expect(result.carried.isEmpty)
  }

  @Test func `Google listing the login under its own URL still reconciles by host and username`() {
    let listed = [item("web.google", url: "https://WWW.Example.com/login", username: "Bob")]
    let result = VaultPendingItems.reconcile(listed, passwords: ["web.google": "new-pass"], pending: [save("web.ours")], now: now)
    #expect(result.items.map(\.id) == ["web.google"])
    #expect(result.items.allSatisfy { $0.pending == nil })
    #expect(result.pending.isEmpty)
  }

  @Test func `an old login with the old password stays hidden behind the pending update`() {
    let listed = [item("web.old"), item("web.else", url: "https://else.example")]
    let result = VaultPendingItems.reconcile(listed, passwords: ["web.old": "old-pass", "web.else": "x"], pending: [save("web.new")], now: now)
    #expect(result.items.map(\.id) == ["web.else", "web.new"])
    #expect(result.pending.count == 1)
  }

  @Test func `a listed login with no password and another id doesn't count as the saved one`() {
    let result = VaultPendingItems.reconcile([item("op.old")], passwords: [:], pending: [save("op.new")], now: now)
    #expect(result.pending.map(\.item.id) == ["op.new"])
    #expect(result.items.map(\.id) == ["op.new"])
  }

  @Test func `a pending save with no password known matches on host and username alone`() {
    let result = VaultPendingItems.reconcile([item("web.listed")], passwords: ["web.listed": "anything"], pending: [save("web.saved", password: nil)], now: now)
    #expect(result.pending.isEmpty)
    #expect(result.items.map(\.id) == ["web.listed"])
  }

  @Test(arguments: [("https://login.example.com", "bob"), ("https://example.com", "ann"), ("https://example.org", "bob")])
  func `another host, a subdomain or another username is a different login`(url: String, username: String) {
    let listed = [item("web.listed", url: url, username: username)]
    let result = VaultPendingItems.reconcile(listed, passwords: ["web.listed": "new-pass"], pending: [save("web.saved")], now: now)
    #expect(result.pending.map(\.item.id) == ["web.saved"])
    #expect(result.items.map(\.id) == ["web.listed", "web.saved"])
  }

  @Test func `a save never reconciled is dropped after a day, its password with it`() {
    let young = save("web.young", url: "https://young.example", age: VaultPendingItems.lifetime - 1)
    let old = save("web.old", url: "https://old.example", age: VaultPendingItems.lifetime)
    let result = VaultPendingItems.reconcile([], passwords: [:], pending: [young, old], now: now)
    #expect(result.pending.map(\.item.id) == ["web.young"])
    #expect(result.items.map(\.id) == ["web.young"])
  }

  @Test func `an expired save no longer hides the login it was replacing`() {
    let result = VaultPendingItems.reconcile([item("web.old")], passwords: ["web.old": "old"], pending: [save("web.new", age: 90_000)], now: now)
    #expect(result.items.map(\.id) == ["web.old"])
    #expect(result.pending.isEmpty)
  }

  @Test func `a pending save with a URL that has no host only matches its own id`() {
    let odd = save("web.odd", url: "not a url")
    let listed = [item("web.listed", url: "not a url")]
    let result = VaultPendingItems.reconcile(listed, passwords: ["web.listed": "new-pass"], pending: [odd], now: now)
    #expect(result.pending.map(\.item.id) == ["web.odd"])
  }

  @Test func `items already marked pending in the list are ignored as listed logins`() {
    let stale = item("web.saved", pending: true)
    let result = VaultPendingItems.reconcile([stale], passwords: [:], pending: [save("web.saved")], now: now)
    #expect(result.items.map(\.id) == ["web.saved"])
    #expect(result.pending.count == 1)
  }

  @Test func `saving the same login again replaces the earlier pending save`() {
    let first = save("web.a", password: "one", age: 30)
    let second = save("web.b", url: "https://www.example.com/", username: "BOB", password: "two", age: 0)
    let other = save("web.c", url: "https://other.example")
    let pending = VaultPendingItems.adding(second, to: [first, other])
    #expect(pending.map(\.item.id) == ["web.c", "web.b"])
    #expect(pending.last?.password == "two")
  }

  @Test func `removing a failed save leaves the others`() {
    let pending = VaultPendingItems.removing("web.a", from: [save("web.a"), save("web.b", url: "https://b.example")])
    #expect(pending.map(\.item.id) == ["web.b"])
  }
}
