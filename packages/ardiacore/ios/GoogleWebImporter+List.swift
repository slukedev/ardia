import Foundation

enum GoogleListReply: Sendable {
  case sites([GoogleListSite])
  case refused(GoogleWebVerdict)
  case failed(GoogleImportError)
}

extension GoogleWebImporter {
  final class ListJob {
    let byPerson: Bool
    let generation: Int
    var failure: GoogleImportError?

    init(byPerson: Bool, generation: Int) {
      self.byPerson = byPerson
      self.generation = generation
    }
  }

  var isBusy: Bool { running != nil || !queue.isEmpty || exporting != nil || listing != nil || signInPage != nil }

  func list(byPerson: Bool) async -> GoogleListReply {
    if byPerson {
      let deadline = Date().addingTimeInterval(Self.personWaitForImports)
      while isBusy, Date() < deadline { try? await Task.sleep(nanoseconds: Self.pollInterval) }
    }
    let now = Date()
    let verdict = listLimits.verdict(byPerson: byPerson, now: now, busy: isBusy, lastExport: limits.lastSuccess, held: limits.held != nil)
    guard verdict == .go else {
      if byPerson { NSLog("[vaults] google read refused: %@", String(describing: verdict)) }
      return .refused(verdict)
    }
    let job = ListJob(byPerson: byPerson, generation: generation)
    listing = job
    listLimits.started(now)
    NSLog("[vaults] google read started (%@)", byPerson ? "person" : "automatic")
    let reply = await runList(job)
    listing = nil
    switch reply {
    case .sites(let sites):
      listLimits.succeeded(Date())
      listFailure = nil
      NSLog("[vaults] google read listed %d site(s)", sites.count)
    case .failed(let error):
      NSLog("[vaults] google read failed: %@", error.rawValue)
      if ![.cancelled, .notAllowed, .checkTooSoon].contains(error) { listFailure = error }
      if error.holdsAutomaticActivity {
        limits.failed(error, now: Date())
        saveLimits()
      }
    case .refused:
      break
    }
    pump()
    guard job.generation == generation else { return .failed(.cancelled) }
    return reply
  }

  private func runList(_ job: ListJob) async -> GoogleListReply {
    let site = Self.site
    guard let page = ArdiaHiddenPage.open(url: site.listURL, profile: Self.profile, config: "{}") else { return .failed(.unavailable) }
    page.blockDownloads(from: GoogleImportSite.origin(of: site.passwords) ?? site.passwords)
    defer { page.close() }
    page.onFail = { [weak job] url, code in
      MainActor.assumeIsolated {
        guard let job, code != Self.abortedLoad, site.isPasswords(url) || site.isAccounts(url) else { return }
        if job.failure == nil { job.failure = code == Self.rendererGone ? .unavailable : .network }
      }
    }
    var flow = GoogleListFlow(started: Date())
    while true {
      try? await Task.sleep(nanoseconds: Self.pollInterval)
      if job.generation != generation { return .failed(.cancelled) }
      if let failure = job.failure { return .failed(failure) }
      if page.closed { return .failed(.cancelled) }
      let snapshot = GoogleListSnapshot.parse(await evaluate(page, GoogleListScripts.snapshot()))
      switch flow.step(snapshot, site: site, now: Date()) {
      case .wait: continue
      case .finish(let sites): return .sites(sites)
      case .fail(let error): return .failed(error)
      }
    }
  }

  func takeFreshRows() -> [GoogleExportRow]? {
    defer { freshRows = nil }
    return freshRows
  }
}
