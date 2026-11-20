import AppKit
import Security
import WebKit

struct WebKitInterstitial {
  let url: URL
  let errors: [String]
  let trust: SecTrust?
  let fingerprint: String?
  let overridable: Bool
  let strictTransport: Bool
}

final class WebKitTabSafety {
  struct BlockedPopup {
    let url: String
    let disposition: String
    let item: WKBackForwardListItem?
  }

  var pageToken = UUID().uuidString
  var interstitial: WebKitInterstitial?
  var errorTitle = ""
  var pageColor: String?
  var backdrop: NSColor?
  var awaitingFirstPaint = false
  let dialogs = WebKitPageDialogs()
  var blockedPopups: [String: BlockedPopup] = [:]
  var lastPopup = 0
  var target = WebKitMainFrameTarget()
  var pendingTransportSecurity: (host: String, header: String)?
  var trustCheck: UUID?

  func newToken() -> String {
    pageToken = UUID().uuidString
    return pageToken
  }
}

extension WebKitTab {
  static let pageActionScheme = "ardia-page"

  private static let authMethods: Set<String> = [
    NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM, NSURLAuthenticationMethodDefault,
  ]

  func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
               completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    let method = challenge.protectionSpace.authenticationMethod
    if method == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust {
      return answerServerTrust(trust, host: challenge.protectionSpace.host, completionHandler)
    }
    guard Self.authMethods.contains(method) else { return completionHandler(.performDefaultHandling, nil) }
    guard challenge.protectionSpace.isProxy() || promptsFor(challenge.protectionSpace, in: webView) else {
      ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "authPromptBlocked"]))
      return completionHandler(.performDefaultHandling, nil)
    }
    if challenge.previousFailureCount == 0, let proposed = challenge.proposedCredential, proposed.hasPassword {
      return completionHandler(.useCredential, proposed)
    }
    presentDialog(cancel: { completionHandler(.cancelAuthenticationChallenge, nil) }) { [weak self] window, settle in
      self?.showAuthPrompt(challenge, in: window, settle: settle) { credential in
        completionHandler(credential == nil ? .performDefaultHandling : .useCredential, credential)
      }
    }
  }

  func promptsFor(_ space: URLProtectionSpace, in webView: WKWebView) -> Bool {
    let candidates = [webView.url, safety.target.url].compactMap { $0 }
    return candidates.contains { Self.sameAuthority(space, $0) }
  }

  static func sameAuthority(_ space: URLProtectionSpace, _ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), let spaceScheme = space.protocol?.lowercased() else { return false }
    let defaults = ["http": 80, "https": 443]
    let port = url.port ?? defaults[scheme] ?? -1
    let spacePort = space.port > 0 ? space.port : defaults[spaceScheme] ?? -1
    return scheme == spaceScheme && host == space.host.lowercased() && port == spacePort
  }

  private func answerServerTrust(_ trust: SecTrust, host: String, _ answer: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    let hub = WebKitHub.shared
    let store = hub.stores.id(of: profile)
    guard hub.certificates.hasException(store, host: host), let print = WebKitCertificates.fingerprint(trust) else {
      return answer(.performDefaultHandling, nil)
    }
    WebKitCertificates.evaluate(trust) { errors in
      guard !errors.isEmpty, hub.certificates.allows(store, host: host, fingerprint: print, errors: errors) else {
        return answer(.performDefaultHandling, nil)
      }
      answer(.useCredential, URLCredential(trust: trust))
    }
  }

  private static let certificateFailures: Set<Int> = [
    NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
    NSURLErrorServerCertificateNotYetValid, NSURLErrorSecureConnectionFailed,
  ]

  func showCertificateInterstitial(_ webView: WKWebView, _ error: NSError, url: URL) -> Bool {
    guard error.domain == NSURLErrorDomain, Self.certificateFailures.contains(error.code), url.scheme?.lowercased() == "https",
      let host = url.host, !host.isEmpty
    else { return false }
    let peer = error.userInfo[NSURLErrorFailingURLPeerTrustErrorKey].flatMap { value -> SecTrust? in
      CFGetTypeID(value as CFTypeRef) == SecTrustGetTypeID() ? (value as! SecTrust) : nil
    }
    let fallback: [String] = switch error.code {
    case NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid: ["dateInvalid"]
    case NSURLErrorSecureConnectionFailed: []
    default: ["authorityInvalid"]
    }
    guard let trust = peer else {
      guard !fallback.isEmpty else { return false }
      presentInterstitial(webView, url: url, host: host, errors: fallback, trust: nil)
      return true
    }
    let check = UUID()
    safety.trustCheck = check
    safety.interstitial = nil
    errorURL = url
    showingError = true
    WebKitCertificates.evaluate(trust) { [weak self, weak webView] evaluated in
      guard let self, let webView, webView === self.webView, self.safety.trustCheck == check, self.showingError, self.errorURL == url else { return }
      self.safety.trustCheck = nil
      let errors = evaluated.isEmpty ? fallback : evaluated
      guard !errors.isEmpty else { return self.showErrorPage(webView, error, url: url) }
      self.presentInterstitial(webView, url: url, host: host, errors: errors, trust: trust)
    }
    return true
  }

  private func presentInterstitial(_ webView: WKWebView, url: URL, host: String, errors: [String], trust: SecTrust?) {
    let hub = WebKitHub.shared
    let store = hub.stores.id(of: profile)
    let print = trust.flatMap(WebKitCertificates.fingerprint)
    let strict = hub.certificates.requiresSecureTransport(host, store: store)
    let overridable = print != nil && WebKitCertificatePolicy.overridable(errors) && !strict
    let blocked = WebKitInterstitial(url: url, errors: errors, trust: trust, fingerprint: print, overridable: overridable, strictTransport: strict)
    safety.interstitial = blocked
    safety.errorTitle = "Privacy error"
    errorURL = url
    showingError = true
    let leaf = trust.flatMap(Self.certificate)
    let page = Self.interstitialPage(blocked, host: host, certificate: leaf, token: safety.newToken())
    webView.loadHTMLString(page, baseURL: url)
    ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "certificateInterstitial"]))
    emit("security", securityInfo())
  }

  private static let netErrorNames: [String: String] = [
    "nameMismatch": "ERR_CERT_COMMON_NAME_INVALID", "dateInvalid": "NET::ERR_CERT_DATE_INVALID", "authorityInvalid": "NET::ERR_CERT_AUTHORITY_INVALID",
    "revoked": "NET::ERR_CERT_REVOKED", "invalid": "NET::ERR_CERT_INVALID", "weakSignature": "NET::ERR_CERT_WEAK_SIGNATURE_ALGORITHM",
    "weakKey": "NET::ERR_CERT_WEAK_KEY", "nameConstraint": "NET::ERR_CERT_NAME_CONSTRAINT_VIOLATION", "validityTooLong": "NET::ERR_CERT_VALIDITY_TOO_LONG",
    "certificateTransparency": "NET::ERR_CERTIFICATE_TRANSPARENCY_REQUIRED",
  ]

  static func interstitialExplanation(_ primary: String, host: String, certificate: [String: Any]?, now: Date = Date()) -> String {
    let site = "<strong>\(escape(host))</strong>"
    let prove = "This server could not prove that it is \(site);"
    let cause = "This may be caused by a misconfiguration or an attacker intercepting your connection."
    let day = 86_400_000.0
    let nowMs = now.timeIntervalSince1970 * 1000
    switch primary {
    case "authorityInvalid":
      return "\(prove) its security certificate is not trusted by your computer's operating system. \(cause)"
    case "nameMismatch":
      let subject = (certificate?["subject"] as? [String: Any])?["commonName"] as? String ?? ""
      return subject.isEmpty ? "\(prove) its security certificate contains errors. \(cause)"
        : "\(prove) its security certificate is from <strong>\(escape(subject))</strong>. \(cause)"
    case "dateInvalid":
      let until = certificate?["validUntil"] as? Double ?? 0, from = certificate?["validFrom"] as? Double ?? 0
      if from > nowMs {
        let days = Int(((from - nowMs) / day).rounded(.up))
        return days <= 1 ? "\(prove) its security certificate is supposedly from tomorrow. \(cause)"
          : "\(prove) its security certificate is supposedly from \(days) days in the future. \(cause)"
      }
      let days = Int(((nowMs - until) / day).rounded(.down))
      let clock = now.formatted(date: .complete, time: .omitted)
      let expired = days <= 1 ? "its security certificate expired in the last day." : "its security certificate expired \(days) days ago."
      return "\(prove) \(expired) \(cause) Your computer's clock is currently set to \(clock). Does that look right? If not, you should correct your system's clock and then refresh this page."
    default:
      return "\(prove) its security certificate contains errors. \(cause)"
    }
  }

  static func interstitialPage(_ blocked: WebKitInterstitial, host: String, certificate: [String: Any]?, token: String) -> String {
    let primary = WebKitCertificates.primaryError(blocked.errors)
    let site = escape(host)
    let details: String
    if blocked.overridable {
      details = "<p>\(interstitialExplanation(primary, host: host, certificate: certificate))</p><p><a id=\"proceed\" href=\"\(pageAction("proceed", token: token))\">Proceed to \(site) (unsafe)</a></p>"
    } else if primary == "revoked" {
      details = "<p>You cannot visit \(site) right now because its certificate has been revoked. Network errors and attacks are usually temporary, so this page will probably work later.</p>"
    } else if blocked.strictTransport {
      details = "<p>\(interstitialExplanation(primary, host: host, certificate: certificate))</p><p>You cannot visit \(site) right now because the website uses HSTS. Network errors and attacks are usually temporary, so this page will probably work later.</p>"
    } else {
      details = "<p>You cannot visit \(site) right now because the website sent scrambled credentials that Ardia cannot process. Network errors and attacks are usually temporary, so this page will probably work later.</p>"
    }
    return """
      <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark"><title>Privacy error</title>
      <style>
      :root{--bg:#fff;--text:#5f6368;--heading:#202124;--accent:#1a73e8;--accent-text:#fff;--border:#dadce0;--danger:#d93025}
      @media (prefers-color-scheme: dark){:root{--bg:#202124;--text:#9aa0a6;--heading:#e8eaed;--accent:#8ab4f8;--accent-text:#202124;--border:#5f6368;--danger:#f28b82}}
      html,body{margin:0;background:var(--bg);color:var(--text)}
      body{font:15px/1.6 -apple-system,system-ui,sans-serif;word-wrap:break-word}
      main{box-sizing:border-box;max-width:600px;margin:14vh auto 0;padding:0 24px}
      svg{display:block;margin:0 0 40px;color:var(--danger)}
      h1{color:var(--heading);font-size:1.6em;font-weight:400;line-height:1.25em;margin:0 0 16px}
      p{margin:0 0 12px}a{color:var(--accent)}
      .code{display:block;margin-top:12px;font-size:.86667em;text-transform:uppercase}
      .buttons{display:flex;flex-direction:row-reverse;justify-content:space-between;align-items:center;margin-top:44px}
      .button{font-family:inherit;display:inline-block;padding:8px 16px;border-radius:20px;font-size:.875em;font-weight:500;text-decoration:none;border:1px solid var(--accent);background:var(--accent);color:var(--accent-text);cursor:default}
      .button.secondary{background:transparent;color:var(--accent);border-color:var(--border)}
      #details{display:none;margin-top:40px;padding-top:16px}#details.open{display:block}
      </style></head><body><main>
      <svg width="72" height="72" viewBox="0 0 72 72" aria-hidden="true"><path fill="currentColor" d="M36 6 2 66h68zm0 12 23 42H13zm-3 14h6v14h-6zm0 18h6v6h-6z"/></svg>
      <h1>Your connection is not private</h1>
      <p>Attackers might be trying to steal your information from <strong>\(site)</strong> (for example, passwords, messages, or credit cards).</p>
      <span class="code">\(netErrorNames[primary] ?? "NET::ERR_CERT_INVALID")</span>
      <div class="buttons"><a class="button" id="back" href="\(pageAction("back", token: token))">Back to safety</a>
      <button class="button secondary" id="advanced" type="button" onclick="var o=document.getElementById('details').classList.toggle('open');this.textContent=o?'Hide advanced':'Advanced'">Advanced</button></div>
      <div id="details">\(details)</div>
      </main></body></html>
      """
  }

  func handlePageAction(_ action: WKNavigationAction) -> Bool {
    guard let url = action.request.url, url.scheme?.lowercased() == Self.pageActionScheme else { return false }
    let parts = url.path.split(separator: "/").map(String.init)
    guard action.sourceFrame.isMainFrame, showingError, parts.count == 2, parts[1] == safety.pageToken, Self.userInitiated(action) else { return true }
    switch (url.host ?? "", parts[0]) {
    case ("page", "reload"):
      ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "errorPageRetry"]))
      reload()
    case ("page", "back"): leaveInterstitial()
    case ("page", "proceed"): proceedThroughInterstitial()
    default: break
    }
    return true
  }

  static func userInitiated(_ action: WKNavigationAction) -> Bool {
    guard action.responds(to: NSSelectorFromString("_isUserInitiated")) else { return action.navigationType == .linkActivated }
    return (action.value(forKey: "_isUserInitiated") as? Bool) == true
  }

  private func leaveInterstitial() {
    guard let view = webView else { return }
    if view.canGoBack {
      view.goBack()
      return
    }
    safety.interstitial = nil
    loadURL("about:blank", userInitiated: true)
  }

  private func proceedThroughInterstitial() {
    guard let blocked = safety.interstitial, blocked.overridable, let host = blocked.url.host, let print = blocked.fingerprint else { return }
    let hub = WebKitHub.shared
    hub.certificates.allow(hub.stores.id(of: profile), host: host, fingerprint: print, errors: blocked.errors)
    ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "certificateProceed"]))
    safety.interstitial = nil
    loadURL(blocked.url.absoluteString, userInitiated: true)
  }

  func applyHTTPSPolicy(_ action: WKNavigationAction, preferences: WKWebpagePreferences) {
    guard #available(macOS 15.2, *), action.targetFrame?.isMainFrame == true, let url = action.request.url, url.scheme?.lowercased() == "http",
      let host = url.host?.lowercased()
    else { return }
    preferences.preferredHTTPSNavigationPolicy = Self.upgradesToHTTPS(host: host, port: url.port) ? .automaticFallbackToHTTP : .keepAsRequested
  }

  static func upgradesToHTTPS(host: String, port: Int?) -> Bool {
    guard port == nil || port == 80, !WebKitCertificates.isIPAddress(host), host.contains(".") else { return false }
    let reserved = [".local", ".localhost", ".test", ".example", ".invalid", ".internal", ".lan", ".home.arpa"]
    return !reserved.contains { host.hasSuffix($0) }
  }

  func noteTransportSecurity(_ response: WKNavigationResponse, in webView: WKWebView) {
    guard response.isForMainFrame else { return }
    safety.pendingTransportSecurity = nil
    guard let http = response.response as? HTTPURLResponse, let url = http.url, url.scheme?.lowercased() == "https",
      let host = url.host, let header = http.value(forHTTPHeaderField: "Strict-Transport-Security")
    else { return }
    safety.pendingTransportSecurity = (host, header)
  }

  func recordTransportSecurity(_ webView: WKWebView) {
    guard let pending = safety.pendingTransportSecurity else { return }
    safety.pendingTransportSecurity = nil
    guard let url = webView.url, url.scheme?.lowercased() == "https", let host = url.host,
      WebKitCertificatePolicy.normalizedHost(host) == WebKitCertificatePolicy.normalizedHost(pending.host)
    else { return }
    let fingerprint = webView.serverTrust.flatMap(WebKitCertificates.fingerprint)
    WebKitHub.shared.certificates.noteTransportSecurity(pending.header, host: host, fingerprint: fingerprint, store: WebKitHub.shared.stores.id(of: profile))
  }

  private func showAuthPrompt(_ challenge: URLAuthenticationChallenge, in window: NSWindow, settle: @escaping () -> Bool,
                              answer: @escaping (URLCredential?) -> Void) -> NSWindow? {
    let space = challenge.protectionSpace
    ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "authPrompt"]))
    let authority = Self.authority(space)
    let insecure = !space.isProxy() && space.protocol?.lowercased() != "https"
    let finish = { (credential: URLCredential?) in if settle() { answer(credential) } }
    if let answered = Self.testAuthAnswer(authority: authority, insecure: insecure, proxy: space.isProxy()) {
      finish(answered)
      return nil
    }
    guard !LaunchConfig.shared.background else {
      NSLog("[webkit] sign-in prompt for %@ (background mode, cancelled)", authority)
      finish(nil)
      return nil
    }
    let alert = NSAlert()
    alert.messageText = "Sign in"
    let line = space.isProxy() ? "The proxy \(authority) requires a username and password" : "\(authority) requires a username and password"
    alert.informativeText = insecure ? "\(line)\nYour connection to this site is not private" : line
    let labelWidth: CGFloat = 76
    let username = NSTextField(frame: NSRect(x: labelWidth, y: 30, width: 260 - labelWidth, height: 24))
    username.stringValue = challenge.proposedCredential?.user ?? ""
    let password = NSSecureTextField(frame: NSRect(x: labelWidth, y: 0, width: 260 - labelWidth, height: 24))
    let fields = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
    for (title, field) in [("Username", username), ("Password", password)] as [(String, NSTextField)] {
      let label = NSTextField(labelWithString: title)
      label.alignment = .right
      label.frame = NSRect(x: 0, y: field.frame.minY + 4, width: labelWidth - 8, height: 17)
      field.setAccessibilityTitleUIElement(label)
      fields.addSubview(label)
      fields.addSubview(field)
    }
    username.nextKeyView = password
    alert.accessoryView = fields
    alert.addButton(withTitle: "Sign In")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = username
    alert.beginSheetModal(for: window) { response in
      finish(response == .alertFirstButtonReturn ? URLCredential(user: username.stringValue, password: password.stringValue, persistence: .forSession) : nil)
    }
    return alert.window
  }

  private static func authority(_ space: URLProtectionSpace) -> String {
    let scheme = space.isProxy() ? "" : (space.protocol?.lowercased() ?? "http") + "://"
    let defaultPort = space.protocol?.lowercased() == "https" ? 443 : 80
    let port = space.port > 0 && space.port != defaultPort ? ":\(space.port)" : ""
    return scheme + space.host.lowercased() + port
  }

  private static func testAuthAnswer(authority: String, insecure: Bool, proxy: Bool) -> URLCredential?? {
    guard LaunchConfig.shared.testFlag("appDialog"), let dir = LaunchConfig.shared.dataDirectory else { return nil }
    let file = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("dialog.json")
    let shown: [String: Any] = ["kind": "auth", "authority": authority, "insecure": insecure, "proxy": proxy]
    if let data = try? JSONSerialization.data(withJSONObject: shown, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: file, options: .atomic) }
    let pickFile = file.appendingPathExtension("pick")
    guard let pick = try? String(contentsOf: pickFile, encoding: .utf8) else { return nil }
    try? FileManager.default.removeItem(at: pickFile)
    let text = pick.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let colon = text.firstIndex(of: ":") else { return .some(nil) }
    return .some(URLCredential(user: String(text[..<colon]), password: String(text[text.index(after: colon)...]), persistence: .forSession))
  }
}
