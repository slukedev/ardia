import AppKit
import Testing

@MainActor
final class Page {
  let dialogs = WebKitPageDialogs()
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
  var shown = true
  var opened: [String] = []
  var settles: [String: () -> Bool] = [:]
  var answers: [String] = []

  init() {
    dialogs.parent = { [unowned self] in self.shown ? self.window : nil }
  }

  func ask(_ name: String) {
    dialogs.present(cancel: { [unowned self] in self.answers.append("\(name) cancelled") }) { [unowned self] _, settle in
      self.opened.append(name)
      self.settles[name] = settle
      return nil
    }
  }

  func answer(_ name: String) {
    if settles[name]?() == true { answers.append("\(name) answered") }
  }
}

@MainActor
func drainMainQueue() async {
  await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
}

@MainActor
@Suite(.serialized) struct PageDialogQueue {
  init() { _ = NSApplication.shared }

  @Test func `a second dialog waits until the first is answered`() async {
    let page = Page()
    page.ask("first")
    page.ask("second")
    #expect(page.opened == ["first"])
    page.answer("first")
    await drainMainQueue()
    #expect(page.opened == ["first", "second"])
  }

  @Test func `a tab that isn't shown holds its dialog until it is`() {
    let page = Page()
    page.shown = false
    page.ask("hidden")
    #expect(page.opened.isEmpty)
    page.shown = true
    page.dialogs.showNext()
    #expect(page.opened == ["hidden"])
  }

  @Test func `cancelling answers every dialog once, even if the sheet ends later`() {
    let page = Page()
    page.ask("up")
    page.ask("queued")
    page.dialogs.cancelAll()
    page.answer("up")
    #expect(page.answers == ["queued cancelled", "up cancelled"])
    #expect(!page.dialogs.isShowing)
  }

  @Test func `a dialog answered while it opens doesn't block the ones after it`() async {
    let page = Page()
    page.dialogs.present(cancel: {}) { _, settle in
      _ = settle()
      return nil
    }
    page.ask("after")
    await drainMainQueue()
    #expect(page.opened == ["after"])
  }

  @Test func `a repeat script dialog offers to silence the page until the page changes`() {
    let page = Page()
    #expect(!page.dialogs.noteScriptDialog())
    #expect(page.dialogs.noteScriptDialog())
    page.dialogs.suppressScriptDialogs()
    #expect(page.dialogs.suppressed)
    page.dialogs.pageChanged()
    #expect(!page.dialogs.suppressed)
    #expect(!page.dialogs.noteScriptDialog())
  }
}

struct PageDialogText {
  @Test func `a short message is shown as written`() {
    let text = "Saved.\nReload to see it."
    #expect(WebKitPageDialogs.elidedMessage(text) == text)
  }

  @Test func `a message longer than 24 rows of 80 columns is cut with an ellipsis`() {
    let long = String(repeating: "x", count: 80 * 30)
    let shown = WebKitPageDialogs.elidedMessage(long)
    #expect(shown.hasSuffix("\u{2026}"))
    #expect(shown.split(separator: "\n").count == WebKitPageDialogs.messageRows)
    let many = (0..<1000).map(String.init).joined(separator: "\n")
    #expect(WebKitPageDialogs.elidedMessage(many).split(separator: "\n").count == WebKitPageDialogs.messageRows)
  }

  @Test func `a prompt's default text keeps at most 2000 characters`() {
    #expect(WebKitPageDialogs.elidedPromptText("abc") == "abc")
    let shown = WebKitPageDialogs.elidedPromptText(String(repeating: "é", count: 5000))
    #expect(shown.count == WebKitPageDialogs.promptTextLimit)
    #expect(shown.hasSuffix("\u{2026}"))
  }
}

struct DownloadNames {
  @Test(arguments: [
    ("invoice\u{202E}fdp.app", "invoicefdp.app"),
    ("../../.ssh/config", "_.._.ssh_config"),
    (" .. ", "download"),
    ("a\u{0}b\nc.txt", "abc.txt"),
    ("👩‍💻 notes.txt", "👩‍💻 notes.txt"),
  ])
  func `names can't disguise or escape`(raw: String, safe: String) {
    #expect(WebKitDownloadNames.safe(raw) == safe)
  }

  @Test func `a long name fits 255 bytes and keeps its extension`() {
    let long = WebKitDownloadNames.safe(String(repeating: "é", count: 300) + ".pdf")
    #expect(long.utf8.count <= 255)
    #expect(long.hasSuffix(".pdf"))
  }
}
