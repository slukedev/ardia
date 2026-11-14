import Foundation

final class WebKitExtensionNativeHost {
  static let errorDomain = "dev.ardia.webkit.nativeMessaging"
  static let skipped: Set<String> = ["com.apple.passwordmanager"]
  static let maxIncoming = 1024 * 1024

  static func folders() -> [URL] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return [
      URL(fileURLWithPath: ArdiaHost.dataDirectory, isDirectory: true).appendingPathComponent("NativeMessagingHosts", isDirectory: true),
      home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts", isDirectory: true),
      URL(fileURLWithPath: "/Library/Application Support/Chromium/NativeMessagingHosts", isDirectory: true),
      URL(fileURLWithPath: "/Library/Google/Chrome/NativeMessagingHosts", isDirectory: true),
    ]
  }

  static func isValidName(_ name: String) -> Bool {
    name.range(of: "^[a-z0-9_]+(\\.[a-z0-9_]+)*$", options: .regularExpression) != nil
  }

  static func error(_ message: String) -> NSError {
    NSError(domain: errorDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }

  static let notFound = error("Specified native messaging host not found.")
  static let forbidden = error("Access to the specified native messaging host is forbidden.")
  static let exited = error("Native host has exited.")
  static let broken = error("Error when communicating with the native messaging host.")

  static func manifest(named name: String, in folders: [URL] = folders()) -> [String: Any]? {
    guard isValidName(name), !skipped.contains(name) else { return nil }
    for folder in folders {
      guard let data = try? Data(contentsOf: folder.appendingPathComponent("\(name).json")),
        let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        manifest["name"] as? String == name, manifest["type"] as? String == "stdio",
        let path = manifest["path"] as? String, path.hasPrefix("/")
      else { continue }
      return manifest
    }
    return nil
  }

  static func allows(_ manifest: [String: Any], extensionId: String) -> Bool {
    (manifest["allowed_origins"] as? [String] ?? []).contains("chrome-extension://\(extensionId)/")
  }

  static func frame(_ message: Any) -> Data? {
    guard JSONSerialization.isValidJSONObject(message) || message is String || message is NSNumber || message is NSNull,
      let body = try? JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed])
    else { return nil }
    var length = UInt32(body.count).littleEndian
    var data = Data(bytes: &length, count: 4)
    data.append(body)
    return data
  }

  static func unframe(_ buffer: inout Data) throws -> [Any] {
    var messages: [Any] = []
    while buffer.count >= 4 {
      let length = buffer.prefix(4).withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
      guard length <= maxIncoming else { throw broken }
      guard buffer.count >= 4 + length else { break }
      let body = buffer.subdata(in: buffer.startIndex + 4..<buffer.startIndex + 4 + length)
      buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + 4 + length)
      guard let message = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else { throw broken }
      messages.append(message)
    }
    return messages
  }

  private let process = Process()
  private let input = Pipe()
  private let output = Pipe()
  private var buffer = Data()
  private var finished = false
  private let onMessage: (Any) -> Void
  private let onExit: (NSError?) -> Void

  private init(onMessage: @escaping (Any) -> Void, onExit: @escaping (NSError?) -> Void) {
    self.onMessage = onMessage
    self.onExit = onExit
  }

  static func launch(_ name: String, extensionId: String, onMessage: @escaping (Any) -> Void, onExit: @escaping (NSError?) -> Void) throws -> WebKitExtensionNativeHost {
    guard let manifest = manifest(named: name), let path = manifest["path"] as? String else { throw notFound }
    guard allows(manifest, extensionId: extensionId) else { throw forbidden }
    let host = WebKitExtensionNativeHost(onMessage: onMessage, onExit: onExit)
    host.process.executableURL = URL(fileURLWithPath: path)
    host.process.arguments = ["chrome-extension://\(extensionId)/"]
    host.process.currentDirectoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
    host.process.standardInput = host.input
    host.process.standardOutput = host.output
    host.process.standardError = FileHandle.nullDevice
    host.output.fileHandleForReading.readabilityHandler = { [weak host] handle in
      let chunk = handle.availableData
      DispatchQueue.main.async { host?.received(chunk) }
    }
    do {
      try host.process.run()
    } catch {
      ArdiaEvents.emit("webKit.counted", data: ["name": "nativeHostFailure"])
      throw broken
    }
    ArdiaEvents.emit("webKit.counted", data: ["name": "nativeHostLaunch"])
    return host
  }

  private func received(_ chunk: Data) {
    guard !finished else { return }
    if chunk.isEmpty { return finish(Self.exited) }
    buffer.append(chunk)
    do {
      for message in try Self.unframe(&buffer) { onMessage(message) }
    } catch {
      finish(Self.broken)
    }
  }

  @discardableResult
  func send(_ message: Any) -> Bool {
    guard !finished, let data = Self.frame(message) else { return false }
    do {
      try input.fileHandleForWriting.write(contentsOf: data)
      return true
    } catch {
      finish(Self.broken)
      return false
    }
  }

  func close() {
    guard !finished else { return }
    finished = true
    output.fileHandleForReading.readabilityHandler = nil
    try? input.fileHandleForWriting.close()
    if process.isRunning { process.terminate() }
  }

  private func finish(_ error: NSError?) {
    guard !finished else { return }
    if error === Self.broken { ArdiaEvents.emit("webKit.counted", data: ["name": "nativeHostFailure"]) }
    close()
    onExit(error)
  }
}
