import AppKit
import WebKit

protocol WebKitTabDelegate: AnyObject {
  func webKitTab(_ tab: WebKitTab, event name: String, payload: [String: Any])
}

final class WebKitTab: NSView, WKNavigationDelegate, WKUIDelegate {
  static let zoomLevels: [Double] = [0.25, 0.333, 0.5, 0.667, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5]

  weak var delegate: WebKitTabDelegate?
  var profile = ""
  var initialURL: String?
  var adoptId: String?
  var transferKey: String?
  var visible = true { didSet { updateHidden(); wakeIfShown(was: oldValue); updateSight(); noteShownChanged(); showNextDialog(); if !visible { WebKitHub.shared.logins.closeDropdowns(for: self) } } }
  var selected = true { didSet { noteShownChanged() } }
  var wasShown = true
  var autoPictureInPicture = false { didSet { autoPictureInPictureInputsChanged() } }
  var pageBackgroundColor: NSColor? { didSet { if let color = pageBackgroundColor { webView?.underPageBackgroundColor = color } } }
  let browserId = WebKitHub.shared.nextBrowserId()

  private(set) var webView: WebKitWebView?
  private var observations: [NSObject] = []
  private var started = false
  private(set) var closed = false { didSet { if closed { stopWatchingSight() } } }
  private var navigationQueued = false
  var mediaFrames: [String: WKFrameInfo] {
    get { webView?.mediaFrames ?? [:] }
    set { webView?.mediaFrames = newValue }
  }
  var playingFrames: Set<String> {
    get { webView?.playingFrames ?? [] }
    set { webView?.playingFrames = newValue }
  }
  private(set) var muted = false
  var pageMedia = WebKitPageMedia()
  var life = WebKitTabLife()
  var sightObserver: NSObjectProtocol?
  var errorURL: URL?
  private var committedAt: Double = 0
  private var respondedStatus = 0
  private var committedStatus = 0
  var showingError = false
  let finder = WebKitFinder()
  let blocked = WebKitBlockedCount()
  let safety = WebKitTabSafety()

  override var isFlipped: Bool { true }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    fitPageToInterfaceScale()
  }

  override func resizeSubviews(withOldSize oldSize: NSSize) { fillWithPage() }

  override func layout() {
    super.layout()
    fillWithPage()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil { followInterfaceScale() }
    watchSight()
    showNextDialog()
  }

  func emit(_ name: String, _ payload: [String: Any] = [:]) {
    delegate?.webKitTab(self, event: name, payload: payload)
  }

  func start() {
    guard !started else { return }
    started = true
    begin()
  }

  private func begin() {
    guard !closed else { return }
    if let key = transferKey {
      let handedOver = WebKitHub.shared.transfers.isPrepared(key) ? WebKitHub.shared.transfers.liveTab(key).flatMap { $0 === self ? nil : $0.relinquish() } : nil
      let parked = WebKitHub.shared.transfers.claimParked(key) as? WebKitWebView
      WebKitHub.shared.transfers.noteLive(self, key: key)
      if let view = handedOver ?? parked {
        if let parked, parked !== view { WebKitHub.close(parked) }
        attach(view)
        emitEverything()
        return
      }
    }
    if let id = adoptId, id.hasPrefix("webkit:"), let offered = WebKitHub.shared.transfers.claimOffered(id) as? WebKitWebView {
      attach(offered)
      emitEverything()
      return
    }
    if let id = adoptId, WebKitHeldPopup.closedBeforeAdoption(id) {
      attach(makeView())
      emit("ready", [:])
      emit("windowClose")
      return
    }
    let created = makeView()
    attach(created)
    emit("ready", [:])
    if let url = initialURL, !url.isEmpty { startFirstPage(url, in: created) }
  }

  func relinquish() -> WebKitWebView? {
    guard !closed, let view = webView else { return nil }
    closed = true
    observations = []
    cancelDialogs()
    WebKitHub.shared.permissions.drop(browserId: browserId)
    if let key = transferKey { WebKitHub.shared.transfers.forgetLive(self, key: key) }
    WebKitHub.shared.logins.forget(self)
    WebKitAutofill.shared.forget(self)
    webView = nil
    stopListening(to: view)
    WebKitHub.shared.transfers.unregister(view)
    view.navigationDelegate = nil
    view.uiDelegate = nil
    view.removeFromSuperview()
    return view
  }

  private func emitEverything() {
    emit("ready", [:])
    queueNavigation()
    emit("progress", ["progress": webView?.estimatedProgress ?? 0])
    emitSecurity()
    emitZoom()
  }

  func attach(_ view: WebKitWebView) {
    webView = view
    defer { WebKitHeldPopup.release(view, to: self) }
    WebKitHub.shared.transfers.register(view, tab: self)
    view.navigationDelegate = self
    view.uiDelegate = self
    view.allowsBackForwardNavigationGestures = true
    view.allowsMagnification = true
    view.isInspectable = WebKitHub.inspectable && !WebKitStores.isPrivate(profile)
    if let color = pageBackgroundColor ?? life.contentsBackgroundColor { view.underPageBackgroundColor = color }
    listen(to: view)
    view.frame = bounds
    view.autoresizingMask = [.width, .height]
    addSubview(view)
    updateHidden()
    observe(view)
    prepareFirstPaint(view)
    if effectiveMuted { applyMute() }
    checkSoundRule()
    WebKitHub.shared.permissions.reconcileCapture(view, profile: profile)
    pushFieldProvider()
    updateSight()
  }

  private func observe(_ view: WebKitWebView) {
    let navigation: (WKWebView) -> Void = { [weak self] _ in self?.queueNavigation() }
    observations = [
      view.observe(\.url) { _, _ in navigation(view) },
      view.observe(\.title) { _, _ in navigation(view) },
      view.observe(\.canGoBack) { _, _ in navigation(view) },
      view.observe(\.canGoForward) { _, _ in navigation(view) },
      view.observe(\.isLoading) { _, _ in navigation(view) },
      view.observe(\.themeColor) { _, _ in navigation(view) },
      view.observe(\.estimatedProgress) { [weak self] v, _ in self?.emit("progress", ["progress": v.estimatedProgress]) },
      view.observe(\.hasOnlySecureContent) { [weak self] _, _ in self?.emitSecurity() },
      view.observe(\.serverTrust) { [weak self] _, _ in self?.emitSecurity() },
      view.observe(\.cameraCaptureState) { [weak self] _, _ in self?.emitMediaAccess() },
      view.observe(\.microphoneCaptureState) { [weak self] _, _ in self?.emitMediaAccess() },
      view.observe(\.magnification) { [weak self] _, _ in self?.emitZoom() },
    ] + mediaWatches(view)
  }

  func dropViewForDiscard() -> WebKitWebView? {
    guard let view = webView else { return nil }
    observations = []
    webView = nil
    stopListening(to: view)
    return view
  }

  private func updateHidden() {
    webView?.isHidden = !visible
  }

  func close() {
    guard !closed else { return }
    lifecycleEnded()
    closed = true
    observations = []
    cancelDialogs()
    WebKitHub.shared.permissions.drop(browserId: browserId)
    if let key = transferKey { WebKitHub.shared.transfers.forgetLive(self, key: key) }
    guard let view = webView else { return }
    WebKitHub.shared.logins.forget(self)
    WebKitAutofill.shared.forget(self)
    webView = nil
    stopListening(to: view)
    if let key = transferKey, WebKitHub.shared.transfers.isPrepared(key) {
      WebKitHub.shared.transfers.unregister(view)
      view.navigationDelegate = nil
      view.uiDelegate = nil
      view.removeFromSuperview()
      if WebKitHub.shared.transfers.park(view, key: key) { return }
    }
    WebKitHub.close(view)
  }

  func queueNavigation() {
    guard !navigationQueued else { return }
    navigationQueued = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.navigationQueued = false
      self.emitNavigation()
    }
  }

  private func emitNavigation() {
    guard let view = webView else { return }
    let reported = showingError ? nil : view.reportedTheme
    let theme = reported?.color ?? view.themeColor.flatMap(Self.hex)
    var navigation: [String: Any] = [
      "url": (view.url ?? view.backForwardList.currentItem?.url)?.absoluteString ?? "",
      "committedUrl": showingError ? "" : (view.backForwardList.currentItem?.url.absoluteString ?? ""),
      "committedAt": committedAt,
      "title": showingError ? safety.errorTitle : (view.title ?? ""),
      "canGoBack": view.canGoBack,
      "canGoForward": view.canGoForward,
      "isLoading": view.isLoading,
      "themeColor": theme ?? NSNull(),
      "themeColorSource": reported?.source ?? (theme == nil ? NSNull() : "meta"),
    ]
    if committedStatus > 0 && !showingError { navigation["httpStatus"] = committedStatus }
    WebKitTabHistory.scheduleSave(self)
    emit("navigation", navigation)
  }

  static func hex(_ color: NSColor) -> String? {
    guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
    let r = Int((rgb.redComponent * 255).rounded()), g = Int((rgb.greenComponent * 255).rounded()), b = Int((rgb.blueComponent * 255).rounded())
    return String(format: "#%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
  }

  func emitMediaAccess() {
    guard let view = webView else { return }
    emit("mediaAccess", [
      "camera": view.cameraCaptureState == .active, "microphone": view.microphoneCaptureState == .active, "screen": capturesDisplay,
    ])
    autoPictureInPictureInputsChanged()
  }

  func loadURL(_ url: String, userInitiated: Bool) {
    if wakeDiscarded(loading: url) { return }
    guard let view = webView, let target = URL(string: url) else { return }
    showingError = false
    safety.trustCheck = nil
    if target.isFileURL {
      view.loadFileURL(target, allowingReadAccessTo: target.deletingLastPathComponent())
    } else {
      view.load(URLRequest(url: target))
    }
  }

  func goBack() {
    wakeDiscarded()
    webView?.goBack()
  }

  func goForward() {
    wakeDiscarded()
    webView?.goForward()
  }

  func go(toHistoryOffset offset: Int) {
    wakeDiscarded()
    guard let view = webView, let item = view.backForwardList.item(at: offset) else { return }
    view.go(to: item)
  }

  func reload() {
    if wakeDiscarded() { return }
    if showingError, let url = errorURL { return loadURL(url.absoluteString, userInitiated: true) }
    webView?.reload()
  }

  func reloadIgnoringCache() {
    if wakeDiscarded() { return }
    if showingError, let url = errorURL { return loadURL(url.absoluteString, userInitiated: true) }
    webView?.reloadFromOrigin()
  }

  func stopLoading() { webView?.stopLoading() }

  func focusPage() {
    guard let view = webView else { return }
    window?.makeFirstResponder(view)
  }

  func focusPageIfUnfocused() -> Bool {
    guard let window, window.firstResponder == nil || window.firstResponder === window else { return false }
    focusPage()
    return true
  }

  func setMuted(_ on: Bool) {
    let changed = on != muted
    muted = on
    if changed, on, WebKitWebView.mutesPage { ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "pageMute"])) }
    applyMute()
    if changed { emitMedia() }
  }

  func runInWorld(_ code: String, frame: WKFrameInfo? = nil, completion: ((Any?) -> Void)? = nil) {
    guard let view = webView else {
      completion?(nil)
      return
    }
    view.evaluateJavaScript(code, in: frame, in: WebKitHub.world) { result in
      if case .success(let value) = result { completion?(value) } else { completion?(nil) }
    }
  }

  private var host: String { webView?.url?.host?.lowercased() ?? "" }

  func zoomStep(_ direction: Int) {
    guard let view = webView else { return }
    let current = view.pageZoom
    var next = 1.0
    if direction > 0 { next = Self.zoomLevels.first { $0 > current + 0.001 } ?? current }
    if direction < 0 { next = Self.zoomLevels.last { $0 < current - 0.001 } ?? current }
    view.pageZoom = next
    if !host.isEmpty { WebKitHub.shared.stores.setZoom(next, profile: profile, host: host) }
    emitZoom(byUser: abs(next - current) > 0.001)
  }

  private func emitZoom(byUser user: Bool = false) {
    guard let view = webView else { return }
    emit("zoom", ["zoom": view.pageZoom, "host": host, "isDefault": abs(view.pageZoom - 1) < 0.001, "pinchScale": view.magnification, "user": user])
  }

  static func jsString(_ text: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: [text]), let json = String(data: data, encoding: .utf8) else { return "\"\"" }
    return String(json.dropFirst().dropLast())
  }

  func executeJavaScript(_ code: String) {
    webView?.evaluateJavaScript(code, in: nil, in: .page) { _ in }
  }

  func evaluate(_ code: String, completion: @escaping (String?) -> Void) {
    guard let view = webView else { return completion(nil) }
    let body = "return await new Promise((resolve) => { const post = (kind, json) => { if (kind === \"result\") resolve(json); }; setTimeout(() => resolve(null), 3000); try {\n\(code)\n} catch (e) { resolve(null); } });"
    view.callAsyncJavaScript(body, arguments: [:], in: nil, in: WebKitHub.world) { result in
      if case .success(let value) = result { completion(value as? String) } else { completion(nil) }
    }
  }

  func navigationEntries() -> [[String: Any]] {
    guard let list = webView?.backForwardList else { return [] }
    let entry = { (item: WKBackForwardListItem, current: Bool) -> [String: Any] in
      ["url": item.url.absoluteString, "title": item.title ?? "", "current": current]
    }
    var entries = list.backList.map { entry($0, false) }
    if let current = list.currentItem { entries.append(entry(current, true)) }
    entries += list.forwardList.map { entry($0, false) }
    return entries
  }

  func downloadFavicon(_ url: String, completion: @escaping ([String: Any]?) -> Void) {
    ArdiaFavicons.fetch(url, profile: profile, name: nil) { completion($0) }
  }

  private var nowPlayingSubframe: WKFrameInfo? {
    let frame = webView?.nowPlaying.frame.flatMap { mediaFrames[$0] }
    return frame?.isMainFrame == true ? nil : frame
  }

  func mediaCommand(_ action: String, seconds: Double) {
    runInWorld("window.__ardia && window.__ardia.media(\(Self.jsString(action)), \(seconds.isFinite ? seconds : 0))", frame: nowPlayingSubframe)
  }

  func setPictureInPicture(_ on: Bool, automatic: Bool = false, completion: @escaping (PictureInPictureAnswer) -> Void) {
    let code = "window.__ardia ? window.__ardia.pictureInPicture(\(on ? "true" : "false"), \(automatic ? "true" : "false")) : false"
    if !on {
      for frame in mediaFrames.values where !frame.isMainFrame { runInWorld(code, frame: frame) }
    }
    runInWorld(code, frame: on ? nowPlayingSubframe : nil) { value in
      completion(value as? String == "nothingPlaying" ? .nothingPlaying : (value as? NSNumber)?.boolValue == true ? .opened : .failed)
    }
  }

  private func emitSecurity() {
    guard webView != nil else { return }
    emit("security", securityInfo())
  }

  func clearSiteData(_ reply: @escaping (Any?, String?) -> Void) {
    guard !host.isEmpty else { return reply(["cookies": false, "storage": false], nil) }
    WebKitHub.shared.clearSiteData(profile: profile, host: host) { reply($0, nil) }
  }

  func pageMessage(_ kind: String, data: Any?, frame: String, frameInfo: WKFrameInfo) {
    let dict = data as? [String: Any]
    let main = frameInfo.isMainFrame
    switch kind {
    case "media":
      guard let dict else { return }
      mediaFrames[frame] = frameInfo
      if !WebKitWebView.mutesPage, (dict["muted"] as? Bool ?? false) != effectiveMuted { runInWorld(muteScript, frame: main ? nil : frameInfo) }
      if dict["playing"] as? Bool == true { playingFrames.insert(frame) } else { playingFrames.remove(frame) }
      emitMedia()
    case "nowPlaying":
      guard let view = webView else { return }
      if let dict, !dict.isEmpty { mediaFrames[frame] = frameInfo } else if !main, !playingFrames.contains(frame) { mediaFrames.removeValue(forKey: frame) }
      emit("nowPlaying", ["state": view.nowPlaying.noteFrame(frame, page: data, main: main) ?? NSNull()])
    case "pip":
      let active = dict?["active"] as? Bool ?? false
      autoPictureInPictureRule.reported(active: active)
      emit("pictureInPicture", ["kind": "video", "active": active])
    case "mediaFault":
      if let fault = WebKitMediaFaults.event(dict, from: frameInfo, muted: muted, blockerActive: WebKitContentBlocker.shared.isFiltering && !blocked.exemptLoad) { emit("mediaFault", fault) }
    case "status":
      noteLinkStatus(data, main: main)
    case "icons":
      noteIcons(dict, main: main)
    case "theme":
      guard main, let view = webView else { return }
      noteTheme(dict, in: view)
    case "scroll":
      guard main, let state = dict?["state"] as? String, ["down", "up", "top"].contains(state) else { return }
      emit("scroll", ["state": state])
    default: fieldProviderMessage(kind, data: dict, frame: frame, frameInfo: frameInfo)
    }
  }

  private static let themeSources: Set<String> = ["meta", "header", "background"]

  private func noteTheme(_ dict: [String: Any]?, in view: WebKitWebView) {
    let color = (dict?["color"] as? String).flatMap { $0.wholeMatch(of: /#[0-9A-F]{6}/) == nil ? nil : $0 }
    let source = (dict?["source"] as? String).flatMap { Self.themeSources.contains($0) ? $0 : nil }
    view.reportedTheme = color.flatMap { color in source.map { WebKitReportedTheme(color: color, source: $0) } }
    if source == "header" || source == "background", color != nil, !view.sampledThemeCounted {
      view.sampledThemeCounted = true
      ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "sampledTint"]))
    }
    queueNavigation()
  }

  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences,
               decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
    let mainFrame = action.targetFrame?.isMainFrame == true
    let decide = { [weak self] (policy: WKNavigationActionPolicy) in
      if mainFrame { self?.safety.target.decided(allowed: policy == .allow) }
      decisionHandler(policy, preferences)
    }
    if handlePageAction(action) { return decide(.cancel) }
    guard let url = action.request.url else { return decide(.allow) }
    if mainFrame { safety.target.began(url) }
    let scheme = url.scheme?.lowercased() ?? ""
    let webSchemes: Set<String> = ["http", "https", "file", "about", "data", "blob", "javascript", "webkit-pdfjs-viewer"]
    if !webSchemes.contains(scheme) {
      decide(.cancel)
      let fromMainFrame = action.sourceFrame.isMainFrame || action.targetFrame?.isMainFrame == true
      guard action.navigationType == .linkActivated || fromMainFrame else { return }
      let source = action.sourceFrame.securityOrigin
      let origin = source.host.isEmpty ? nil : Origins.of(source)
      if let request = WebKitHub.shared.externalApps.request(url: url, origin: origin, profile: profile) { emit("externalApp", request) }
      return
    }
    if let policy = linkPolicy(for: action, url: url) { return decide(policy) }
    applyHTTPSPolicy(action, preferences: preferences)
    if action.targetFrame?.isMainFrame == true, !applyBlockerPolicy(action, preferences: preferences, in: webView) { return decide(.cancel) }
    applySiteSettings(action, preferences: preferences, in: webView) { decide(action.shouldPerformDownload ? .download : .allow) }
  }

  func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
    let attachment = disposition.hasPrefix("attachment")
    let policy: WKNavigationResponsePolicy = !response.canShowMIMEType || (attachment && response.isForMainFrame) ? .download : .allow
    if response.isForMainFrame {
      respondedStatus = (response.response as? HTTPURLResponse)?.statusCode ?? 0
      safety.target.responded(status: respondedStatus, displays: policy == .allow)
    }
    noteTransportSecurity(response, in: webView)
    decisionHandler(policy)
  }

  func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
    if navigationAction.targetFrame?.isMainFrame != false { safety.target.ended() }
    adoptDownload(download, from: webView)
  }

  func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
    if navigationResponse.isForMainFrame { safety.target.ended() }
    adoptDownload(download, from: webView)
  }

  private func adoptDownload(_ download: WKDownload, from webView: WKWebView) {
    noteNavigationDownload(download, from: webView)
    WebKitHub.shared.downloads.adopt(download, profile: profile, webView: webView)
    let url = download.originalRequest?.url?.absoluteString ?? ""
    emit("downloadNavigation", ["url": url, "committedUrl": webView.backForwardList.currentItem?.url.absoluteString ?? "", "skipped": false])
  }

  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    fieldProviderCommitted()
    if !showingError { errorURL = nil }
    committedAt = Date().timeIntervalSince1970 * 1000
    committedStatus = respondedStatus
    respondedStatus = 0
    playingFrames.removeAll()
    mediaFrames.removeAll()
    resetNowPlaying()
    cancelDialogs()
    safety.dialogs.pageChanged()
    safety.target.ended()
    recordTransportSecurity(webView)
    WebKitHub.shared.permissions.drop(browserId: browserId)
    self.webView?.captureOrigins.removeAll()
    self.webView?.reportedTheme = nil
    self.webView?.sampledThemeCounted = false
    if !host.isEmpty {
      let zoom = WebKitHub.shared.stores.zoom(profile: profile, host: host)
      if abs(webView.pageZoom - zoom) > 0.001 { webView.pageZoom = zoom }
    }
    audioCommitted()
    emitZoom()
    emitSecurity()
    queueNavigation()
    siteCommitted()
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    if !WebKitWebView.mutesPage, effectiveMuted { applyMute() }
    queueNavigation()
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    respondedStatus = 0
    resetBlocked()
    if showingError && webView.url != errorURL { showingError = false }
    emit("status", ["text": ""])
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    respondedStatus = 0
    safety.target.ended()
    safety.pendingTransportSecurity = nil
    failed(webView, error)
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    failed(webView, error, committed: true)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    guard webView === self.webView else { return }
    cancelDialogs()
    WebKitHub.shared.permissions.drop(browserId: browserId)
    mediaFrames.removeAll()
    playingFrames.removeAll()
    self.webView?.scriptFrames.removeAll()
    if let view = self.webView { ArdiaWebView.resetFieldProviderPage(view) }
    resetNowPlaying()
    processTerminated()
    emitMedia()
    emit("crashed", ["status": 0, "reason": "crashed", "code": 0])
  }

  private func resetNowPlaying() {
    if webView?.nowPlaying.reset() == true { emit("nowPlaying", ["state": NSNull()]) }
  }

  func webViewDidClose(_ webView: WKWebView) {
    emit("windowClose")
  }
}
