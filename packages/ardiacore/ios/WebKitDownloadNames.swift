import Foundation

enum WebKitDownloadNames {
  private static let maxBytes = 255
  private static let maxExtensionBytes = 32
  private static let invisible = CharacterSet.controlCharacters.union(.illegalCharacters).subtracting(CharacterSet(charactersIn: "\u{200C}\u{200D}"))

  static func safe(_ name: String) -> String {
    let visible = String(String.UnicodeScalarView(name.unicodeScalars.filter { !invisible.contains($0) }))
    let cleaned = visible.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
    let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
    return trimmed.isEmpty ? "download" : fitted(trimmed)
  }

  private static func fitted(_ name: String) -> String {
    guard name.utf8.count > maxBytes else { return name }
    let ext = (name as NSString).pathExtension
    let suffix = ext.isEmpty || ext.utf8.count > maxExtensionBytes ? "" : "." + ext
    var stem = Substring(suffix.isEmpty ? name : String(name.dropLast(suffix.count)))
    while stem.utf8.count + suffix.utf8.count > maxBytes { stem = stem.dropLast() }
    return String(stem) + suffix
  }
}
