import Foundation
import Testing

private func parsedOnUtilityQueue(_ text: String) async -> WebKitUserFilters {
  await withCheckedContinuation { done in
    DispatchQueue.global(qos: .utility).async { done.resume(returning: WebKitUserFilters.parse(text)) }
  }
}

@Suite struct UserFilterParsing {
  @Test func `a filter nested 5000 deep is rejected without overflowing a background queue's stack`() async {
    let nested = "example.com##div" + String(repeating: ":if(", count: 5000) + "a" + String(repeating: ")", count: 5000)
    let deep = await parsedOnUtilityQueue(nested)
    #expect(deep.accepted == 0)
    #expect(deep.rejected == 1)
  }

  @Test func `a shallow :if() filter still parses`() async {
    let kept = await parsedOnUtilityQueue("example.com##div:if(span:has-text(ad))")
    #expect(kept.accepted == 1)
    #expect(kept.hide["example.com"]?.count == 1)
  }

  @Test func `a selector or :style() that could close its CSS rule or load a URL is rejected`() {
    let breakout = WebKitUserFilters.parse(
      "example.com##div}body{background:red\nexample.com##.ad:style(color:red}*{x:y)\nexample.com##.ad:style(background:URL(https://t.example/p))")
    #expect(breakout.accepted == 0)
    #expect(breakout.rejected == 3)
  }

  @Test func `a plain :style() declaration still parses`() {
    let style = WebKitUserFilters.parse("example.com##.ad:style(opacity: 0.5 !important)")
    #expect(style.accepted == 1)
    #expect(style.hide["example.com"]?.count == 1)
  }
}
