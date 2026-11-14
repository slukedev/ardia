import AppKit
import WebKit

@available(macOS 15.4, *)
final class WebKitExtensionBridge {
  private struct Pending {
    let reply: (Any?, (any Error)?) -> Void
    let windows: [[String]]
    let timeout: DispatchWorkItem
  }

  private final class Listener {
    let port: WKWebExtension.MessagePort
    let extensionId: String
    var apis: Set<String> = []

    init(port: WKWebExtension.MessagePort, extensionId: String) {
      self.port = port
      self.extensionId = extensionId
    }
  }

  static let replyDeadline: TimeInterval = 15
  private static var nextRequest = 0
  private static var pending: [String: Pending] = [:]

  private weak var hub: WebKitExtensionHub?
  private var listeners: [ObjectIdentifier: Listener] = [:]
  private var hosts: [ObjectIdentifier: WebKitExtensionNativeHost] = [:]
  private var announced: Set<String> = []

  init(hub: WebKitExtensionHub) { self.hub = hub }

  static func failure(_ message: String) -> NSError {
    NSError(domain: "dev.ardia.webkit.extensions", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }

  func sendMessage(_ message: Any?, to application: String?, from context: WKWebExtensionContext, reply: @escaping (Any?, (any Error)?) -> Void) {
    guard let hub, let loaded = hub.loadedExtension(context.uniqueIdentifier) else { return reply(nil, Self.failure("The extension isn't loaded.")) }
    guard let application, application != WebKitExtensionShim.application else {
      return call(message as? [String: Any] ?? [:], loaded: loaded, hub: hub, reply: reply)
    }
    guard loaded.nativeMessaging else { return reply(nil, WebKitExtensionNativeHost.forbidden) }
    sendToHost(application, message: message, extensionId: loaded.id, reply: reply)
  }

  func connect(_ port: WKWebExtension.MessagePort, from context: WKWebExtensionContext, completion: @escaping ((any Error)?) -> Void) {
    guard let hub, let loaded = hub.loadedExtension(context.uniqueIdentifier) else { return completion(Self.failure("The extension isn't loaded.")) }
    let key = ObjectIdentifier(port)
    guard let application = port.applicationIdentifier, application != WebKitExtensionShim.application else {
      let listener = Listener(port: port, extensionId: loaded.id)
      listeners[key] = listener
      port.messageHandler = { [weak self, weak listener] message, _ in
        guard let self, let listener, let body = message as? [String: Any], let listen = body["listen"] as? [String] else { return }
        listener.apis = Set(listen).intersection(self.hub?.loadedExtension(listener.extensionId)?.apis ?? [])
        self.announce()
      }
      port.disconnectHandler = { [weak self] _ in
        self?.listeners.removeValue(forKey: key)
        self?.announce()
      }
      return completion(nil)
    }
    guard loaded.nativeMessaging else { return completion(WebKitExtensionNativeHost.forbidden) }
    do {
      let host = try WebKitExtensionNativeHost.launch(application, extensionId: loaded.id, onMessage: { [weak port] message in
        port?.sendMessage(message, completionHandler: nil)
      }, onExit: { [weak self, weak port] error in
        self?.hosts.removeValue(forKey: key)
        if let error { port?.disconnect(throwing: error) } else { port?.disconnect() }
      })
      hosts[key] = host
      port.messageHandler = { [weak host] message, _ in
        guard let message else { return }
        host?.send(message)
      }
      port.disconnectHandler = { [weak self] _ in
        self?.hosts.removeValue(forKey: key)?.close()
      }
      completion(nil)
    } catch {
      completion(error)
    }
  }

  private func sendToHost(_ application: String, message: Any?, extensionId: String, reply: @escaping (Any?, (any Error)?) -> Void) {
    let token = UUID()
    var answered = false
    let answer: (Any?, (any Error)?) -> Void = { [weak self] value, error in
      guard !answered else { return }
      answered = true
      self?.oneShots.removeValue(forKey: token)?.close()
      reply(value, error)
    }
    do {
      let host = try WebKitExtensionNativeHost.launch(application, extensionId: extensionId, onMessage: { message in answer(message, nil) },
                                                      onExit: { error in answer(nil, error ?? WebKitExtensionNativeHost.exited) })
      oneShots[token] = host
      guard let message, host.send(message) else { return answer(nil, WebKitExtensionNativeHost.broken) }
    } catch {
      answer(nil, error)
    }
  }

  private var oneShots: [UUID: WebKitExtensionNativeHost] = [:]

  private func call(_ body: [String: Any], loaded: WebKitExtensionHub.Loaded, hub: WebKitExtensionHub, reply: @escaping (Any?, (any Error)?) -> Void) {
    guard body["ardia"] as? Int == 1, let api = body["api"] as? String, let method = body["method"] as? String else {
      return reply(["error": "Ardia doesn't know this message."], nil)
    }
    guard loaded.apis.contains(api) else { return reply(["error": "The extension doesn't have the \(api) permission."], nil) }
    if method != "groupIdsOf" { ArdiaEvents.emit("webKit.counted", data: ["name": "shim\(api.prefix(1).uppercased())\(api.dropFirst())"]) }
    let args = body["args"] as? [Any] ?? []
    let tabs = (body["tabs"] as? [Any] ?? []).map { hub.resolve($0 as? [String: Any]) }
    let windows = hub.windowTabKeys()
    if api == "sidePanel" {
      return reply(hub.sidePanelCall(method, args: args, tabs: tabs, extensionId: loaded.id), nil)
    }
    if api == "downloads", method == "download" {
      guard let options = args.first as? [String: Any], let started = hub.startDownload(options) else {
        return reply(["error": "Invalid URL."], nil)
      }
      return forward(api: api, method: "download", args: [started], tabKeys: [], windows: windows, extensionId: loaded.id, hub: hub, reply: reply)
    }
    forward(api: api, method: method, args: args, tabKeys: tabs.map { tab -> Any in tab?.transferKey.map { $0 as Any } ?? NSNull() }, windows: windows, extensionId: loaded.id, hub: hub, reply: reply)
  }

  private func forward(api: String, method: String, args: [Any], tabKeys: [Any], windows: [[String]], extensionId: String, hub: WebKitExtensionHub,
                       reply: @escaping (Any?, (any Error)?) -> Void) {
    Self.nextRequest += 1
    let id = "wk-ext-\(Self.nextRequest)"
    let timeout = DispatchWorkItem { Self.answer(id, ["error": "Ardia didn't answer in time."]) }
    Self.pending[id] = Pending(reply: reply, windows: windows, timeout: timeout)
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.replyDeadline, execute: timeout)
    ArdiaEvents.emit("webKit.extensionCall", data: [
      "id": id, "profile": hub.profile, "base": ArdiaHost.baseProfile(of: hub.profile), "private": hub.isPrivate, "extensionId": extensionId,
      "api": api, "method": method, "args": args, "tabKeys": tabKeys, "windows": windows,
    ])
  }

  static func answer(_ id: String, _ payload: [String: Any]) {
    guard let entry = pending.removeValue(forKey: id) else { return }
    entry.timeout.cancel()
    var body: [String: Any] = ["windows": entry.windows]
    if let error = payload["error"] as? String { body["error"] = error } else { body["result"] = payload["result"] ?? NSNull() }
    entry.reply(body, nil)
  }

  func event(api: String, name: String, args: [Any]) {
    guard let hub else { return }
    let message: [String: Any] = ["ardia": 1, "api": api, "event": name, "args": args, "windows": hub.windowTabKeys()]
    for listener in listeners.values where listener.apis.contains(api) && !listener.port.isDisconnected {
      listener.port.sendMessage(message, completionHandler: nil)
    }
  }

  func dropExtension(_ id: String) {
    for (key, listener) in listeners where listener.extensionId == id {
      listener.port.disconnect()
      listeners.removeValue(forKey: key)
    }
    announce()
  }

  func closeAll() {
    listeners.values.forEach { $0.port.disconnect() }
    listeners.removeAll()
    hosts.values.forEach { $0.close() }
    hosts.removeAll()
    oneShots.values.forEach { $0.close() }
    oneShots.removeAll()
    announce()
  }

  private func announce() {
    guard let hub else { return }
    let apis = listeners.values.reduce(into: Set<String>()) { $0.formUnion($1.apis) }
    guard apis != announced else { return }
    announced = apis
    ArdiaEvents.emit("webKit.extensionListeners", data: [
      "profile": hub.profile, "base": ArdiaHost.baseProfile(of: hub.profile), "private": hub.isPrivate, "apis": apis.sorted(),
    ])
  }
}
