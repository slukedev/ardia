import AppKit

enum PictureInPictureAnswer {
  case opened
  case nothingPlaying
  case failed
}

extension WebKitTab {
  private static let leftAppKey = "leftApp"
  private static let playsHandlerInstalled: Void = {
    ArdiaChromeWindowHost.playsForAutoPictureInPictureHandler = { window in
      WebKitHub.shared.transfers.liveTabs.contains { $0.window === window && $0.visible && $0.playsForAutoPictureInPicture }
    }
  }()

  var autoPictureInPictureRule: WebKitAutoPictureInPicture {
    get { webView?.autoPictureInPictureRule ?? WebKitAutoPictureInPicture() }
    set { webView?.autoPictureInPictureRule = newValue }
  }

  private var playsMedia: Bool {
    guard let view = webView else { return false }
    return !playingFrames.isEmpty || view.cameraCaptureState == .active || view.microphoneCaptureState == .active
  }

  var playsForAutoPictureInPicture: Bool { autoPictureInPicture && playsMedia }

  func watchSight() {
    stopWatchingSight()
    guard !closed, let window else { return }
    _ = Self.playsHandlerInstalled
    sightObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name.ArdiaWindowSeenDidChange, object: window, queue: .main) { [weak self] note in
      self?.updateSight()
      if (note.userInfo?[Self.leftAppKey] as? Bool) == true { self?.noteStayedOnAppSwitch() }
    }
    updateSight()
  }

  func stopWatchingSight() {
    if let sightObserver { NotificationCenter.default.removeObserver(sightObserver) }
    sightObserver = nil
  }

  private var seenByUser: Bool {
    guard let window else { return false }
    return visible && ArdiaChromeWindowHost.userSees(window)
  }

  func updateSight() {
    guard !closed, let window else { return }
    let seen = seenByUser
    let kept = seen && ArdiaChromeWindowHost.userSeesOnlyThroughWindowServer(window)
    if !kept {
      pageMedia.keptByWindowServer = false
    } else if !pageMedia.keptByWindowServer && playsForAutoPictureInPicture {
      pageMedia.keptByWindowServer = true
      emit("autoPictureInPictureKept", ArdiaConsentStamp.begin().onto(["appSwitch": false]))
    }
    switch autoPictureInPictureRule.sight(seen, enabled: autoPictureInPicture, playing: playsMedia) {
    case .open:
      let stamp = ArdiaConsentStamp.begin()
      setPictureInPicture(true, automatic: true) { [weak self] answer in if answer == .nothingPlaying { self?.emit("autoPictureInPictureKept", stamp.onto(["reason": "nothingPlaying"])) } }
    case .close: setPictureInPicture(false) { _ in }
    case .none: break
    }
  }

  private func noteStayedOnAppSwitch() {
    guard !closed, visible, !autoPictureInPictureRule.reportedActive, seenByUser, playsForAutoPictureInPicture else { return }
    emit("autoPictureInPictureKept", ArdiaConsentStamp.begin().onto(["appSwitch": true]))
  }

  func autoPictureInPictureInputsChanged() {
    let plays = playsForAutoPictureInPicture
    guard plays != pageMedia.playedForAutoPictureInPicture else { return }
    pageMedia.playedForAutoPictureInPicture = plays
    guard let window else { return }
    ArdiaChromeWindowHost.reconsiderSight(of: window)
    updateSight()
  }
}
