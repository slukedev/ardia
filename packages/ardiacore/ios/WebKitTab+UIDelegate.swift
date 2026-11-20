import AppKit
import UniformTypeIdentifiers
import WebKit

extension WebKitTab {
  @objc(_webViewFullscreenMayReturnToInline:)
  func webViewFullscreenMayReturnToInline(_ webView: WKWebView) {
    guard !closed, webView === self.webView else { return }
    let fromOtherApp = ArdiaChromeWindowHost.activateForPictureInPictureReturn()
    emit("activateRequest", ["reason": "pictureInPicture", "fromOtherApp": fromOtherApp])
  }

  func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
               type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
    let kinds: [String]
    switch type {
    case .camera: kinds = ["camera"]
    case .microphone: kinds = ["microphone"]
    default: kinds = ["camera", "microphone"]
    }
    guard let originString = Origins.site(origin) else { return decisionHandler(.deny) }
    WebKitHub.shared.permissions.request(browserId: browserId, tabId: transferKey, profile: profile, origin: originString, kinds: kinds) { [weak webView] allowed in
      if allowed, let view = webView as? WebKitWebView {
        for kind in kinds { view.captureOrigins[kind, default: []].insert(originString) }
      }
      decisionHandler(allowed ? .grant : .deny)
    }
  }

  @objc(_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
  func webViewRequestsLocation(_ webView: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
    if LaunchConfig.shared.background {
      NSLog("[webkit] location request (background mode, denied so macOS never asks)")
      return decisionHandler(.deny)
    }
    guard let site = Origins.site(origin) else { return decisionHandler(.deny) }
    WebKitHub.shared.permissions.request(browserId: browserId, tabId: transferKey, profile: profile, origin: site, kinds: ["location"]) {
      decisionHandler($0 ? .grant : .deny)
    }
  }

  func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
               completionHandler: @escaping () -> Void) {
    let alert = scriptAlert(frame, message)
    alert.addButton(withTitle: "OK")
    guard foremost else {
      completionHandler()
      guard !safety.dialogs.suppressed, !LaunchConfig.shared.background else { return }
      return presentScriptDialog(alert, answered: { _ in }, cancelled: {})
    }
    presentScriptDialog(alert, answered: { _ in completionHandler() }, cancelled: completionHandler)
  }

  func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
               completionHandler: @escaping (Bool) -> Void) {
    guard foremost else { return suppressHiddenDialog { completionHandler(false) } }
    let alert = scriptAlert(frame, message)
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    presentScriptDialog(alert, answered: { completionHandler($0 == .alertFirstButtonReturn) }, cancelled: { completionHandler(false) })
  }

  func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
               initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
    guard foremost else { return suppressHiddenDialog { completionHandler(nil) } }
    let alert = scriptAlert(frame, prompt)
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.stringValue = WebKitPageDialogs.elidedPromptText(defaultText ?? "")
    alert.accessoryView = field
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    presentScriptDialog(alert, answered: { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }, cancelled: { completionHandler(nil) })
  }

  private var foremost: Bool { !closed && visible && window != nil }

  private func suppressHiddenDialog(_ answer: () -> Void) {
    ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "dialogSuppressedWhileHidden"]))
    answer()
  }

  private func scriptAlert(_ frame: WKFrameInfo, _ text: String) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = Self.sheetTitle(frame)
    alert.informativeText = WebKitPageDialogs.elidedMessage(text)
    return alert
  }

  private func presentScriptDialog(_ alert: NSAlert, answered: @escaping (NSApplication.ModalResponse) -> Void, cancelled: @escaping () -> Void) {
    guard !safety.dialogs.suppressed, !LaunchConfig.shared.background else { return cancelled() }
    let offersSuppression = safety.dialogs.noteScriptDialog()
    presentDialog(cancel: cancelled) { [weak self] window, settle in
      if offersSuppression {
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Prevent this page from creating additional dialogs"
      }
      alert.beginSheetModal(for: window) { response in
        guard settle() else { return }
        if offersSuppression, alert.suppressionButton?.state == .on, let self {
          self.safety.dialogs.suppressScriptDialogs()
          ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "scriptDialogsSuppressed"]))
        }
        answered(response)
      }
      return alert.window
    }
  }

  static func sheetTitle(_ frame: WKFrameInfo) -> String {
    let host = frame.securityOrigin.host
    return host.isEmpty ? "This page says" : "\(host) says"
  }

  func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
               completionHandler: @escaping ([URL]?) -> Void) {
    guard visible, let window else { return completionHandler(nil) }
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = parameters.allowsMultipleSelection
    panel.canChooseDirectories = parameters.allowsDirectories
    panel.canChooseFiles = true
    let accepted = WebKitFileTypes.accepted(by: parameters)
    if !accepted.isEmpty {
      WebKitFileTypes.offer(accepted, in: panel)
      ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "uploadFiltered"]))
    }
    panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
  }

  @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
  func webViewRequestsDisplayCapture(_ webView: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo, withSystemAudio: Bool,
                                     decisionHandler: @escaping (Int) -> Void) {
    guard !closed, webView === self.webView else { return decisionHandler(WebKitDisplayCapture.deny) }
    guard let id = WebKitDisplayCapture.hold(decisionHandler, for: self) else { return decisionHandler(WebKitDisplayCapture.deny) }
    let frameOrigin = Origins.of(origin)
    let sources = ArdiaHost.displayMediaSources.filter { ["screen", "window"].contains($0["kind"] as? String ?? "") }
    ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "screenShareRequest"]))
    emit("displayMediaRequest", [
      "id": id, "origin": webView.url.flatMap(Origins.of) ?? frameOrigin, "frameOrigin": frameOrigin, "audio": NSNull(), "sources": sources,
    ])
  }

  @objc(_webView:mediaCaptureStateDidChange:)
  func webViewMediaCaptureStateDidChange(_ webView: WKWebView, state: UInt) {
    guard !closed, webView === self.webView else { return }
    emitMediaAccess()
  }

  func presentDialog(cancel: @escaping () -> Void, show: @escaping WebKitPageDialogs.Show) {
    guard !closed else { return cancel() }
    safety.dialogs.parent = { [weak self] in self?.dialogWindow }
    if dialogWindow == nil { ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "dialogHeldWhileHidden"])) }
    safety.dialogs.present(cancel: cancel, show: show)
  }

  private var dialogWindow: NSWindow? { foremost ? window : nil }

  func showNextDialog() { safety.dialogs.showNext() }

  func cancelDialogs() {
    safety.dialogs.cancelAll()
    WebKitDisplayCapture.denyAll(for: self)
  }

  var capturesDisplay: Bool {
    guard let view = webView, view.responds(to: NSSelectorFromString("_displayCaptureState")) else { return false }
    return (view.value(forKey: "_displayCaptureState") as? NSNumber)?.intValue == WKMediaCaptureState.active.rawValue
  }

  func answerDisplayCapture(_ requestId: String, sourceId: String?) {
    WebKitDisplayCapture.answer(requestId, sourceId: sourceId)
  }
}

enum WebKitDisplayCapture {
  static let deny = 0
  private static let screenPrompt = 1
  private static let windowPrompt = 2

  private final class Request {
    weak var tab: WebKitTab?
    var decide: ((Int) -> Void)?

    init(tab: WebKitTab, decide: @escaping (Int) -> Void) {
      self.tab = tab
      self.decide = decide
    }

    func answer(_ decision: Int) {
      decide?(decision)
      decide = nil
    }
  }

  private static var pending: [String: Request] = [:]

  static func hold(_ decide: @escaping (Int) -> Void, for tab: WebKitTab) -> String? {
    for (id, request) in pending where request.tab?.closed != false {
      pending.removeValue(forKey: id)
      request.answer(deny)
    }
    guard pending.values.filter({ $0.tab === tab }).count < 16 else { return nil }
    let id = "wk-display-" + UUID().uuidString
    pending[id] = Request(tab: tab, decide: decide)
    return id
  }

  static func denyAll(for tab: WebKitTab) {
    for (id, request) in pending where request.tab == nil || request.tab === tab {
      pending.removeValue(forKey: id)
      request.answer(deny)
    }
  }

  static func answer(_ id: String, sourceId: String?) {
    guard let request = pending.removeValue(forKey: id) else { return }
    let source = sourceId ?? ""
    let decision = source.hasPrefix("screen:") ? screenPrompt : source.hasPrefix("window:") ? windowPrompt : deny
    if decision != deny { ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "screenShareAllowed"])) }
    request.answer(decision)
  }
}

enum WebKitFileTypes {
  private static let groups: [String: UTType] = ["image/*": .image, "audio/*": .audio, "video/*": .movie, "text/*": .text]

  static func accepted(by parameters: WKOpenPanelParameters) -> [UTType] {
    let list = { (key: String) -> [String] in
      guard parameters.responds(to: NSSelectorFromString(key)) else { return [] }
      return parameters.value(forKey: key) as? [String] ?? []
    }
    let byMIME = list("_acceptedMIMETypes").compactMap { mime in groups[mime.lowercased()] ?? UTType(mimeType: mime.lowercased()) }
    let byExtension = list("_acceptedFileExtensions").compactMap { UTType(filenameExtension: $0.hasPrefix(".") ? String($0.dropFirst()) : $0) }
    var seen = Set<String>()
    return (byMIME + byExtension).filter { seen.insert($0.identifier).inserted }
  }

  private final class Chooser: NSObject {
    weak var panel: NSSavePanel?
    let types: [UTType]

    init(panel: NSSavePanel, types: [UTType]) {
      self.panel = panel
      self.types = types
    }

    @objc func choose(_ popup: NSPopUpButton) {
      panel?.allowedContentTypes = popup.indexOfSelectedItem == 0 ? types : []
    }
  }

  private static var chooserKey: UInt8 = 0

  static func offer(_ types: [UTType], in panel: NSOpenPanel) {
    panel.allowedContentTypes = types
    panel.allowsOtherFileTypes = true
    let chooser = Chooser(panel: panel, types: types)
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    popup.addItems(withTitles: ["Custom Files", "All Files"])
    popup.target = chooser
    popup.action = #selector(Chooser.choose(_:))
    popup.sizeToFit()
    let label = NSTextField(labelWithString: "Format:")
    let row = NSStackView(views: [label, popup])
    row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
    row.frame.size = row.fittingSize
    objc_setAssociatedObject(popup, &chooserKey, chooser, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    panel.accessoryView = row
    panel.isAccessoryViewDisclosed = true
  }
}
