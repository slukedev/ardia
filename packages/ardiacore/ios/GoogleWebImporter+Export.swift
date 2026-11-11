import Foundation

extension GoogleWebImporter {
  func export(trigger: GoogleWebTrigger, password: String?) async -> GoogleExportReply {
    if let job = exporting, trigger.byPerson, let person = job.person { return .confirm(id: job.id, error: person) }
    if trigger.byPerson {
      let deadline = Date().addingTimeInterval(Self.personWaitForImports)
      while running != nil || !queue.isEmpty || listing != nil, Date() < deadline { try? await Task.sleep(nanoseconds: Self.pollInterval) }
    }
    let now = Date()
    let admission = limits.admission(trigger, now: now, busy: running != nil || exporting != nil || listing != nil || signInPage != nil, raptSeen: rapt?.seen)
    guard admission.verdict == .go else {
      if trigger != .use { NSLog("[vaults] google export refused (%@): %@", trigger.rawValue, String(describing: admission.verdict)) }
      return .refused(admission.verdict)
    }
    let job = ExportJob(trigger: trigger, generation: generation, mayAnswerCheck: admission.mayAnswerCheck)
    exporting = job
    limits.started(now)
    saveLimits()
    NSLog("[vaults] google export started (%@)", trigger.rawValue)
    return await withCheckedContinuation { waiter in
      job.waiters.append(waiter)
      Task {
        let reply = await runExport(job, password: password)
        finishExport(job, reply)
      }
    }
  }

  func runExport(_ job: ExportJob, password given: String?) async -> GoogleExportReply {
    let site = Self.site
    let passwordsOrigin = GoogleImportSite.origin(of: site.passwords) ?? site.passwords
    let config = VaultJSON.text(["fileImport": true, "csvExport": true, "csvExportOrigin": passwordsOrigin])
    let usedRapt = rapt
    guard let page = ArdiaHiddenPage.open(url: GoogleRapt.url(site.optionsURL, adding: usedRapt), profile: Self.profile, config: config) else {
      return .failed(.unavailable)
    }
    job.page = page
    page.blockDownloads(from: passwordsOrigin)
    defer {
      page.close()
      job.page = nil
    }
    page.onMessage = { [weak job, weak page] kind, json, origin, _ in
      MainActor.assumeIsolated {
        guard let job, let page else { return }
        if kind == "csvExport" {
          guard GoogleImportSite.origin(of: origin) == passwordsOrigin, job.csv == nil else { return }
          let message = VaultJSON.dict(VaultJSON.parse(Data(json.utf8)))
          job.csv = message.flatMap { VaultJSON.string($0["text"]) }
        } else if kind == "fileChooser" {
          let request = VaultJSON.dict(VaultJSON.parse(Data(json.utf8)))
          page.send("fileImport", json: VaultJSON.text(["id": request.flatMap { VaultJSON.string($0["id"]) } ?? "", "refused": true]))
        }
      }
    }
    page.onCommit = { [weak self] url in MainActor.assumeIsolated { self?.noteRapt(url, site: site) } }
    page.onFail = { [weak job] url, code in
      MainActor.assumeIsolated {
        guard let job, code != Self.abortedLoad, site.isPasswords(url) || site.isAccounts(url) else { return }
        if job.failure == nil { job.failure = code == Self.rendererGone ? .unavailable : .network }
      }
    }
    var flow = GoogleExportFlow(started: Date(), mayAnswerCheck: job.mayAnswerCheck)
    var password = given
    var lastSnapshot: GoogleImportSnapshot?
    while true {
      try? await Task.sleep(nanoseconds: Self.pollInterval)
      if let failure = job.failure { return .failed(failure) }
      if page.closed { return .failed(.cancelled) }
      let snapshot = job.csv == nil ? await snapshot(page) : nil
      if let snapshot { lastSnapshot = snapshot }
      let stage = snapshot.map { GoogleImportClassifier.classify($0, site: site) } ?? .loading
      switch flow.step(stage, exportButton: snapshot?.exportButton == true, captured: job.csv != nil, now: Date()) {
      case .wait:
        continue
      case .clickExport:
        _ = await click(page, .exportButton)
      case .clickConfirmExport:
        _ = await click(page, .confirmExport)
      case .fillPassword:
        if password == nil {
          switch await GoogleAccountPassword.read() {
          case .success(let stored): password = stored.password
          case .failure(let error): return .failed(error)
          }
        }
        guard let password, site.isAccounts(page.url) else { continue }
        if usedRapt != nil, rapt == usedRapt { rapt = nil }
        limits.answeredCheck(Date())
        saveLimits()
        let message: [String: Any] = [
          "id": job.id, "origin": GoogleImportSite.origin(of: page.url) ?? "", "password": password,
          "fields": GoogleImportSelectors.current.passwordFields, "next": GoogleImportSelectors.current.nextButtons,
          "nextText": GoogleImportSelectors.current.nextText,
        ]
        page.send("fileImportFill", json: VaultJSON.text(message))
      case .finish:
        noteRapt(page.url, site: site)
        guard let csv = job.csv, let rows = GoogleExportCSV.rows(csv) else { return .failed(.pageChanged) }
        return .list(rows)
      case .needPerson(let error):
        guard job.trigger.byPerson else { return .failed(error) }
        if job.person == nil {
          job.person = error
          flow.personStarted(Date())
          answerExport(job, .confirm(id: job.id, error: error))
          emitExport(job, state: "confirm", error: error)
        }
      case .fail(let error):
        if error == .checkTooSoon, rapt == usedRapt { rapt = nil }
        NSLog("[vaults] google export stopped at %@", Self.describe(lastSnapshot, stage: stage, url: page.url))
        return .failed(error)
      }
    }
  }

  func finishExport(_ job: ExportJob, _ reply: GoogleExportReply) {
    let now = Date()
    switch reply {
    case .list(let rows):
      limits.succeeded(now)
      listFailure = nil
      if job.generation == generation {
        latestRows = rows
        freshRows = rows
        NSLog("[vaults] google export read %d row(s)", rows.count)
      } else {
        NSLog("[vaults] google export finished after a lock; its list was dropped")
      }
      emitExport(job, state: "saved", error: nil)
    case .failed(let error):
      limits.failed(error, now: now)
      NSLog("[vaults] google export failed: %@", error.rawValue)
      emitExport(job, state: "failed", error: error)
    case .refused, .confirm:
      break
    }
    saveLimits()
    job.csv = nil
    exporting = nil
    let unanswered = job.waiters.isEmpty && job.generation == generation
    answerExport(job, reply)
    if unanswered, case .list = reply { Task { await VaultBroker.shared.googleListChanged() } }
    pump()
  }

  func answerExport(_ job: ExportJob, _ reply: GoogleExportReply) {
    let waiters = job.waiters
    job.waiters = []
    for waiter in waiters { waiter.resume(returning: reply) }
  }

  func emitExport(_ job: ExportJob, state: String, error: GoogleImportError?) {
    var payload: [String: Any] = ["provider": GooglePasswordManagerVault.providerId, "id": job.id, "state": state, "trigger": job.trigger.rawValue]
    if let error {
      payload["code"] = error.rawValue
      payload["message"] = error.message
    }
    ArdiaEvents.emit("vaults.googleExport", data: payload)
  }

  static func describe(_ snapshot: GoogleImportSnapshot?, stage: GoogleImportStage, url: String) -> String {
    let address = URLComponents(string: snapshot?.url ?? url).map { "\($0.host ?? "")\($0.path)" } ?? ""
    guard let snapshot else { return "\(stage) \(address) no snapshot" }
    let buttons = snapshot.dialogButtons.joined(separator: "|")
    return "\(stage) \(address) ready=\(snapshot.ready) export=\(snapshot.exportButton.map(String.init) ?? "nil") dialog=\(snapshot.dialog ?? "nil") buttons=\(buttons) text=\(snapshot.text.count)"
  }
}
