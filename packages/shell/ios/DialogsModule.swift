import AppKit
import ExpoModulesCore

public class DialogsModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ArdiaDialogs")

    AsyncFunction("confirm") { (options: ConfirmOptions, promise: Promise) in
      if let file = MenuChoice.testFile(flag: "appDialog", name: "dialog.json"),
         let answer = MenuChoice.testAnswer(dumping: options.toDictionary().merging(["kind": "confirm"]) { $1 }, to: file) {
        let words = Set(answer.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        promise.resolve(["confirmed": words.contains("confirm"), "suppressed": words.contains("suppress")])
        return
      }
      let alert = DialogsModule.alert(title: options.title, message: options.message)
      let confirmResponse: NSApplication.ModalResponse = options.cancelIsDefault ? .alertSecondButtonReturn : .alertFirstButtonReturn
      let titles = options.cancelIsDefault ? [options.cancelTitle, options.confirmTitle] : [options.confirmTitle, options.cancelTitle]
      for title in titles { alert.addButton(withTitle: title) }
      let confirmButton = options.cancelIsDefault ? alert.buttons.last : alert.buttons.first
      if options.destructive { confirmButton?.hasDestructiveAction = true }
      if options.warning, let icon = DialogsModule.warningIcon() { alert.icon = icon }
      if let suppression = options.suppression {
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = suppression
      }
      DialogsModule.present(alert, windowId: options.windowId) { response in
        promise.resolve([
          "confirmed": response == confirmResponse,
          "suppressed": alert.suppressionButton?.state == .on,
        ])
      }
    }.runOnQueue(.main)
    AsyncFunction("prompt") { (options: PromptOptions, promise: Promise) in
      if let file = MenuChoice.testFile(flag: "appDialog", name: "dialog.json"),
         let answer = MenuChoice.testAnswer(dumping: options.toDictionary().merging(["kind": "prompt"]) { $1 }, to: file) {
        promise.resolve(answer.isEmpty ? nil : answer)
        return
      }
      let alert = DialogsModule.alert(title: options.title, message: options.message)
      alert.addButton(withTitle: options.confirmTitle)
      alert.addButton(withTitle: "Cancel")
      let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
      field.stringValue = options.value
      field.placeholderString = options.placeholder
      alert.accessoryView = field
      alert.window.initialFirstResponder = field
      DialogsModule.present(alert, windowId: options.windowId) { response in
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        promise.resolve(response == .alertFirstButtonReturn && !text.isEmpty ? text : nil)
      }
    }.runOnQueue(.main)
    AsyncFunction("pickFiles") { (promise: Promise) in
      let panel = NSOpenPanel()
      panel.allowsMultipleSelection = true
      panel.canChooseDirectories = false
      panel.begin { response in
        promise.resolve(response == .OK ? panel.urls.map(\.absoluteString) : [])
      }
    }.runOnQueue(.main)
    AsyncFunction("pickFolder") { (current: String?, prompt: String?, promise: Promise) in
      let panel = NSOpenPanel()
      panel.canChooseFiles = false
      panel.canChooseDirectories = true
      panel.canCreateDirectories = true
      panel.allowsMultipleSelection = false
      if let prompt { panel.prompt = prompt }
      if let current { panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true) }
      panel.begin { response in promise.resolve(response == .OK ? panel.url?.path : nil) }
    }.runOnQueue(.main)
  }

  static func warningIcon() -> NSImage? {
    let configuration = NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)
      .applying(NSImage.SymbolConfiguration(paletteColors: [.black, .systemYellow]))
    return NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")?.withSymbolConfiguration(configuration)
  }

  static func alert(title: String, message: String) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    return alert
  }

  static func present(_ alert: NSAlert, windowId: String?, completion: @escaping (NSApplication.ModalResponse) -> Void) {
    if let window = windowId.flatMap({ WindowManager.shared.window($0) }), window.isVisible {
      alert.beginSheetModal(for: window, completionHandler: completion)
    } else {
      completion(alert.runModal())
    }
  }
}
