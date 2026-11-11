import Foundation

enum GoogleExportReply: Sendable {
  case list([GoogleExportRow])
  case refused(GoogleWebVerdict)
  case confirm(id: String, error: GoogleImportError)
  case failed(GoogleImportError)
}

enum GoogleImportReply: Sendable {
  case saved(Int)
  case confirm(id: String, error: GoogleImportError)
  case failed(GoogleImportError)
}

@MainActor
final class GoogleWebImporter {
  static let shared = GoogleWebImporter()

  static let profile = ""
  static let pollInterval: UInt64 = 300_000_000
  static let signInCheckLimit: TimeInterval = 20
  static let evaluateTimeout: TimeInterval = 5
  static let reconcileDelay: TimeInterval = 10
  static let reconcileRetries = 3
  static let signInPageLifetime: TimeInterval = 120
  static let personWaitForImports: TimeInterval = 90
  private static let importConfig = #"{"fileImport":true}"#
  private static let limitsFile = "google-web-limits.json"
  static let abortedLoad = -3
  static let rendererGone = -1

  static var site: GoogleImportSite {
    let config = LaunchConfig.shared
    guard config.background, VaultSandbox.directory != nil,
      let passwords = config.testValue("googlePasswordsURL").flatMap(GoogleImportSite.origin(of:)),
      let accounts = config.testValue("googleAccountsURL").flatMap(GoogleImportSite.origin(of:))
    else { return .google }
    return GoogleImportSite(passwords: passwords, accounts: accounts)
  }

  final class Job {
    let id = UUID().uuidString.lowercased()
    let key: String
    let host: String
    let csv: String
    let accountPassword: String?
    var waiters: [CheckedContinuation<GoogleImportReply, Never>] = []
    var page: ArdiaHiddenPage?
    var person: GoogleImportError?
    var failure: GoogleImportError?
    var filesGiven = 0

    init(key: String, host: String, csv: String, accountPassword: String?) {
      self.key = key
      self.host = host
      self.csv = csv
      self.accountPassword = accountPassword
    }
  }

  final class ExportJob {
    let id = UUID().uuidString.lowercased()
    let trigger: GoogleWebTrigger
    let generation: Int
    let mayAnswerCheck: Bool
    var page: ArdiaHiddenPage?
    var csv: String?
    var failure: GoogleImportError?
    var person: GoogleImportError?
    var waiters: [CheckedContinuation<GoogleExportReply, Never>] = []

    init(trigger: GoogleWebTrigger, generation: Int, mayAnswerCheck: Bool) {
      self.trigger = trigger
      self.generation = generation
      self.mayAnswerCheck = mayAnswerCheck
    }
  }

  var queue: [Job] = []
  var running: Job?
  var exporting: ExportJob?
  var rapt: GoogleRapt?
  lazy var limits: GoogleWebLimits = Self.loadLimits()
  var latestRows: [GoogleExportRow]?
  var freshRows: [GoogleExportRow]?
  var listing: ListJob?
  var listLimits = GoogleListLimits()
  var listFailure: GoogleImportError?
  var signInPage: ArdiaHiddenPage?
  private var signInWatch: Task<Void, Never>?
  private var signInExpiry: Task<Void, Never>?
  private var finals: [String: GoogleImportReply] = [:]
  private var finalOrder: [String] = []
  private var finalWaiters: [String: [CheckedContinuation<GoogleImportReply, Never>]] = [:]
  var generation = 0
  private var reconcileTask: Task<Void, Never>?
  private var reconcileRuns = 0

  func outcome(_ id: String) async -> Bool {
    if case .saved = await finalReply(id) { return true }
    return false
  }

  func finalReply(_ id: String) async -> GoogleImportReply {
    if let known = finals[id] { return known }
    guard ([running].compactMap { $0 } + queue).contains(where: { $0.id == id }) else { return .failed(.cancelled) }
    return await withCheckedContinuation { finalWaiters[id, default: []].append($0) }
  }

  func save(url: String, username: String, password: String, title: String, accountPassword: String? = nil) async -> GoogleImportReply {
    let job = job(url: url, username: username, password: password, title: title, accountPassword: accountPassword)
    if let person = job.person { return .confirm(id: job.id, error: person) }
    return await withCheckedContinuation { waiter in
      job.waiters.append(waiter)
      pump()
    }
  }

  func enqueue(url: String, username: String, password: String, title: String, accountPassword: String?) -> String {
    let job = job(url: url, username: username, password: password, title: title, accountPassword: accountPassword)
    pump()
    return job.id
  }

  private func job(url: String, username: String, password: String, title: String, accountPassword: String?) -> Job {
    let key = GoogleImportCSV.dedupeKey(url: url, username: username, password: password)
    if let pending = ([running].compactMap { $0 } + queue).first(where: { $0.key == key && $0.failure == nil }) { return pending }
    let job = Job(
      key: key, host: VaultOriginMatch.host(of: url) ?? title, csv: GoogleImportCSV.make(name: title, url: url, username: username, password: password),
      accountPassword: accountPassword)
    queue.append(job)
    return job
  }

  func reveal(_ id: String?) -> Bool {
    if let id, let job = running, job.id == id, let page = job.page {
      return page.reveal(withTitle: "Confirm It's You") { [weak self] in MainActor.assumeIsolated { self?.cancel(job) } }
    }
    if let id, let job = exporting, job.id == id, let page = job.page {
      return page.reveal(withTitle: "Confirm It's You") { [weak job] in MainActor.assumeIsolated { if job?.failure == nil, job?.csv == nil { job?.failure = .cancelled } } }
    }
    return revealSignIn()
  }

  func checkSignIn() async -> String {
    let site = Self.site
    let page = signInPage ?? ArdiaHiddenPage.open(url: site.optionsURL, profile: Self.profile, config: "{}")
    guard let page else { return "unavailable" }
    signInPage = page
    let started = Date()
    while Date().timeIntervalSince(started) < Self.signInCheckLimit, !page.closed {
      try? await Task.sleep(nanoseconds: Self.pollInterval)
      guard let snapshot = await snapshot(page) else { continue }
      switch GoogleImportClassifier.classify(snapshot, site: site) {
      case .options, .confirmExport, .preparing, .selectFile, .readyToImport, .imported, .importFailed, .onDeviceEncryption:
        closeSignIn()
        return "signedIn"
      case .signIn, .twoStep, .captcha, .unusualActivity, .passwordChallenge:
        closeSignInLater(page)
        return "signIn"
      case .insecureBrowser:
        closeSignIn()
        return "insecureBrowser"
      case .loading, .elsewhere:
        continue
      }
    }
    closeSignIn()
    return "network"
  }

  func dropLatest() {
    generation += 1
    latestRows = nil
    freshRows = nil
    reconcileTask?.cancel()
    reconcileTask = nil
    if let job = exporting, job.failure == nil { job.failure = .cancelled }
  }

  func forget() {
    dropLatest()
    closeSignIn()
    rapt = nil
    limits = GoogleWebLimits()
    listLimits = GoogleListLimits()
    listFailure = nil
    saveLimits()
    let dropped = queue
    queue = []
    for job in dropped {
      job.failure = .cancelled
      finish(job, .failed(.cancelled))
    }
    if let job = running, job.failure == nil { job.failure = .cancelled }
  }

  var lastRefresh: Date? { [limits.lastSuccess, listLimits.lastSuccess].compactMap { $0 }.max() }

  var heldBy: GoogleImportError? { limits.held }
  var failedWith: GoogleImportError? {
    if let listFailure { return listFailure }
    guard limits.failures > 0, let error = limits.lastError else { return nil }
    if let read = listLimits.lastSuccess, let failed = limits.lastFailure, read > failed { return nil }
    return error
  }

  func personConfirmed() {
    limits.personConfirmed()
    saveLimits()
  }

  private func revealSignIn() -> Bool {
    let site = Self.site
    if signInPage == nil { signInPage = ArdiaHiddenPage.open(url: site.signInURL, profile: Self.profile, config: "{}") }
    guard let page = signInPage else { return false }
    let shown = page.reveal(withTitle: "Sign In to Google") { [weak self] in MainActor.assumeIsolated { self?.closeSignIn() } }
    signInWatch?.cancel()
    signInWatch = Task { [weak self] in
      while !Task.isCancelled, !page.closed {
        try? await Task.sleep(nanoseconds: Self.pollInterval)
        guard let self, let snapshot = await self.snapshot(page) else { continue }
        if site.isPasswords(snapshot.url) {
          self.closeSignIn()
          ArdiaEvents.emit("vaults.googleSignIn", data: ["provider": GooglePasswordManagerVault.providerId, "signedIn": true])
          return
        }
      }
    }
    return shown
  }

  private func closeSignInLater(_ page: ArdiaHiddenPage) {
    signInExpiry?.cancel()
    signInExpiry = Task { [weak self, weak page] in
      try? await Task.sleep(nanoseconds: UInt64(Self.signInPageLifetime * 1_000_000_000))
      guard !Task.isCancelled, let self, let page, self.signInPage === page, !page.revealed else { return }
      NSLog("[vaults] google sign-in check page closed unused")
      self.closeSignIn()
    }
  }

  private func closeSignIn() {
    signInExpiry?.cancel()
    signInExpiry = nil
    signInWatch?.cancel()
    signInWatch = nil
    signInPage?.close()
    signInPage = nil
  }

  private func cancel(_ job: Job) {
    if job.failure == nil { job.failure = .cancelled }
  }

  func pump() {
    guard running == nil, exporting == nil, listing == nil, !queue.isEmpty else { return }
    let job = queue.removeFirst()
    running = job
    Task {
      let reply = await run(job)
      finish(job, reply)
      running = nil
      pump()
    }
  }

  private func run(_ job: Job) async -> GoogleImportReply {
    let site = Self.site
    let usedRapt = rapt
    guard let page = ArdiaHiddenPage.open(url: GoogleRapt.url(site.importURL, adding: usedRapt), profile: Self.profile, config: Self.importConfig) else {
      return .failed(.unavailable)
    }
    job.page = page
    page.blockDownloads(from: GoogleImportSite.origin(of: site.passwords) ?? site.passwords)
    page.onCommit = { [weak self] url in MainActor.assumeIsolated { self?.noteRapt(url, site: site) } }
    defer {
      page.close()
      job.page = nil
    }
    page.onMessage = { [weak self, weak job, weak page] kind, json, origin, _ in
      MainActor.assumeIsolated {
        guard let self, let job, let page else { return }
        self.pageMessage(job, page: page, kind: kind, json: json, origin: origin, site: site)
      }
    }
    page.onFail = { [weak job] url, code in
      MainActor.assumeIsolated {
        guard let job, code != Self.abortedLoad, site.isPasswords(url) || site.isAccounts(url) else { return }
        if job.failure == nil { job.failure = code == Self.rendererGone ? .unavailable : .network }
      }
    }
    var flow = GoogleImportFlow(started: Date())
    var password: String?
    while true {
      try? await Task.sleep(nanoseconds: Self.pollInterval)
      if let failure = job.failure { return .failed(failure) }
      if page.closed { return .failed(.cancelled) }
      let stage = await snapshot(page).map { GoogleImportClassifier.classify($0, site: site) } ?? .loading
      switch flow.step(stage, now: Date()) {
      case .wait:
        continue
      case .clickImport:
        _ = await click(page, .importButton)
      case .clickSelectFile:
        _ = await click(page, .selectFile)
      case .clickConfirmImport:
        _ = await click(page, .confirmImport)
      case .fillPassword:
        if password == nil, let given = job.accountPassword, !given.isEmpty { password = given }
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
      case .finish(let count):
        _ = await click(page, .done)
        return .saved(count)
      case .needPerson(let error):
        if job.person == nil {
          job.person = error
          flow.personStarted(Date())
          answer(job, .confirm(id: job.id, error: error))
          emit(job, state: "confirm", error: error)
        }
      case .fail(let error):
        return .failed(error)
      }
    }
  }

  private func pageMessage(_ job: Job, page: ArdiaHiddenPage, kind: String, json: String, origin: String, site: GoogleImportSite) {
    guard kind == "fileChooser" else { return }
    let request = VaultJSON.dict(VaultJSON.parse(Data(json.utf8)))
    let id = request.flatMap { VaultJSON.string($0["id"]) } ?? ""
    guard GoogleImportSite.origin(of: origin) == GoogleImportSite.origin(of: site.passwords), job.failure == nil, job.filesGiven < 3 else {
      NSLog("[vaults] google import refused a file chooser from %@", origin)
      return page.send("fileImport", json: VaultJSON.text(["id": id, "refused": true]))
    }
    job.filesGiven += 1
    NSLog("[vaults] google import answered the page's file chooser (%@)", request.flatMap { VaultJSON.string($0["via"]) } ?? "?")
    page.send("fileImport", json: VaultJSON.text(["id": id, "name": GoogleImportCSV.fileName, "type": "text/csv", "text": job.csv]))
  }

  private func finish(_ job: Job, _ reply: GoogleImportReply) {
    switch reply {
    case .saved(let count):
      NSLog("[vaults] google import saved %d password(s) for %@", count, job.host)
      emit(job, state: "saved", error: nil)
      reconcileRuns = 0
      scheduleReconcile(after: Self.reconcileDelay)
    case .failed(let error):
      NSLog("[vaults] google import failed for %@: %@", job.host, error.rawValue)
      if error.holdsAutomaticActivity {
        limits.failed(error, now: Date())
        saveLimits()
      }
      emit(job, state: "failed", error: error)
    case .confirm:
      break
    }
    answer(job, reply)
    finals[job.id] = reply
    finalOrder.append(job.id)
    while finalOrder.count > 32 { finals[finalOrder.removeFirst()] = nil }
    for waiter in finalWaiters.removeValue(forKey: job.id) ?? [] { waiter.resume(returning: reply) }
  }

  private func scheduleReconcile(after delay: TimeInterval) {
    reconcileTask?.cancel()
    reconcileTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(max(delay, 1) * 1_000_000_000))
      guard !Task.isCancelled, let self else { return }
      self.reconcileTask = nil
      guard self.running == nil, self.queue.isEmpty, self.exporting == nil, self.listing == nil else { return }
      let retry = await VaultBroker.shared.reconcileGoogle()
      guard let retry, self.reconcileTask == nil, self.reconcileRuns < Self.reconcileRetries else { return }
      self.reconcileRuns += 1
      self.scheduleReconcile(after: retry)
    }
  }

  private func answer(_ job: Job, _ reply: GoogleImportReply) {
    let waiters = job.waiters
    job.waiters = []
    for waiter in waiters { waiter.resume(returning: reply) }
  }

  func noteRapt(_ url: String, site: GoogleImportSite) {
    guard let token = GoogleRapt.token(in: url, site: site), token != rapt?.token else { return }
    rapt = GoogleRapt(token: token, seen: Date())
  }

  private static func loadLimits() -> GoogleWebLimits {
    guard let file = VaultCache.directory?.appendingPathComponent(limitsFile), let data = try? Data(contentsOf: file) else { return GoogleWebLimits() }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return (try? decoder.decode(GoogleWebLimits.self, from: data)) ?? GoogleWebLimits()
  }

  func saveLimits() {
    guard let directory = VaultCache.directory else { return }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    guard let data = try? encoder.encode(limits) else { return }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try data.write(to: directory.appendingPathComponent(Self.limitsFile), options: .atomic)
    } catch {
      NSLog("[vaults] couldn't keep Google's refresh limits: %@", error.localizedDescription)
    }
  }

  private func emit(_ job: Job, state: String, error: GoogleImportError?) {
    var payload: [String: Any] = ["provider": GooglePasswordManagerVault.providerId, "id": job.id, "state": state, "host": job.host]
    if let error {
      payload["code"] = error.rawValue
      payload["message"] = error.message
    }
    ArdiaEvents.emit("vaults.googleImport", data: payload)
  }

  func snapshot(_ page: ArdiaHiddenPage) async -> GoogleImportSnapshot? {
    let json = await evaluate(page, GoogleImportScripts.snapshot())
    return GoogleImportSnapshot.parse(json)
  }

  func click(_ page: ArdiaHiddenPage, _ target: GoogleImportScripts.Target) async -> Bool {
    await evaluate(page, GoogleImportScripts.click(target)) == "true"
  }

  private final class OneAnswer: @unchecked Sendable {
    var continuation: CheckedContinuation<String?, Never>?

    func give(_ value: String?) {
      continuation?.resume(returning: value)
      continuation = nil
    }
  }

  func evaluate(_ page: ArdiaHiddenPage, _ code: String) async -> String? {
    let answer = OneAnswer()
    return await withCheckedContinuation { done in
      answer.continuation = done
      page.evaluate(code) { json in DispatchQueue.main.async { answer.give(json) } }
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.evaluateTimeout) { answer.give(nil) }
    }
  }
}
