import Foundation
import Testing

private let plain = #"{"action":{"type":"block"},"trigger":{"url-filter":"/plain/"}}"#
private let allow = #"{"action":{"type":"ignore-previous-rules"},"trigger":{"url-filter":"/allowed/"}}"#

private func group(_ name: String) -> String {
  #"{"action":{"type":"block"},"trigger":{"url-filter":"/\#(name)/"}},{"action":{"type":"ignore-previous-rules"},"trigger":{"url-filter":"\#(name)-excluded"}}"#
}

private func rules(in list: String) throws -> [[String: Any]] {
  try #require(JSONSerialization.jsonObject(with: Data(list.utf8)) as? [[String: Any]])
}

private func filters(in list: String) throws -> [String] {
  try rules(in: list).compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String }
}

@Suite struct ExclusionGroupPlacement {
  let lists = WebKitRulePacker.lists(
    texts: [
      ["b10\t\(plain)", "p10.0.1\t\(group("early"))", "p10.1.0\t\(group("clashing"))", "p10.0.0\t\(group("first"))", "a30\t\(allow)"].joined(separator: "\n"),
    ],
    user: [])

  @Test func `a plain block never shares a list with an exclusion group, so no exclusion can undo it`() throws {
    let holding = try lists.filter { try filters(in: $0).contains("/plain/") }
    #expect(holding.count == 1)
    for list in holding {
      let found = try filters(in: list)
      #expect(!found.contains { $0.hasSuffix("-excluded") })
    }
  }

  @Test func `groups the converter put in different sets get different lists`() throws {
    let early = try lists.firstIndex { try filters(in: $0).contains("/early/") }
    let clashing = try lists.firstIndex { try filters(in: $0).contains("/clashing/") }
    #expect(early != nil && clashing != nil && early != clashing)
  }

  @Test func `groups in one set keep the converter's rank order`() throws {
    let list = try #require(try lists.first { try filters(in: $0).contains("/early/") })
    let found = try filters(in: list)
    let first = try #require(found.firstIndex(of: "first-excluded"))
    let early = try #require(found.firstIndex(of: "/early/"))
    #expect(first < early)
  }

  @Test func `every network list ends with the allow rules and the top-document pass`() throws {
    for list in lists {
      let found = try filters(in: list)
      #expect(found.suffix(2) == ["/allowed/", ".*"])
    }
  }
}

@Suite struct UncompiledRuleSearch {
  private func search(_ count: Int, bad: Set<Int>) -> WebKitRuleBisect {
    var bisect = WebKitRuleBisect(count: count)
    while let range = bisect.next {
      let compiled = bad.isDisjoint(with: range)
      bisect.record(range, compiled: compiled)
    }
    return bisect
  }

  @Test(arguments: [(1, Set([0])), (8, Set([2, 5])), (1000, Set([0, 499, 999])), (64, Set<Int>())])
  func `finds exactly the rules that don't compile`(count: Int, bad: Set<Int>) {
    let found = search(count, bad: bad)
    #expect(found.rejected == bad.sorted())
    #expect(found.attempts <= found.limit)
  }

  @Test func `stops at its limit and leaves every untested rule out`() {
    let found = search(1000, bad: Set(0..<1000))
    #expect(found.attempts == found.limit)
    #expect(found.rejected.count == 1000)
  }

  @Test func `nothing to search is finished at once`() {
    let found = WebKitRuleBisect(count: 0)
    #expect(found.finished)
    #expect(found.rejected.isEmpty)
  }
}
