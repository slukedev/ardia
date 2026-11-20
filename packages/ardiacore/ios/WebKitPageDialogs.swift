import AppKit

final class WebKitPageDialogs {
  typealias Show = (NSWindow, @escaping () -> Bool) -> NSWindow?

  private struct Waiting {
    let show: Show
    let cancel: () -> Void
  }

  private final class Shown {
    let cancel: () -> Void
    var sheet: NSWindow?
    var settled = false

    init(cancel: @escaping () -> Void) { self.cancel = cancel }
  }

  var parent: () -> NSWindow? = { nil }
  private var waiting: [Waiting] = []
  private var shown: Shown?
  private var scriptDialogsThisPage = 0
  private(set) var suppressed = false

  var isShowing: Bool { shown != nil }
  var waitingCount: Int { waiting.count }

  func present(cancel: @escaping () -> Void, show: @escaping Show) {
    waiting.append(Waiting(show: show, cancel: cancel))
    showNext()
  }

  func showNext() {
    guard shown == nil, !waiting.isEmpty, let window = parent() else { return }
    let next = waiting.removeFirst()
    let current = Shown(cancel: next.cancel)
    shown = current
    let sheet = next.show(window) { [weak self] in
      guard !current.settled else { return false }
      current.settled = true
      if self?.shown === current { self?.shown = nil }
      DispatchQueue.main.async { self?.showNext() }
      return true
    }
    if !current.settled { current.sheet = sheet }
  }

  func cancelAll() {
    let dropped = waiting
    waiting.removeAll()
    dropped.forEach { $0.cancel() }
    guard let current = shown else { return }
    shown = nil
    if let sheet = current.sheet, let parent = sheet.sheetParent { parent.endSheet(sheet, returnCode: .abort) }
    guard !current.settled else { return }
    current.settled = true
    current.cancel()
  }

  static let messageRows = 24
  static let messageColumns = 80
  static let promptTextLimit = 2000

  static func elidedPromptText(_ text: String) -> String {
    text.count <= promptTextLimit ? text : String(text.prefix(promptTextLimit - 1)) + "\u{2026}"
  }

  static func elidedMessage(_ text: String) -> String {
    var rows: [Substring] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      var rest = Substring(line)
      repeat {
        rows.append(rest.prefix(messageColumns))
        rest = rest.dropFirst(messageColumns)
      } while !rest.isEmpty && rows.count <= messageRows
      if rows.count > messageRows { break }
    }
    guard rows.count > messageRows else { return text }
    return rows.prefix(messageRows).joined(separator: "\n") + "\u{2026}"
  }

  func noteScriptDialog() -> Bool {
    scriptDialogsThisPage += 1
    return scriptDialogsThisPage > 1
  }

  func suppressScriptDialogs() { suppressed = true }

  func pageChanged() {
    scriptDialogsThisPage = 0
    suppressed = false
  }
}
