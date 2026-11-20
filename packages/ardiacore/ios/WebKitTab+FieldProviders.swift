import os
import WebKit

extension WebKitTab {
  func fieldProviderMessage(_ kind: String, data dict: [String: Any]?, frame: String, frameInfo: WKFrameInfo) {
    let main = frameInfo.isMainFrame
    switch kind {
    case "fieldProviderHello":
      noteScriptFrame(frame, frameInfo)
    case "fieldFocus":
      guard main, let view = webView, let generation = dict?["generation"] as? Double, let sequence = dict?["seq"] as? Double else { return }
      ArdiaWebView.noteFieldFocus(dict?["field"] as? String, sequence: sequence, generation: generation, query: dict?["query"] as? String, owner: view)
    case "fieldProviderHint":
      guard let state = dict?["state"] as? String, ["shown", "dismissed"].contains(state), sameOriginAsTop(frameInfo),
        ArdiaWebView.fieldProvider(profile: profile) != nil
      else { return }
      emit("fieldProviderHint", ["state": state])
    case "fieldProvider":
      guard let view = webView, let field = dict?["field"] as? String, let generation = dict?["generation"] as? Double,
        sameOriginAsTop(frameInfo)
      else { return }
      guard visible else {
        os_log("[ardiacore] system passwords panel refused reason=hidden via=badge")
        return emitPanelResult(["shown": false, "reason": "hidden"], via: "badge")
      }
      ArdiaWebView.requestSystemPanel(in: view, owner: view, profile: profile, field: field, generation: generation) { [weak self] result in
        self?.emitPanelResult(result, via: "badge")
      }
    case "verificationCode":
      guard main, let view = webView, let generation = dict?["generation"] as? Double, let url = dict?["url"] as? String,
        view.scriptFrames[frame] != nil,
        let offer = ArdiaWebView.offerVerificationCode(url, owner: view, frame: frame, profile: profile, generation: generation),
        let token = offer["token"] as? String, let app = offer["app"] as? String
      else { return }
      emit("verificationCodeFound", ["token": token, "app": app, "main": true])
    default: siteMessage(kind, data: dict, frameInfo: frameInfo)
    }
  }

  private func noteScriptFrame(_ frame: String, _ info: WKFrameInfo) {
    guard let view = webView, !frame.isEmpty else { return }
    if info.isMainFrame {
      view.scriptFrames = [:]
      ArdiaWebView.resetFieldProviderPage(view)
    } else if view.scriptFrames.count >= 256 {
      view.scriptFrames = view.scriptFrames.filter { $0.value.isMainFrame }
    }
    view.scriptFrames[frame] = info
    pushFieldProvider(to: info)
  }

  private func sameOriginAsTop(_ info: WKFrameInfo) -> Bool {
    if info.isMainFrame { return true }
    guard let top = webView?.url, let scheme = top.scheme?.lowercased(), let host = top.host?.lowercased(), !host.isEmpty else { return false }
    let defaultPort = { (scheme: String) in scheme == "https" ? 443 : scheme == "http" ? 80 : 0 }
    let origin = info.securityOrigin
    let originScheme = origin.protocol.lowercased()
    let originPort = origin.port == 0 ? defaultPort(originScheme) : origin.port
    return originScheme == scheme && origin.host.lowercased() == host && originPort == (top.port ?? defaultPort(scheme))
  }

  private var fieldProviderJSON: String {
    guard let provider = ArdiaWebView.fieldProvider(profile: profile), let data = try? JSONSerialization.data(withJSONObject: provider),
      let text = String(data: data, encoding: .utf8)
    else { return "false" }
    return text
  }

  private func pushFieldProvider(to info: WKFrameInfo) {
    let state = sameOriginAsTop(info) ? fieldProviderJSON : "false"
    runInWorld("window.__ardia && window.__ardia.fieldProvider(\(state))", frame: info.isMainFrame ? nil : info)
  }

  func pushFieldProvider() {
    guard let view = webView else { return }
    for info in view.scriptFrames.values { pushFieldProvider(to: info) }
  }

  private func emitPanelResult(_ result: [AnyHashable: Any], via: String) {
    let reason = result["reason"] as? String
    guard reason != "noProvider", reason != "stale" else { return }
    var payload: [String: Any] = ["via": via, "shown": result["shown"] as? Bool ?? false]
    if let reason { payload["reason"] = reason }
    if let panel = result["panel"] as? String { payload["panel"] = panel }
    emit("fieldProviderOpened", payload)
  }

  func showFieldProviderHint(label: String, side: String) -> Bool {
    guard let view = webView, let json = ArdiaWebView.fieldProviderHintJSON(label, side: side) else { return false }
    pushFieldProviderHint(json, in: view)
    ArdiaWebView.whenSystemPanelCloses { [weak self] in
      guard let self, let view = self.webView else { return }
      self.pushFieldProviderHint("false", in: view)
    }
    return true
  }

  private func pushFieldProviderHint(_ json: String, in view: WebKitWebView) {
    for info in view.scriptFrames.values where sameOriginAsTop(info) {
      runInWorld("window.__ardia && window.__ardia.fieldProviderHint(\(json))", frame: info.isMainFrame ? nil : info)
    }
  }

  func showSystemPanel(generation: Double, done: @escaping ([AnyHashable: Any]) -> Void) {
    guard let view = webView else { return done(["shown": false, "reason": "noTab"]) }
    ArdiaWebView.querySystemPanel(in: view, owner: view, profile: profile, generation: generation, ask: { [weak self] query in
      let quoted = (try? JSONSerialization.data(withJSONObject: [query])).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
      self?.runInWorld("window.__ardia && window.__ardia.fieldFocusQuery(\(quoted)[0])")
    }) { [weak self] result in
      self?.emitPanelResult(result, via: "menu")
      done(result)
    }
  }

  func setUpVerificationCode(_ token: String, generation: Double, done: @escaping ([AnyHashable: Any]) -> Void) {
    guard let view = webView else { return done(["opened": false, "reason": "noTab"]) }
    ArdiaWebView.redeemVerificationCode(token, owner: view, profile: profile, generation: generation,
                                        frameAlive: { [weak view] frame in view?.scriptFrames[frame] != nil }, completion: done)
  }

  func fieldProviderCommitted() {
    guard let view = webView else { return }
    view.scriptFrames = [:]
    ArdiaWebView.resetFieldProviderPage(view)
  }
}
