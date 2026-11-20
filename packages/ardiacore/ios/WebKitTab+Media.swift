import AppKit
import WebKit

final class WebKitKeyWatch: NSObject {
  private let object: NSObject
  private let key: String
  private let changed: () -> Void

  init?(_ object: NSObject, key: String, changed: @escaping () -> Void) {
    guard object.responds(to: NSSelectorFromString(key)) else { return nil }
    self.object = object
    self.key = key
    self.changed = changed
    super.init()
    object.addObserver(self, forKeyPath: key, options: [], context: nil)
  }

  deinit {
    object.removeObserver(self, forKeyPath: key)
  }

  override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
    changed()
  }
}

struct WebKitPageMedia {
  var soundBlocked = false
  var soundRuleOrigin: String?
  var soundRuleGeneration = 0
  var webAudioCounted = false
  var fullscreen = false
  var keptByWindowServer = false
  var playedForAutoPictureInPicture = false
}

extension WebKitWebView {
  private static let setPageMutedSelector = NSSelectorFromString("_setPageMuted:")
  private static let mutedStateSelector = NSSelectorFromString("_mediaMutedState")
  static let playingAudioKey = "_isPlayingAudio"
  static let mutesPage = WKWebView.instancesRespond(to: setPageMutedSelector) && WKWebView.instancesRespond(to: mutedStateSelector)
  static let reportsAudio = WKWebView.instancesRespond(to: NSSelectorFromString(playingAudioKey))
  private static let audioMutedFlag: UInt = 1

  func setAudioMuted(_ on: Bool) {
    guard Self.mutesPage else { return }
    typealias MutedState = @convention(c) (AnyObject, Selector) -> UInt
    typealias SetPageMuted = @convention(c) (AnyObject, Selector, UInt) -> Void
    let current = unsafeBitCast(method(for: Self.mutedStateSelector), to: MutedState.self)(self, Self.mutedStateSelector)
    let silenced = on || WebKitHub.silenced
    let next = silenced ? current | Self.audioMutedFlag : current & ~Self.audioMutedFlag
    guard next != current else { return }
    unsafeBitCast(method(for: Self.setPageMutedSelector), to: SetPageMuted.self)(self, Self.setPageMutedSelector, next)
  }

  var playsAudio: Bool { Self.reportsAudio && (value(forKey: Self.playingAudioKey) as? Bool ?? false) }
}

extension WebKitTab {
  private static let pageMuteFallbackCounted: Void = {
    if !WebKitWebView.mutesPage || !WebKitWebView.reportsAudio { ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "pageMuteFallback"])) }
  }()

  var effectiveMuted: Bool { muted || pageMedia.soundBlocked }

  var audible: Bool {
    guard let view = webView else { return false }
    return WebKitWebView.reportsAudio ? view.playsAudio : !playingFrames.isEmpty
  }

  func mediaWatches(_ view: WebKitWebView) -> [NSObject] {
    _ = Self.pageMuteFallbackCounted
    let audio = WebKitKeyWatch(view, key: WebKitWebView.playingAudioKey) { [weak self] in self?.audioChanged() }
    return (audio.map { [$0] } ?? []) + lifecycleWatches(view)
  }

  private func audioChanged() {
    guard let view = webView else { return }
    if view.playsAudio, playingFrames.isEmpty, !pageMedia.webAudioCounted {
      pageMedia.webAudioCounted = true
      ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "webAudioAudible"]))
    }
    emitMedia()
  }

  func emitMedia() {
    emit("media", ["playing": audible, "muted": effectiveMuted])
    autoPictureInPictureInputsChanged()
  }

  func applyMute() {
    guard let view = webView else { return }
    if WebKitWebView.mutesPage {
      view.setAudioMuted(effectiveMuted)
    } else {
      let code = muteScript
      runInWorld(code)
      for frame in mediaFrames.values where !frame.isMainFrame { runInWorld(code, frame: frame) }
    }
  }

  var muteScript: String { "window.__ardia && window.__ardia.mute(\(effectiveMuted ? "true" : "false"))" }

  func audioCommitted() {
    pageMedia.webAudioCounted = false
    checkSoundRule()
    if !WebKitWebView.mutesPage, effectiveMuted { applyMute() }
  }

  func checkSoundRule() {
    let origin = webView?.url.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? Origins.of($0) : nil }
    pageMedia.soundRuleGeneration += 1
    let generation = pageMedia.soundRuleGeneration
    pageMedia.soundRuleOrigin = origin
    guard let origin else { return setSoundBlocked(false) }
    WebKitHub.shared.permissions.soundBlocked(profile: profile, origin: origin) { [weak self] blocked in
      guard let self, !self.closed, self.pageMedia.soundRuleGeneration == generation else { return }
      self.setSoundBlocked(blocked)
    }
  }

  private func setSoundBlocked(_ blocked: Bool) {
    guard blocked != pageMedia.soundBlocked else { return }
    pageMedia.soundBlocked = blocked
    if blocked { ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "soundRuleMuted"])) }
    applyMute()
    emitMedia()
  }
}
