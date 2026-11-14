import Foundation

struct WebKitExtensionStaging {
  struct Staged {
    let folder: URL
    let apis: Set<String>
    let nativeMessaging: Bool
    let signature: String
  }

  static let revision = 1
  static let shimmed: Set<String> = ["downloads", "history", "bookmarks", "tabGroups", "sidePanel"]
  static let workerFile = "__ardia_webkit_worker.js"
  static let markerFile = ".ardia-webkit-staged"

  static func root(profile: String) -> URL {
    URL(fileURLWithPath: ArdiaServices.profileDirectory(profile), isDirectory: true).appendingPathComponent("Ardia WebKit Extensions", isDirectory: true)
  }

  static func manifest(at folder: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  static func permissionNames(_ value: Any?) -> Set<String> {
    Set((value as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.contains("://") && !$0.hasPrefix("<") && !$0.hasPrefix("*") })
  }

  static func stage(id: String, source: URL, profile: String, grants: WebKitExtensionGrants) -> Staged {
    guard let manifest = manifest(at: source) else {
      return Staged(folder: source, apis: [], nativeMessaging: false, signature: source.standardizedFileURL.path)
    }
    let required = permissionNames(manifest["permissions"])
    let optional = permissionNames(manifest["optional_permissions"])
    let granted = required.union(optional.intersection(grants.apis))
    let apis = shimmed.intersection(granted)
    let nativeMessaging = granted.contains("nativeMessaging")
    let plain = Staged(folder: source, apis: apis, nativeMessaging: nativeMessaging, signature: source.standardizedFileURL.path)
    guard !apis.isEmpty else { return plain }
    let target = root(profile: profile).appendingPathComponent(id, isDirectory: true)
    let signature = "\(revision)|\(source.standardizedFileURL.path)|\(newestChange(in: source))|\(apis.sorted().joined(separator: ","))"
    let staged = Staged(folder: target, apis: apis, nativeMessaging: nativeMessaging, signature: signature)
    if (try? String(contentsOf: target.appendingPathComponent(markerFile), encoding: .utf8)) == signature { return staged }
    do {
      try write(manifest, from: source, to: target, apis: apis)
      try signature.write(to: target.appendingPathComponent(markerFile), atomically: true, encoding: .utf8)
      return staged
    } catch {
      NSLog("[webkit] extension %@ couldn't be staged: %@", id, error.localizedDescription)
      try? FileManager.default.removeItem(at: target)
      return plain
    }
  }

  static func forgetAll(except ids: Set<String>, profile: String) {
    let folder = root(profile: profile)
    for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !ids.contains(name) {
      try? FileManager.default.removeItem(at: folder.appendingPathComponent(name, isDirectory: true))
    }
  }

  private static func newestChange(in folder: URL) -> Int {
    let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
    guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
    var newest = 0.0
    var count = 0
    for case let file as URL in files {
      guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
      count += 1
      newest = max(newest, values.contentModificationDate?.timeIntervalSince1970 ?? 0)
    }
    return Int(newest) * 100_000 + count
  }

  private static func write(_ manifest: [String: Any], from source: URL, to target: URL, apis: Set<String>) throws {
    let files = FileManager.default
    try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
    try files.copyItem(at: source, to: target)
    try WebKitExtensionShim.source(apis: apis).write(to: target.appendingPathComponent(WebKitExtensionShim.fileName), atomically: true, encoding: .utf8)
    var edited = manifest
    var permissions = manifest["permissions"] as? [Any] ?? []
    if !permissions.contains(where: { ($0 as? String) == "nativeMessaging" }) { permissions.append("nativeMessaging") }
    edited["permissions"] = permissions
    if var background = manifest["background"] as? [String: Any] {
      try wrapBackground(&background, in: target)
      edited["background"] = background
    }
    let data = try JSONSerialization.data(withJSONObject: edited, options: [.withoutEscapingSlashes])
    try data.write(to: target.appendingPathComponent("manifest.json"), options: .atomic)
    try injectPages(in: target)
  }

  private static func relative(_ path: String) -> String { String(path.drop { $0 == "/" }) }

  static func wrapBackground(_ background: inout [String: Any], in target: URL) throws {
    let shim = WebKitExtensionShim.fileName
    if let scripts = background["scripts"] as? [String], !scripts.isEmpty {
      background["scripts"] = [shim] + scripts.map(relative).filter { $0 != shim }
      return
    }
    guard let worker = background["service_worker"] as? String, !worker.isEmpty else { return }
    let path = relative(worker)
    let wrapper = (background["type"] as? String) == "module"
      ? "import \"/\(shim)\";\nimport \"/\(path)\";\n"
      : "importScripts(\"/\(shim)\", \"/\(path)\");\n"
    try wrapper.write(to: target.appendingPathComponent(workerFile), atomically: true, encoding: .utf8)
    background["service_worker"] = workerFile
  }

  static func injected(_ html: String) -> String {
    let tag = "<script src=\"/\(WebKitExtensionShim.fileName)\"></script>"
    guard !html.contains(tag) else { return html }
    for opener in ["<head[\\s>]", "<html[\\s>]"] {
      guard let start = html.range(of: opener, options: [.regularExpression, .caseInsensitive]),
        let end = html.range(of: ">", range: start.lowerBound..<html.endIndex)
      else { continue }
      return html.replacingCharacters(in: end.upperBound..<end.upperBound, with: tag)
    }
    let doctype = html.range(of: "<!doctype", options: .caseInsensitive).flatMap { html.range(of: ">", range: $0.upperBound..<html.endIndex) }
    guard let doctype else { return tag + html }
    return html.replacingCharacters(in: doctype.upperBound..<doctype.upperBound, with: tag)
  }

  private static func injectPages(in folder: URL) throws {
    guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
    for case let file as URL in files where ["html", "htm"].contains(file.pathExtension.lowercased()) {
      guard let html = try? String(contentsOf: file, encoding: .utf8) else { continue }
      let edited = injected(html)
      if edited != html { try edited.write(to: file, atomically: true, encoding: .utf8) }
    }
  }
}
