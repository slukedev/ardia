import AppKit
import WebKit

struct WebKitErrorPage {
  let title: String
  let html: String
}

extension WebKitTab {
  private struct NetError {
    let heading: String
    let summary: String
    let code: String
    let suggestions: String?
  }

  private static let swatches: [String: (Double, Double, Double)] = [
    "plum": (0xC0, 0x7A, 0x98), "blue": (0x46, 0x91, 0xC3), "purple": (0x78, 0x73, 0xAF), "pink": (0xD3, 0x7B, 0x8B),
    "red": (0xC1, 0x57, 0x5C), "orange": (0xD8, 0x72, 0x49), "yellow": (0xE3, 0xAC, 0x38), "neutral": (0x8E, 0x8E, 0x93),
  ]

  private static let offlineCodes: Set<Int> = [NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff]

  static func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
  }

  static func pageAction(_ name: String, token: String) -> String { "\(pageActionScheme)://page/\(name)/\(token)" }

  private static func netError(_ error: NSError, host: String, url: URL) -> NetError {
    let site = "<strong>\(escape(host))</strong>"
    let unreachable = "This site can’t be reached"
    let dnsTips = "Checking the proxy, firewall, and DNS configuration", proxyTips = "Checking the proxy and the firewall"
    let broken = "This page isn’t working"
    guard error.domain == NSURLErrorDomain else {
      return NetError(heading: broken, summary: "\(site) sent an invalid response.", code: "ERR_FAILED", suggestions: nil)
    }
    switch error.code {
    case NSURLErrorCannotFindHost:
      return NetError(heading: unreachable, summary: "\(site)’s server IP address could not be found.", code: "ERR_NAME_NOT_RESOLVED", suggestions: dnsTips)
    case NSURLErrorDNSLookupFailed:
      return NetError(heading: unreachable, summary: "\(site)’s server IP address could not be found.", code: "ERR_NAME_RESOLUTION_FAILED", suggestions: dnsTips)
    case NSURLErrorCannotConnectToHost:
      return NetError(heading: unreachable, summary: "\(site) refused to connect.", code: "ERR_CONNECTION_REFUSED", suggestions: proxyTips)
    case NSURLErrorTimedOut:
      return NetError(heading: unreachable, summary: "\(site) took too long to respond.", code: "ERR_CONNECTION_TIMED_OUT", suggestions: proxyTips)
    case NSURLErrorNetworkConnectionLost:
      return NetError(heading: unreachable, summary: "The connection was reset.", code: "ERR_CONNECTION_RESET", suggestions: proxyTips)
    case NSURLErrorHTTPTooManyRedirects:
      return NetError(heading: broken, summary: "\(site) redirected you too many times.", code: "ERR_TOO_MANY_REDIRECTS", suggestions: nil)
    case NSURLErrorBadServerResponse:
      return NetError(heading: broken, summary: "\(site) sent an invalid response.", code: "ERR_INVALID_RESPONSE", suggestions: nil)
    case NSURLErrorZeroByteResource:
      return NetError(heading: broken, summary: "\(site) didn’t send any data.", code: "ERR_EMPTY_RESPONSE", suggestions: nil)
    case NSURLErrorSecureConnectionFailed, NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired:
      let code = error.code == NSURLErrorSecureConnectionFailed ? "ERR_SSL_PROTOCOL_ERROR" : "ERR_BAD_SSL_CLIENT_AUTH_CERT"
      return NetError(heading: "This site can’t provide a secure connection", summary: "\(site) sent an invalid response.", code: code, suggestions: nil)
    case NSURLErrorFileDoesNotExist:
      return NetError(heading: "Your file couldn’t be accessed", summary: "It may have been moved, edited, or deleted.", code: "ERR_FILE_NOT_FOUND", suggestions: nil)
    case NSURLErrorNoPermissionsToReadFile:
      return NetError(heading: "Access to the file was denied", summary: "The file at \(site) is not readable. It may have been removed, moved, or file permissions may be preventing access.",
                      code: "ERR_ACCESS_DENIED", suggestions: nil)
    case NSURLErrorUnsupportedURL:
      return NetError(heading: unreachable, summary: "\(site) uses an unsupported protocol.", code: "ERR_UNKNOWN_URL_SCHEME", suggestions: nil)
    default:
      let address = "<strong>\(escape(url.absoluteString))</strong>"
      return NetError(heading: unreachable, summary: "The webpage at \(address) might be temporarily down or it may have moved permanently to a new web address.",
                      code: "ERR_FAILED", suggestions: nil)
    }
  }

  static func errorPage(_ url: URL, _ error: NSError, pageColor: String?, token: String) -> WebKitErrorPage {
    let host = url.host ?? url.absoluteString
    if error.domain == NSURLErrorDomain, offlineCodes.contains(error.code) { return offlinePage(host: host, pageColor: pageColor, token: token) }
    let failure = netError(error, host: host, url: url)
    let suggestions = failure.suggestions.map { "<p>Try:</p><ul><li>Checking the connection</li><li>\($0)</li></ul>" } ?? ""
    let html = """
      <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark"><title>\(escape(host))</title>
      <style>
      :root{--bg:#fff;--text:#5f6368;--heading:#202124;--button:#1a73e8;--button-text:#fff}
      @media (prefers-color-scheme: dark){:root{--bg:#202124;--text:#9aa0a6;--heading:#e8eaed;--button:#8ab4f8;--button-text:#202124}}
      html,body{margin:0;background:var(--bg);color:var(--text)}
      body{font:15px/1.6 -apple-system,system-ui,sans-serif;word-wrap:break-word}
      main{box-sizing:border-box;max-width:600px;margin:14vh auto 0;padding:0 24px}
      svg{display:block;margin:0 0 40px}
      h1{color:var(--heading);font-size:1.6em;font-weight:400;line-height:1.25em;margin:0 0 16px}
      p{margin:0 0 4px}ul{margin:4px 0 0;padding-left:20px}
      .code{display:block;margin-top:12px;font-size:.86667em;text-transform:uppercase}
      .button{display:inline-block;margin-top:44px;padding:8px 16px;border-radius:20px;background:var(--button);color:var(--button-text);font-size:.875em;font-weight:500;text-decoration:none}
      </style></head><body><main>
      <svg width="72" height="72" viewBox="0 0 72 72" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="4" d="M16 6h28l16 16v44H16z"/><path fill="currentColor" d="M27 36h5v5h-5zm13 0h5v5h-5zM26 53c6-6 14-6 20 0l-3 3c-4-4-10-4-14 0z"/></svg>
      <h1>\(failure.heading)</h1><p>\(failure.summary)</p>\(suggestions)<span class="code">\(failure.code)</span>
      <a class="button" id="reload" href="\(pageAction("reload", token: token))">Reload</a>
      </main></body></html>
      """
    return WebKitErrorPage(title: host, html: html)
  }

  private static func offlinePage(host: String, pageColor: String?, token: String) -> WebKitErrorPage {
    let html = """
      <!doctype html><html\(pageColor == "incognito" ? " data-theme=\"dark\"" : "") style="\(themeVariables(pageColor))"><head><meta charset="utf-8"><meta name="color-scheme" content="light dark"><title>\(escape(host)) · No internet</title>
      <style>
      :root{--bg:light-dark(#f2f0df,#182d24);--text:light-dark(#182d24,#f2f0df);--text-2:light-dark(rgba(24,45,36,.68),rgba(242,240,223,.68));--text-3:light-dark(rgba(24,45,36,.46),rgba(242,240,223,.45));--primary:light-dark(#203f32,#d3deb5);--primary-text:light-dark(#f2f0df,#182d24);color-scheme:light dark}
      :root[data-theme="dark"]{color-scheme:dark}
      html,body{margin:0;height:100%;background:var(--bg);color:var(--text)}
      body{font:13px/1.45 -apple-system,system-ui,sans-serif;-webkit-font-smoothing:antialiased;display:grid;place-items:center}
      header{display:grid;grid-template-columns:auto 1fr auto;align-items:center;gap:16px;max-width:760px;width:calc(100% - 48px)}
      svg{color:var(--text-3)}
      h1{margin:0 0 2px;font:600 23px/1.2 ui-serif,"New York",Georgia,serif;letter-spacing:-.01em}
      p{margin:0;color:var(--text-2)}
      .code{margin-top:6px;font:11px/1.4 Menlo,ui-monospace,monospace;color:var(--text-3);text-transform:uppercase;letter-spacing:.02em}
      .host{text-transform:none}
      .button{display:inline-flex;align-items:center;height:28px;padding:0 12px;border-radius:8px;background:var(--primary);color:var(--primary-text);font:500 13px/1 -apple-system,system-ui,sans-serif;text-decoration:none}
      </style></head><body><header>
      <svg viewBox="0 0 48 48" width="48" height="48" aria-hidden="true"><path d="M8 18.5a23 23 0 0 1 32 0M13.5 24.5a15 15 0 0 1 21 0M19 30.5a7 7 0 0 1 10 0" fill="none" stroke="currentColor" stroke-width="3.2" stroke-linecap="round"/><path d="M6 6l36 36" stroke="currentColor" stroke-width="3.2" stroke-linecap="round"/></svg>
      <div><h1>No internet</h1><p>Try checking your network cables, router, or Wi‑Fi.</p>
      <p class="code">ERR_INTERNET_DISCONNECTED<span class="host"> · \(escape(host))</span></p></div>
      <a class="button" id="reload" href="\(pageAction("reload", token: token))">Retry</a>
      </header></body></html>
      """
    return WebKitErrorPage(title: "\(host) · No internet", html: html)
  }

  private static func themeVariables(_ name: String?) -> String {
    let key = name == "incognito" ? "neutral" : name ?? ""
    guard var c = swatches[key] else { return "" }
    if key == "neutral" {
      let y = (c.0 * 0.2126 + c.1 * 0.7152 + c.2 * 0.0722).rounded()
      c = (y, y, y)
    }
    func mix(_ target: (Double, Double, Double), _ t: Double) -> String {
      let channel = { (a: Double, b: Double) in Int((a + (b - a) * t).rounded()) }
      return "rgb(\(channel(c.0, target.0)) \(channel(c.1, target.1)) \(channel(c.2, target.2))"
    }
    let black = (0.0, 0.0, 0.0), paper = (247.0, 245.0, 238.0)
    let lightBg = mix(paper, 0.88), darkBg = mix(black, 0.82), lightText = mix(black, 0.8), darkText = mix(paper, 0.9)
    let rule = { (name: String, light: String, dark: String) in "\(name):light-dark(\(light)),\(dark)))" }
    return [
      rule("--bg", lightBg, darkBg), rule("--text", lightText, darkText),
      rule("--text-2", lightText + " / .68", darkText + " / .68"), rule("--text-3", lightText + " / .46", darkText + " / .45"),
      rule("--primary", mix(black, 0.66), mix(paper, 0.6)), rule("--primary-text", lightBg, darkBg),
    ].joined(separator: ";")
  }

  func failed(_ webView: WKWebView, _ error: Error, committed: Bool = false) {
    let nsError = error as NSError
    let failing = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url
    let cancelled = nsError.code == NSURLErrorCancelled || (nsError.domain == "WebKitErrorDomain" && (nsError.code == 102 || nsError.code == 204))
    if !cancelled { emit("loadError", ["url": failing?.absoluteString ?? "", "code": nsError.code, "text": nsError.localizedDescription]) }
    if !cancelled, !committed, let failing, showCertificateInterstitial(webView, nsError, url: failing) { return }
    guard !cancelled, !committed, let failing else { return queueNavigation() }
    showErrorPage(webView, nsError, url: failing)
  }

  func showErrorPage(_ webView: WKWebView, _ nsError: NSError, url failing: URL) {
    errorURL = failing
    showingError = true
    safety.interstitial = nil
    let page = Self.errorPage(failing, nsError, pageColor: safety.pageColor, token: safety.newToken())
    safety.errorTitle = page.title
    webView.loadHTMLString(page.html, baseURL: failing)
  }

  func applyPageColor(_ name: String?) {
    guard safety.pageColor != name else { return }
    safety.pageColor = name
    guard showingError, safety.interstitial == nil, let view = webView else { return }
    let style = Self.jsString(Self.themeVariables(name))
    let dark = name == "incognito" ? "'dark'" : "null"
    view.evaluateJavaScript("(() => { const r = document.documentElement; if (!document.querySelector('header')) return; r.setAttribute('style', \(style)); if (\(dark)) r.dataset.theme = 'dark'; else delete r.dataset.theme; })()",
                            in: nil, in: .page) { _ in }
  }

  func applyBackdrop(_ color: NSColor?) {
    safety.backdrop = color
    paintBackdrop()
  }

  func prepareFirstPaint(_ view: WebKitWebView) {
    if view.responds(to: NSSelectorFromString("_setObservedRenderingProgressEvents:")) {
      view.setValue(NSNumber(value: Self.firstPaintEvents), forKey: "observedRenderingProgressEvents")
    }
    safety.awaitingFirstPaint = view.url == nil
    paintBackdrop()
  }

  private static let firstPaintEvents: UInt = 1 << 1 | 1 << 6

  private func paintBackdrop() {
    wantsLayer = true
    layer?.backgroundColor = safety.backdrop?.cgColor
    guard let view = webView, view.responds(to: NSSelectorFromString("_setDrawsBackground:")) else { return }
    let draws = !(safety.awaitingFirstPaint && safety.backdrop != nil)
    if (view.value(forKey: "drawsBackground") as? Bool) != draws { view.setValue(draws, forKey: "drawsBackground") }
  }

  @objc(_webView:renderingProgressDidChange:)
  func webViewRenderingProgressDidChange(_ webView: WKWebView, progressEvents: UInt) {
    guard webView === self.webView, safety.awaitingFirstPaint, progressEvents & Self.firstPaintEvents != 0 else { return }
    safety.awaitingFirstPaint = false
    paintBackdrop()
  }
}
