import AppKit
import UniformTypeIdentifiers
import WebKit

extension WebKitTab {
  private enum SaveFormat: Int, CaseIterable {
    case webArchive, pageSource

    var title: String { self == .webArchive ? "Web Archive" : "Page Source" }
    var type: UTType { self == .webArchive ? .webArchive : .html }
  }

  private final class SaveFormatChooser: NSObject {
    weak var panel: NSSavePanel?
    var format = SaveFormat.webArchive

    init(panel: NSSavePanel) { self.panel = panel }

    @objc func choose(_ popup: NSPopUpButton) {
      guard let panel, let chosen = SaveFormat(rawValue: popup.indexOfSelectedItem) else { return }
      format = chosen
      panel.allowedContentTypes = [chosen.type]
      let name = (panel.nameFieldStringValue as NSString).deletingPathExtension
      panel.nameFieldStringValue = name + "." + (chosen.type.preferredFilenameExtension ?? "")
    }
  }

  func runPageFileCommand(_ name: String) {
    switch name {
    case "savePage": savePage()
    case "viewSource": viewSource()
    default: break
    }
  }

  func savePage() {
    guard let view = webView, let window, let url = view.url, ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { return }
    let title = (view.title?.isEmpty == false ? view.title : nil) ?? url.host ?? "Untitled"
    let panel = NSSavePanel()
    let chooser = SaveFormatChooser(panel: panel)
    panel.allowedContentTypes = [SaveFormat.webArchive.type]
    panel.nameFieldStringValue = WebKitDownloadNames.safe(title) + ".webarchive"
    panel.canCreateDirectories = true
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    popup.addItems(withTitles: SaveFormat.allCases.map(\.title))
    popup.target = chooser
    popup.action = #selector(SaveFormatChooser.choose(_:))
    popup.sizeToFit()
    let row = NSStackView(views: [NSTextField(labelWithString: "Format:"), popup])
    row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
    row.frame.size = row.fittingSize
    panel.accessoryView = row
    let profile = profile
    WebKitHub.shared.downloads.resolveDestination(for: profile) { [weak self, weak view, weak window] folder, _ in
      guard let self, let view, let window, !self.closed, view === self.webView else { return }
      panel.directoryURL = folder
      panel.beginSheetModal(for: window) { [weak self, weak view] response in
        guard response == .OK, let target = panel.url, let self, let view else { return }
        let format = chooser.format
        let stamp = ArdiaConsentStamp.begin()
        self.pageData(format, of: view) { data in
          guard let data else { return Self.saveFailed(stamp) }
          do {
            let staged = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).ardia-saving")
            try data.write(to: staged)
            WebKitDownloads.markDownloaded(staged, source: url, referrer: nil, profile: profile)
            do {
              if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
              } else {
                try FileManager.default.moveItem(at: staged, to: target)
              }
            } catch {
              try? FileManager.default.removeItem(at: staged)
              throw error
            }
            WebKitDownloads.markDownloaded(target, source: url, referrer: nil, profile: profile)
            ArdiaEvents.emit("webKit.counted", data: stamp.onto(["name": "savePage"]))
          } catch {
            Self.saveFailed(stamp)
          }
        }
      }
    }
  }

  private static func saveFailed(_ stamp: ArdiaConsentStamp = .begin()) {
    NSLog("[webkit] Save Page failed")
    ArdiaEvents.emit("webKit.counted", data: stamp.onto(["name": "savePageFailure"]))
  }

  private func pageData(_ format: SaveFormat, of view: WKWebView, done: @escaping (Data?) -> Void) {
    if format == .webArchive {
      return view.createWebArchiveData { result in DispatchQueue.main.async { done(try? result.get()) } }
    }
    let selector = NSSelectorFromString("_getMainResourceDataWithCompletionHandler:")
    guard view.responds(to: selector) else {
      return view.evaluateJavaScript("document.documentElement.outerHTML", in: nil, in: WebKitHub.world) { result in
        done(((try? result.get()) as? String).map { Data($0.utf8) })
      }
    }
    typealias Fetch = @convention(c) (AnyObject, Selector, @escaping @convention(block) (NSData?, NSError?) -> Void) -> Void
    unsafeBitCast(view.method(for: selector), to: Fetch.self)(view, selector) { data, _ in
      DispatchQueue.main.async { done(data as Data?) }
    }
  }
}
