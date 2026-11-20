import AppKit
import WebKit

struct WebKitDiscardedPage {
  let state: Any?
  let url: String
}

struct WebKitTabLife {
  var discarded: WebKitDiscardedPage?
  var frozen = false
  var suspended = false
  var unresponsive = false
  var unresponsiveRecheck: DispatchWorkItem?
  var historySave: DispatchWorkItem?
  var pageColor: String?
  var contentsBackgroundColor: NSColor?
}

enum WebKitTabHistory {
  struct Saved {
    let url: String
    let state: Data
  }

  private static let version = 1
  private static let saveDelay = 2.5
  private static let keepFor: TimeInterval = 90 * 86400
  private static let maxBytes = 32 * 1024 * 1024
  private static let files = DispatchQueue(label: "ardia.webkit.tab-history")
  private static var bound = Set<String>()
  private static var pruned = Set<String>()
  private static var waiting: [ObjectIdentifier: WebKitTab] = [:]
  private static let flushAtQuit: NSObjectProtocol = NotificationCenter.default.addObserver(
    forName: NSApplication.willTerminateNotification, object: nil, queue: .main
  ) { _ in flushAll() }

  private static func hex(_ text: String) -> String { text.utf8.map { String(format: "%02X", $0) }.joined() }

  private static func directory(_ profile: String) -> URL? {
    guard !WebKitStores.isPrivate(profile) else { return nil }
    return URL(fileURLWithPath: ArdiaHost.dataDirectory).appendingPathComponent("WebKit Tab History").appendingPathComponent("p" + hex(profile))
  }

  private static func file(_ profile: String, key: String) -> URL? {
    guard !key.isEmpty else { return nil }
    return directory(profile)?.appendingPathComponent(hex(key))
  }

  static func samePage(_ a: String, _ b: String) -> Bool {
    let strip = { (url: String) in url.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? url }
    return strip(a) == strip(b)
  }

  static func bind(_ key: String) { bound.insert(key) }

  static func take(profile: String, key: String, url: String) -> Saved? {
    guard !bound.contains(key), let file = file(profile, key: key) else { return nil }
    let read: Saved? = files.sync {
      guard let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.count <= maxBytes,
        let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any], saved["version"] as? Int == version,
        let savedURL = saved["url"] as? String, let encoded = saved["state"] as? String, let state = Data(base64Encoded: encoded)
      else { return nil }
      return Saved(url: savedURL, state: state)
    }
    guard let read, samePage(read.url, url) else { return nil }
    return read
  }

  static func scheduleSave(_ tab: WebKitTab) {
    guard let key = tab.transferKey, file(tab.profile, key: key) != nil else { return }
    _ = flushAtQuit
    tab.life.historySave?.cancel()
    let work = DispatchWorkItem { [weak tab] in tab.map(saveNow) }
    tab.life.historySave = work
    waiting[ObjectIdentifier(tab)] = tab
    DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay, execute: work)
  }

  static func flush(_ tab: WebKitTab) {
    guard tab.life.historySave != nil else { return }
    saveNow(tab)
  }

  static func saveNow(_ tab: WebKitTab) {
    tab.life.historySave?.cancel()
    tab.life.historySave = nil
    waiting.removeValue(forKey: ObjectIdentifier(tab))
    guard let key = tab.transferKey, let file = file(tab.profile, key: key) else { return }
    let url: String
    let state: Data
    if let page = tab.life.discarded {
      guard let saved = page.state as? Data else { return }
      url = page.url
      state = saved
    } else {
      guard let view = tab.webView, let current = view.backForwardList.currentItem, let saved = view.interactionState as? Data else { return }
      url = current.url.absoluteString
      state = saved
    }
    bound.insert(key)
    let directory = file.deletingLastPathComponent()
    let profile = tab.profile
    let prune = pruned.insert(profile).inserted
    files.async {
      let body: [String: Any] = ["version": version, "url": url, "state": state.base64EncodedString()]
      guard let data = try? JSONSerialization.data(withJSONObject: body), data.count <= maxBytes else { return }
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try? data.write(to: file, options: .atomic)
      if prune { pruneOld(in: directory) }
    }
  }

  private static func flushAll() {
    for tab in Array(waiting.values) { saveNow(tab) }
    files.sync {}
  }

  private static func pruneOld(in directory: URL) {
    let cutoff = Date().addingTimeInterval(-keepFor)
    let names = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    for name in names where ((try? name.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture) < cutoff {
      try? FileManager.default.removeItem(at: name)
    }
  }

  static func cleared(profile: String, live: [WebKitTab]) {
    guard let directory = directory(profile) else { return }
    files.async { try? FileManager.default.removeItem(at: directory) }
    for tab in live where tab.profile == profile { scheduleSave(tab) }
  }

  static func forget(profile: String) {
    guard let directory = directory(profile) else { return }
    files.async { try? FileManager.default.removeItem(at: directory) }
  }
}

extension WebKitTab {
  private static let suspendSelector = NSSelectorFromString("_suspendPage:")
  private static let resumeSelector = NSSelectorFromString("_resumePage:")
  private static let killSelector = NSSelectorFromString("_killWebContentProcess")
  private static let responsiveKey = "_webProcessIsResponsive"
  private static let processKey = "_webProcessIdentifier"
  private static let waitBeforeAskingAgain = 15.0

  func makeView() -> WebKitWebView {
    WebKitWebView(frame: bounds, configuration: WebKitHub.shared.configuration(profile: profile))
  }

  func startFirstPage(_ url: String, in view: WebKitWebView) {
    if skipsNavigationDownload(url) { return }
    if restoreSavedHistory(url, in: view) { return }
    loadWhenBlockerReady(url, in: view)
  }

  private func restoreSavedHistory(_ url: String, in view: WebKitWebView) -> Bool {
    let restoreKey = adoptId.flatMap { $0.hasPrefix("restore:") ? String($0.dropFirst("restore:".count)) : nil }
    let keys = [restoreKey, transferKey].compactMap { $0 }
    guard let saved = keys.lazy.compactMap({ WebKitTabHistory.take(profile: self.profile, key: $0, url: url) }).first else { return false }
    if let key = transferKey { WebKitTabHistory.bind(key) }
    restoreState(saved.state, orLoad: url, in: view)
    ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "historyRestored"]))
    return true
  }

  private func restoreState(_ state: Any, orLoad url: String, in view: WebKitWebView) {
    WebKitContentBlocker.shared.whenReady(within: 1) { [weak self, weak view] in
      guard let self, let view, self.webView === view, view.url == nil, !view.isLoading else { return }
      view.interactionState = state
      if view.backForwardList.currentItem == nil { self.loadURL(url, userInitiated: false) }
    }
  }

  func discardPage(unload: Bool) -> String {
    if unload { return Self.unsupported }
    if life.discarded != nil { return "already" }
    guard !closed, let view = webView, let url = view.url?.absoluteString, !url.isEmpty else { return "refused" }
    let state = view.interactionState
    life.discarded = WebKitDiscardedPage(state: state, url: url)
    life.unresponsiveRecheck?.cancel()
    life.unresponsive = false
    life.suspended = false
    WebKitTabHistory.scheduleSave(self)
    WebKitTabHistory.flush(self)
    cancelDialogs()
    WebKitHub.shared.permissions.drop(browserId: browserId)
    WebKitHub.shared.logins.forget(self)
    WebKitAutofill.shared.forget(self)
    pageMedia = WebKitPageMedia()
    if let dropped = dropViewForDiscard() { WebKitHub.close(dropped) }
    emit("discarded", ["url": url, "reason": "external"])
    ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "discard"]))
    return "discarded"
  }

  @discardableResult
  func wakeDiscarded(loading url: String? = nil) -> Bool {
    guard !closed, let page = life.discarded else { return false }
    life.discarded = nil
    let view = makeView()
    attach(view)
    emit("ready", [:])
    ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "discardWake"]))
    if let state = page.state, url == nil {
      restoreState(state, orLoad: page.url, in: view)
    } else if let state = page.state {
      view.interactionState = state
      loadURL(url ?? page.url, userInitiated: true)
    } else {
      loadURL(url ?? page.url, userInitiated: false)
    }
    return true
  }

  func wakeIfShown(was shown: Bool) {
    if visible && !shown { wakeDiscarded() }
  }

  func lifecycleWatches(_ view: WebKitWebView) -> [NSObject] {
    if life.frozen { applyFrozen() }
    return [view.observe(\.fullscreenState) { [weak self] v, _ in self?.fullscreenChanged(v.fullscreenState) }]
  }

  private func fullscreenChanged(_ state: WKWebView.FullscreenState) {
    let on = state == .enteringFullscreen || state == .inFullscreen
    guard on != pageMedia.fullscreen else { return }
    pageMedia.fullscreen = on
    if on { ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "fullscreen"])) }
    emit("fullscreen", ["fullscreen": on])
  }

  var pageFrozen: Bool {
    get { life.frozen }
    set {
      guard newValue != life.frozen else { return }
      life.frozen = newValue
      applyFrozen()
    }
  }

  private func applyFrozen() {
    guard let view = webView, life.frozen != life.suspended else { return }
    let selector = life.frozen ? Self.suspendSelector : Self.resumeSelector
    guard view.responds(to: selector) else { return }
    life.suspended = life.frozen
    typealias PageCall = @convention(c) (AnyObject, Selector, @escaping @convention(block) (Bool) -> Void) -> Void
    unsafeBitCast(view.method(for: selector), to: PageCall.self)(view, selector, { _ in })
  }

  @objc(_webViewWebProcessDidBecomeUnresponsive:)
  func webViewWebProcessDidBecomeUnresponsive(_ webView: WKWebView) {
    guard webView === self.webView, !life.unresponsive else { return }
    life.unresponsive = true
    ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "unresponsive"]))
    emit("unresponsive", [:])
  }

  @objc(_webViewWebProcessDidBecomeResponsive:)
  func webViewWebProcessDidBecomeResponsive(_ webView: WKWebView) {
    guard webView === self.webView else { return }
    life.unresponsiveRecheck?.cancel()
    life.unresponsiveRecheck = nil
    guard life.unresponsive else { return }
    life.unresponsive = false
    emit("responsive", [:])
  }

  func processTerminated() {
    life.unresponsiveRecheck?.cancel()
    life.unresponsiveRecheck = nil
    guard life.unresponsive else { return }
    life.unresponsive = false
    emit("responsive", [:])
  }

  func resolveHang(terminate: Bool) {
    guard let view = webView, life.unresponsive else { return }
    life.unresponsiveRecheck?.cancel()
    if terminate {
      life.unresponsive = false
      ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "unresponsiveEnded"]))
      let pid = view.responds(to: NSSelectorFromString(Self.processKey)) ? (view.value(forKey: Self.processKey) as? NSNumber)?.int32Value ?? 0 : 0
      if pid > 0 { kill(pid, SIGKILL) } else if view.responds(to: Self.killSelector) { view.perform(Self.killSelector) }
      return
    }
    let work = DispatchWorkItem { [weak self, weak view] in
      guard let self, let view, view === self.webView, self.life.unresponsive else { return }
      guard view.responds(to: NSSelectorFromString(Self.responsiveKey)) else { return }
      if (view.value(forKey: Self.responsiveKey) as? Bool) == false { self.emit("unresponsive", [:]) }
    }
    life.unresponsiveRecheck = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.waitBeforeAskingAgain, execute: work)
  }

  func lifecycleEnded() {
    life.unresponsiveRecheck?.cancel()
    life.unresponsiveRecheck = nil
    WebKitTabHistory.flush(self)
  }

  func skipsNavigationDownload(_ url: String) -> Bool {
    guard ArdiaHost.wasNavigationDownload(url, profile: profile) else { return false }
    ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "downloadSkipped"]))
    DispatchQueue.main.async { [weak self] in self?.emit("downloadNavigation", ["url": url, "committedUrl": "", "skipped": true]) }
    return true
  }

  func noteNavigationDownload(_ download: WKDownload, from webView: WKWebView) {
    if let url = download.originalRequest?.url?.absoluteString { ArdiaHost.noteNavigationDownload(url, profile: profile) }
    if webView.backForwardList.currentItem == nil, let first = initialURL, !first.isEmpty { ArdiaHost.noteNavigationDownload(first, profile: profile) }
  }
}
