import WebKit

final class WebKitBlockedCount {
  var count = 0
  var lastURL = ""
  var generation = 0
  var emitQueued = false
  var exemptLoad = false
  var strictURL: URL?
  var strictPageLoading = false
}

final class WebKitPopupPolicy: NSObject, WKNavigationDelegate {
  static let shared = WebKitPopupPolicy()

  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences,
               decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
    if action.targetFrame?.isMainFrame == true, let url = action.request.url { WebKitContentBlocker.shared.configure(preferences, for: url) }
    decisionHandler(.allow, preferences)
  }
}

extension WebKitTab {
  @objc(_webView:contentRuleListWithIdentifier:performedAction:forURL:)
  func contentRuleList(_ webView: WKWebView, identifier: String, performedAction action: NSObject, forURL url: URL) {
    guard webView === self.webView, action.responds(to: NSSelectorFromString("blockedLoad")),
      (action.value(forKey: "blockedLoad") as? Bool) == true
    else { return }
    blocked.count += 1
    blocked.lastURL = url.absoluteString
    guard !blocked.emitQueued else { return }
    blocked.emitQueued = true
    let generation = blocked.generation
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak webView] in
      guard let self, let webView, webView === self.webView, self.blocked.generation == generation else { return }
      self.blocked.emitQueued = false
      self.emit("contentBlocked", ["count": self.blocked.count, "url": self.blocked.lastURL])
    }
  }

  func resetBlocked() {
    blocked.generation += 1
    blocked.emitQueued = false
    let had = blocked.count > 0 || !blocked.lastURL.isEmpty
    blocked.count = 0
    blocked.lastURL = ""
    if had { emit("contentBlocked", ["count": 0, "url": ""]) }
  }

  func applyBlockerPolicy(_ action: WKNavigationAction, preferences: WKWebpagePreferences, in webView: WKWebView) -> Bool {
    guard let url = action.request.url else { return true }
    let exempt = WebKitContentBlocker.shared.configure(preferences, for: url)
    if blocked.strictPageLoading, blocked.strictURL == url {
      blocked.strictPageLoading = false
      return true
    }
    if !exempt, case .reloadAsNewLoad(let passed) = strictProceed(action, url: url) {
      DispatchQueue.main.async { [weak self] in self?.loadURL(passed.absoluteString, userInitiated: true) }
      return false
    }
    if !exempt {
      let source = action.sourceFrame.securityOrigin.host.lowercased()
      if WebKitContentBlocker.shared.strictBlocks(url, initiator: source.isEmpty ? nil : source, store: WebKitHub.shared.stores.id(of: profile)) {
        showStrictBlock(url, in: webView)
        return false
      }
    }
    let redirect = action.responds(to: NSSelectorFromString("_isRedirect")) && (action.value(forKey: "isRedirect") as? Bool) == true
    if redirect && blocked.exemptLoad && !exempt {
      blocked.exemptLoad = false
      let request = action.request
      DispatchQueue.main.async { [weak webView] in webView?.load(request) }
      return false
    }
    if !redirect || exempt { blocked.exemptLoad = exempt }
    return true
  }

  private func strictProceed(_ action: WKNavigationAction, url: URL) -> WebKitStrictProceed.Decision {
    let decision = WebKitStrictProceed.decide(
      shown: blocked.strictURL, showingError: showingError, target: url, fromMainFrame: action.sourceFrame.isMainFrame,
      linkActivated: action.navigationType == .linkActivated)
    guard case .reloadAsNewLoad = decision else { return decision }
    blocked.strictURL = nil
    WebKitContentBlocker.shared.passStrict(url, store: WebKitHub.shared.stores.id(of: profile))
    ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "blockerStrictProceed"]))
    return decision
  }

  private func showStrictBlock(_ url: URL, in webView: WKWebView) {
    blocked.strictURL = url
    blocked.strictPageLoading = true
    safety.interstitial = nil
    safety.errorTitle = "Page blocked"
    errorURL = url
    showingError = true
    webView.loadHTMLString(Self.strictBlockPage(url, token: safety.newToken()), baseURL: url)
    ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "blockerStrictBlocked"]))
  }

  static func strictBlockPage(_ url: URL, token: String) -> String {
    let address = escape(url.absoluteString)
    return """
      <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark"><title>Page blocked</title>
      <style>
      :root{--bg:#fff;--text:#5f6368;--heading:#202124;--accent:#1a73e8;--accent-text:#fff;--border:#dadce0;--danger:#d93025;--well:#f1f3f4}
      @media (prefers-color-scheme: dark){:root{--bg:#202124;--text:#9aa0a6;--heading:#e8eaed;--accent:#8ab4f8;--accent-text:#202124;--border:#5f6368;--danger:#f28b82;--well:#303134}}
      html,body{margin:0;background:var(--bg);color:var(--text)}
      body{font:15px/1.6 -apple-system,system-ui,sans-serif;word-wrap:break-word}
      main{box-sizing:border-box;max-width:600px;margin:14vh auto 0;padding:0 24px}
      svg{display:block;margin:0 0 40px;color:var(--danger)}
      h1{color:var(--heading);font-size:1.6em;font-weight:400;line-height:1.25em;margin:0 0 16px}
      p{margin:0 0 12px}
      .url{display:block;padding:8px 12px;border-radius:8px;background:var(--well);color:var(--heading);font:13px/1.5 ui-monospace,Menlo,monospace;word-break:break-all}
      .buttons{display:flex;flex-direction:row-reverse;justify-content:space-between;align-items:center;margin-top:44px}
      .button{font-family:inherit;display:inline-block;padding:8px 16px;border-radius:20px;font-size:.875em;font-weight:500;text-decoration:none;border:1px solid var(--accent);background:var(--accent);color:var(--accent-text);cursor:default}
      .button.secondary{background:transparent;color:var(--accent);border-color:var(--border)}
      </style></head><body><main>
      <svg width="72" height="72" viewBox="0 0 72 72" aria-hidden="true"><path fill="currentColor" d="M36 4 8 14v20c0 17 12 29 28 34 16-5 28-17 28-34V14zm0 7 22 8v15c0 13-9 23-22 28-13-5-22-15-22-28V19zm-3 9h6v20h-6zm0 24h6v6h-6z"/></svg>
      <h1>Page blocked</h1>
      <p>uBlock Origin has prevented the following page from loading:</p>
      <span class="url">\(address)</span>
      <div class="buttons"><a class="button" id="back" href="\(pageAction("back", token: token))">Go back</a>
      <a class="button secondary" id="proceed" href="\(address)">Proceed</a></div>
      </main></body></html>
      """
  }

  func loadWhenBlockerReady(_ url: String, in view: WebKitWebView) {
    WebKitContentBlocker.shared.whenReady(within: 1) { [weak self, weak view] in
      guard let self, let view, self.webView === view, view.url == nil, !view.isLoading else { return }
      self.loadURL(url, userInitiated: false)
    }
  }
}
