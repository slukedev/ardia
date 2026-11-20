import AppKit
import WebKit

final class WebKitFinder: NSObject {
  private struct Options: OptionSet {
    let rawValue: UInt
    static let caseInsensitive = Options(rawValue: 1 << 0)
    static let backwards = Options(rawValue: 1 << 3)
    static let wrapAround = Options(rawValue: 1 << 4)
    static let showHighlight = Options(rawValue: 1 << 7)
    static let determineMatchIndex = Options(rawValue: 1 << 9)
  }

  private typealias FindString = @convention(c) (AnyObject, Selector, NSString, UInt, UInt) -> Void
  private typealias SetDelegate = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
  private typealias HideFindUI = @convention(c) (AnyObject, Selector) -> Void

  private static let findSelector = NSSelectorFromString("_findString:options:maxCount:")
  private static let setDelegateSelector = NSSelectorFromString("_setFindDelegate:")
  private static let delegateSelector = NSSelectorFromString("_findDelegate")
  private static let hideSelector = NSSelectorFromString("_hideFindUI")
  static let native = [findSelector, setDelegateSelector, delegateSelector, hideSelector].allSatisfy { WKWebView.instancesRespond(to: $0) }
  static let maxCount: UInt = 10_000

  weak var tab: WebKitTab?
  private(set) var text = ""
  private var count = 0
  private var active = 0
  private var counted = false

  func find(_ query: String, forward: Bool) {
    guard let view = tab?.webView else { return }
    if query.isEmpty { return clear(in: view, reporting: true) }
    let refined = query != text && !text.isEmpty
    let fresh = query != text
    text = query
    guard Self.native else { return findWithoutSPI(query, forward: forward, fresh: fresh, in: view) }
    if !counted {
      counted = true
      ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "nativeFind"]))
    }
    adopt(view)
    guard refined else { return findNatively(query, forward: forward, in: view) }
    view.evaluateJavaScript("(() => { const s = getSelection(); if (s.rangeCount) s.collapseToStart(); })()", in: nil, in: WebKitHub.world) { [weak self] _ in
      guard let self, self.text == query, self.tab?.webView === view else { return }
      self.findNatively(query, forward: forward, in: view)
    }
  }

  private func findNatively(_ query: String, forward: Bool, in view: WebKitWebView) {
    var options: Options = [.caseInsensitive, .wrapAround, .showHighlight, .determineMatchIndex]
    if !forward { options.insert(.backwards) }
    let call = unsafeBitCast(view.method(for: Self.findSelector), to: FindString.self)
    call(view, Self.findSelector, query as NSString, options.rawValue, Self.maxCount)
  }

  func stop(clearSelection: Bool) {
    guard let view = tab?.webView else { return reset() }
    clear(in: view, reporting: false)
    if clearSelection { view.evaluateJavaScript("getSelection().removeAllRanges()", in: nil, in: WebKitHub.world) { _ in } }
  }

  func reset() {
    text = ""
    count = 0
    active = 0
    counted = false
  }

  private func clear(in view: WebKitWebView, reporting: Bool) {
    reset()
    if Self.native {
      unsafeBitCast(view.method(for: Self.hideSelector), to: HideFindUI.self)(view, Self.hideSelector)
    }
    if reporting { report(count: 0, active: 0) }
  }

  private func adopt(_ view: WebKitWebView) {
    if view.perform(Self.delegateSelector)?.takeUnretainedValue() === self { return }
    unsafeBitCast(view.method(for: Self.setDelegateSelector), to: SetDelegate.self)(view, Self.setDelegateSelector, self)
  }

  private func report(count: Int, active: Int) {
    self.count = count
    self.active = count > 0 ? min(max(active, 1), count) : 0
    tab?.emit("find", ["count": self.count, "active": self.active, "final": true])
  }

  @objc(_webView:didFindMatches:forString:withMatchIndex:)
  func webView(_ webView: WKWebView, didFindMatches matches: UInt, for string: String, withMatchIndex index: Int) {
    guard webView === tab?.webView, string == text else { return }
    let found = Int(min(matches, Self.maxCount))
    let ordinal = index >= 0 && index < found ? index + 1 : active
    report(count: max(found, 1), active: ordinal)
  }

  @objc(_webView:didCountMatches:forString:)
  func webView(_ webView: WKWebView, didCountMatches matches: UInt, for string: String) {
    guard webView === tab?.webView, string == text, matches > 0 else { return }
    report(count: Int(min(matches, Self.maxCount)), active: active)
  }

  @objc(_webView:didFailToFindString:)
  func webView(_ webView: WKWebView, didFailToFind string: String) {
    guard webView === tab?.webView, string == text else { return }
    report(count: 0, active: 0)
  }

  private func findWithoutSPI(_ query: String, forward: Bool, fresh: Bool, in view: WebKitWebView) {
    if !counted {
      counted = true
      ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "fallbackFind"]))
    }
    let configuration = WKFindConfiguration()
    configuration.backwards = !forward
    configuration.caseSensitive = false
    configuration.wraps = true
    view.evaluateJavaScript("window.__ardia ? window.__ardia.count(\(WebKitTab.jsString(query))) : 0", in: nil, in: WebKitHub.world) { [weak self] value in
      guard let self, self.text == query, self.tab?.webView === view else { return }
      let total = ((try? value.get()) as? NSNumber)?.intValue ?? 0
      view.find(query, configuration: configuration) { [weak self] result in
        guard let self, self.text == query, self.tab?.webView === view else { return }
        guard result.matchFound else { return self.report(count: 0, active: 0) }
        let count = max(total, 1)
        var next = self.active
        if fresh || next == 0 { next = 1 } else { next = forward ? next % count + 1 : (next + count - 2) % count + 1 }
        self.report(count: count, active: next)
      }
    }
  }
}

extension WebKitTab {
  func find(_ text: String, forward: Bool, findNext: Bool) {
    finder.tab = self
    finder.find(text, forward: forward)
  }

  func stopFinding(_ clearSelection: Bool) {
    finder.tab = self
    finder.stop(clearSelection: clearSelection)
  }
}
