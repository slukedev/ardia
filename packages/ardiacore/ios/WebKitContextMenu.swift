import AppKit
import UniformTypeIdentifiers
import WebKit

struct WebKitMenuTarget {
  enum Media { case video, audio }

  var link: URL?
  var linkText = ""
  var image: URL?
  var media: URL?
  var mediaKind: Media?
  var mediaLoops: Bool?
  var mediaShowsControls: Bool?
  var editable = false
  var selection = ""
  var page: URL?
  var pageTitle = ""
  var point = NSPoint.zero
  var pointInPage = NSPoint.zero
  var frame: WKFrameInfo?

  private func web(_ url: URL?) -> Bool { ["http", "https"].contains(url?.scheme?.lowercased() ?? "") }

  enum Share: String { case text, link, image, video, audio, page }

  var shares: [Share] {
    if editable { return [] }
    var found: [Share] = []
    let collapsed = { (text: String) in text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    let selectedLink = web(link) && collapsed(selection) == collapsed(linkText)
    if !selection.isEmpty && !selectedLink { found.append(.text) }
    if web(link) { found.append(.link) }
    if image != nil { found.append(.image) }
    if mediaKind == .video, web(media) { found.append(.video) }
    if mediaKind == .audio, web(media) { found.append(.audio) }
    if found.isEmpty, link == nil, image == nil, mediaKind == nil, web(page) { found.append(.page) }
    return found
  }
}

final class WebKitMenuAction: NSObject {
  let run: () -> Void

  init(_ run: @escaping () -> Void) {
    self.run = run
  }

  @objc func activate(_ sender: Any?) { run() }

  static func item(_ title: String, enabled: Bool = true, _ run: @escaping () -> Void) -> NSMenuItem {
    let action = WebKitMenuAction(run)
    let item = NSMenuItem(title: title, action: enabled ? #selector(activate(_:)) : nil, keyEquivalent: "")
    item.target = action
    item.representedObject = action
    item.isEnabled = enabled
    return item
  }
}

struct WebKitMenuCommands {
  let tab: WebKitTab
  let target: WebKitMenuTarget

  static func opensFromPage(_ url: URL, page: URL?) -> Bool {
    switch url.scheme?.lowercased() ?? "" {
    case "http", "https": true
    case "about": url.absoluteString.lowercased() == "about:blank"
    case let scheme where ["file", "ardia"].contains(scheme): page?.scheme?.lowercased() == scheme
    default: false
    }
  }

  func open(_ url: URL?, _ disposition: String) {
    guard let url, Self.opensFromPage(url, page: target.page) else { return }
    tab.emit("openWindow", ["url": url.absoluteString, "disposition": disposition, "userGesture": true])
  }

  func copyAddress(_ url: URL?) {
    guard let url else { return }
    let board = NSPasteboard.general
    board.clearContents()
    board.writeObjects([url as NSURL])
    board.setString(url.absoluteString, forType: .string)
  }

  static let findMedia = """
    const at = document.elementFromPoint(x, y)?.closest("video, audio");
    const all = Array.from(document.querySelectorAll("video, audio"));
    const named = (m) => !!src && (m.currentSrc === src || m.src === src);
    const m = (at && (!src || named(at)) ? at : null) || all.find(named) || (all.length === 1 ? all[0] : null);
    if (!m) return null;
    """

  func onMedia(_ body: String, _ done: @escaping (Any?) -> Void = { _ in }) {
    guard let view = tab.webView else { return done(nil) }
    let point = target.pointInPage
    let arguments: [String: Any] = ["x": Double(point.x), "y": Double(point.y), "src": target.media?.absoluteString ?? ""]
    view.callAsyncJavaScript(Self.findMedia + body, arguments: arguments, in: target.frame, in: .defaultClient) { result in done(try? result.get()) }
  }

  static let frameCapture =
    "if (!m.videoWidth) return null; const c = document.createElement('canvas'); c.width = m.videoWidth; c.height = m.videoHeight; c.getContext('2d').drawImage(m, 0, 0); try { return c.toDataURL('image/png'); } catch (e) { return null; }"

  static func png(_ value: Any?) -> Data? {
    guard let url = value as? String, let comma = url.firstIndex(of: ","), url.hasPrefix("data:image/png;base64") else { return nil }
    return Data(base64Encoded: String(url[url.index(after: comma)...]))
  }

  func copyVideoFrame() {
    onMedia(Self.frameCapture) { value in
      guard let data = Self.png(value) else { return }
      let board = NSPasteboard.general
      board.clearContents()
      board.setData(data, forType: .png)
    }
  }

  func saveVideoFrame() {
    let tab = tab
    let name = (target.media?.deletingPathExtension().lastPathComponent).flatMap { $0.isEmpty ? nil : $0 } ?? "Video Frame"
    onMedia(Self.frameCapture) { value in
      guard let data = Self.png(value), let window = tab.window else { return }
      if LaunchConfig.shared.background { return NSLog("[webkit] save panel (background mode, not shown): %@.png", name) }
      let panel = NSSavePanel()
      panel.nameFieldStringValue = name + ".png"
      panel.allowedContentTypes = [.png]
      panel.beginSheetModal(for: window) { response in
        guard response == .OK, let url = panel.url, (try? data.write(to: url, options: .atomic)) != nil else { return }
        WebKitDownloads.markDownloaded(url, source: tab.webView?.url, referrer: nil, profile: tab.profile)
      }
    }
  }
}

final class WebKitContextMenu {
  private let tab: WebKitTab
  private let target: WebKitMenuTarget
  private var native: [String: NSMenuItem] = [:]
  private let menu = NSMenu()
  private var run: WebKitMenuCommands { WebKitMenuCommands(tab: tab, target: target) }

  init(tab: WebKitTab, target: WebKitMenuTarget, proposed: NSMenu) {
    self.tab = tab
    self.target = target
    for item in proposed.items {
      if let id = item.identifier?.rawValue, id.hasPrefix("WKMenuItemIdentifier") { native[id] = item }
    }
    proposed.removeAllItems()
    menu.autoenablesItems = false
  }

  private func take(_ id: String, as title: String? = nil) -> NSMenuItem? {
    guard let item = native.removeValue(forKey: "WKMenuItemIdentifier\(id)") else { return nil }
    if let title { item.title = title }
    return item
  }

  private func add(_ item: NSMenuItem?) {
    if let item { menu.addItem(item) }
  }

  private func separate() {
    guard let last = menu.items.last, !last.isSeparatorItem else { return }
    menu.addItem(.separator())
  }

  private static func modifiers() -> [String: Bool] {
    let flags = NSApp.currentEvent?.modifierFlags ?? []
    return ["metaKey": flags.contains(.command), "shiftKey": flags.contains(.shift), "altKey": flags.contains(.option)]
  }

  static func selectionLabel(_ text: String) -> String {
    let collapsed = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ") as NSString
    let limit = 50
    if collapsed.length <= limit { return collapsed as String }
    let space = collapsed.range(of: " ", options: .backwards, range: NSRange(location: 0, length: limit))
    let end = space.location != NSNotFound && space.location > 25 ? space.location : limit
    let whole = collapsed.rangeOfComposedCharacterSequences(for: NSRange(location: 0, length: end))
    return collapsed.substring(with: whole) + "…"
  }

  private func shareTitle(_ share: WebKitMenuTarget.Share, only: Bool) -> String {
    if only { return "Share…" }
    switch share {
    case .text: return "Share Text…"
    case .link: return "Share Link…"
    case .image: return "Share Image…"
    case .video: return "Share Video…"
    case .audio: return "Share Audio…"
    case .page: return "Share Page…"
    }
  }

  private func addShare(_ share: WebKitMenuTarget.Share) {
    let shares = target.shares
    guard shares.contains(share) else { return }
    let target = target
    let tab = tab
    menu.addItem(WebKitMenuAction.item(shareTitle(share, only: shares.count == 1)) {
      var item: [String: Any] = ["kind": share.rawValue]
      switch share {
      case .text: item["text"] = target.selection
      case .link:
        item["url"] = target.link?.absoluteString ?? ""
        item["title"] = target.linkText
      case .image: item["url"] = target.image?.absoluteString ?? ""
      case .video, .audio: item["url"] = target.media?.absoluteString ?? ""
      case .page:
        item["url"] = target.page?.absoluteString ?? ""
        item["title"] = target.pageTitle
      }
      tab.emit("command", [
        "command": "share", "text": item["text"] ?? "", "share": item,
        "anchor": [target.point.x - 1, target.point.y - 1, 2, 2],
      ])
    })
  }

  private func addLinkItems() {
    let link = target.link
    add(WebKitMenuAction.item("Open Link in New Tab") { [run] in run.open(link, "background") })
    add(WebKitMenuAction.item("Open Link in New Window") { [run] in run.open(link, "window") })
    add(WebKitMenuAction.item("Open Link in Split View") { [run] in run.open(link, "split") })
    add(WebKitMenuAction.item("Open Link in Incognito Window") { [run] in run.open(link, "incognito") })
    separate()
    add(take("DownloadLinkedFile", as: "Save Link As…"))
    add(WebKitMenuAction.item("Copy Link Address") { [run] in run.copyAddress(link) })
    addShare(.link)
  }

  private func addImageItems() {
    let image = target.image
    add(WebKitMenuAction.item("Open Image in New Tab") { [run] in run.open(image, "background") })
    add(take("DownloadImage", as: "Save Image As…"))
    add(take("CopyImage", as: "Copy Image"))
    add(WebKitMenuAction.item("Copy Image Address") { [run] in run.copyAddress(image) })
    addShare(.image)
  }

  private func addMediaItems(_ kind: WebKitMenuTarget.Media) {
    let media = target.media
    let noun = kind == .video ? "Video" : "Audio"
    add(WebKitMenuAction.item("Loop") { [run] in run.onMedia("m.loop = !m.loop; return m.loop;") }.checked(target.mediaLoops))
    add(WebKitMenuAction.item("Show All Controls") { [run] in run.onMedia("m.controls = !m.controls; return m.controls;") }.checked(target.mediaShowsControls))
    separate()
    add(WebKitMenuAction.item("Open \(noun) in New Tab") { [run] in run.open(media, "background") })
    if kind == .video { add(WebKitMenuAction.item("Save Video Frame As…") { [run] in run.saveVideoFrame() }) }
    add(take("DownloadMedia", as: "Save \(noun) As…"))
    if kind == .video { add(WebKitMenuAction.item("Copy Video Frame") { [run] in run.copyVideoFrame() }) }
    add(WebKitMenuAction.item("Copy \(noun) Address") { [run] in run.copyAddress(media) })
    if kind == .video { add(take("TogglePictureInPicture", as: "Picture in Picture")) }
    addShare(kind == .video ? .video : .audio)
  }

  private func addSearchItem() {
    let text = target.selection
    let tab = tab
    let title = "Search \(ArdiaWebView.searchEngineNameInUse()) for “\(Self.selectionLabel(text))”"
    menu.addItem(WebKitMenuAction.item(title) {
      tab.emit("command", ["command": "search", "text": text, "modifiers": Self.modifiers()])
    })
  }

  private func addPrintItem() {
    let tab = tab
    menu.addItem(WebKitMenuAction.item("Print…") { tab.print() })
  }

  private func addSelectionItems() {
    if target.link == nil {
      add(take("LookUp"))
      add(take("Translate"))
      separate()
    }
    add(take("Copy", as: "Copy"))
    add(take("CopyLinkWithHighlight", as: "Copy Link to Highlight") ?? WebKitMenuAction.item("Copy Link to Highlight", enabled: false) {})
    addSearchItem()
    addPrintItem()
    addShare(.text)
  }

  private func responderItem(_ title: String, _ selector: Selector) -> NSMenuItem {
    NSMenuItem(title: title, action: selector, keyEquivalent: "")
  }

  private func addEditableItems() {
    add(take("LookUp"))
    add(take("Translate"))
    separate()
    add(responderItem("Emoji & Symbols", #selector(NSApplication.orderFrontCharacterPalette(_:))))
    separate()
    let undo = tab.webView?.undoManager
    add(responderItem("Undo", Selector(("undo:"))).enabling(undo?.canUndo == true))
    add(responderItem("Redo", Selector(("redo:"))).enabling(undo?.canRedo == true))
    separate()
    let selected = !target.selection.isEmpty
    let pasteable = NSPasteboard.general.availableType(from: [.string, .rtf, .html, .URL, .fileURL, .tiff, .png]) != nil
    add(responderItem("Cut", #selector(NSText.cut(_:))).enabling(selected))
    add(responderItem("Copy", #selector(NSText.copy(_:))).enabling(selected))
    add((take("Paste", as: "Paste") ?? responderItem("Paste", #selector(NSText.paste(_:)))).enabling(pasteable))
    add(responderItem("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:))).enabling(pasteable))
    add(responderItem("Select All", #selector(NSText.selectAll(_:))))
    separate()
    addPrintItem()
    separate()
    let direction = NSMenuItem(title: "Writing Direction", action: nil, keyEquivalent: "")
    let directions = NSMenu(title: "Writing Direction")
    directions.addItem(responderItem("Default", #selector(NSResponder.makeBaseWritingDirectionNatural(_:))))
    directions.addItem(responderItem("Left to Right", #selector(NSResponder.makeBaseWritingDirectionLeftToRight(_:))))
    directions.addItem(responderItem("Right to Left", #selector(NSResponder.makeBaseWritingDirectionRightToLeft(_:))))
    direction.submenu = directions
    add(direction)
  }

  private func addPageItems() {
    let tab = tab
    guard let view = tab.webView else { return }
    add(WebKitMenuAction.item("Back", enabled: view.canGoBack) { tab.goBack() })
    add(WebKitMenuAction.item("Forward", enabled: view.canGoForward) { tab.goForward() })
    add(WebKitMenuAction.item("Reload") { tab.reload() })
    separate()
    add(WebKitMenuAction.item("Save As…", enabled: target.page != nil) { tab.runPageFileCommand("savePage") })
    addPrintItem()
    addShare(.page)
  }

  func build() -> NSMenu {
    if target.editable {
      addEditableItems()
    } else {
      if target.link != nil { addLinkItems() }
      if target.image != nil {
        separate()
        addImageItems()
      }
      if let kind = target.mediaKind {
        separate()
        addMediaItems(kind)
      }
      if !target.selection.isEmpty {
        separate()
        addSelectionItems()
      }
      if target.link == nil, target.image == nil, target.mediaKind == nil, target.selection.isEmpty { addPageItems() }
    }
    separate()
    let tab = tab
    if !target.editable, target.link == nil, target.image == nil, target.mediaKind == nil, target.selection.isEmpty {
      add(WebKitMenuAction.item("View Page Source") { tab.runPageFileCommand("viewSource") })
    }
    add(take("InspectElement", as: "Inspect") ?? WebKitMenuAction.item("Inspect") { tab.showWebKitDevTools(panel: "inspect") })
    if !target.selection.isEmpty, let speech = take("SpeechMenu", as: "Speech") {
      separate()
      menu.addItem(speech)
    }
    while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
    return menu
  }
}

private extension NSMenuItem {
  func enabling(_ on: Bool) -> NSMenuItem {
    isEnabled = on
    return self
  }

  func checked(_ on: Bool?) -> NSMenuItem {
    state = on == true ? .on : .off
    return self
  }
}

extension WebKitTab {
  private static func value<T>(_ object: NSObject?, _ key: String) -> T? {
    guard let object, object.responds(to: NSSelectorFromString(key)) else { return nil }
    return object.value(forKey: key) as? T
  }

  private func menuTarget(_ element: AnyObject) -> WebKitMenuTarget {
    let hit: NSObject? = Self.value(element as? NSObject, "hitTestResult")
    var target = WebKitMenuTarget()
    target.link = Self.value(hit, "absoluteLinkURL")
    target.linkText = (Self.value(hit, "linkLabel") as String?) ?? ""
    target.image = Self.value(hit, "absoluteImageURL")
    let mediaURL: URL? = Self.value(hit, "absoluteMediaURL")
    let elementType = (Self.value(hit, "elementType") as NSNumber?)?.intValue ?? 0
    if mediaURL != nil || elementType != 0 {
      target.media = mediaURL
      target.mediaKind = elementType == 1 ? .audio : .video
    }
    target.editable = (Self.value(hit, "isContentEditable") as NSNumber?)?.boolValue ?? false
    target.frame = Self.value(hit, "frameInfo")
    target.page = webView?.url
    target.pageTitle = webView?.title ?? ""
    if let view = webView, let window {
      let inWindow = view.lastContextClick ?? window.mouseLocationOutsideOfEventStream
      target.point = NSPoint(x: inWindow.x, y: (window.contentView?.frame.height ?? 0) - inWindow.y)
      let box = (Self.value(hit, "elementBoundingBox") as NSValue?)?.rectValue ?? .zero
      let inView = target.mediaKind != nil && !box.isEmpty ? NSPoint(x: box.midX, y: box.midY) : view.convert(inWindow, from: nil)
      let scale = max(view.pageZoom * view.magnification, 0.01)
      target.pointInPage = NSPoint(x: inView.x / scale, y: inView.y / scale)
    }
    return target
  }

  @objc(_webView:getContextMenuFromProposedMenu:forElement:userInfo:completionHandler:)
  func webView(_ webView: WKWebView, contextMenuFromProposedMenu proposed: NSMenu, forElement element: AnyObject, userInfo: AnyObject?,
               completionHandler: @escaping (NSMenu?) -> Void) {
    var target = menuTarget(element)
    let identifiers = proposed.items.compactMap { $0.identifier?.rawValue }
    let wantsSelection = identifiers.contains("WKMenuItemIdentifierCopy") || identifiers.contains("WKMenuItemIdentifierLookUp") || target.editable
    let finish = { [weak self] in
      guard let self else { return completionHandler(proposed) }
      let menu = WebKitContextMenu(tab: self, target: target, proposed: proposed).build()
      ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "contextMenu"]))
      completionHandler(self.showOrDump(menu, target: target))
    }
    let readMedia = { [weak self] in
      guard let self, target.mediaKind != nil else { return finish() }
      WebKitMenuCommands(tab: self, target: target).onMedia("return [m.loop, m.controls];") { value in
        if let flags = value as? [Bool], flags.count == 2 {
          target.mediaLoops = flags[0]
          target.mediaShowsControls = flags[1]
        }
        finish()
      }
    }
    guard wantsSelection else { return readMedia() }
    let code = "(() => { const a = document.activeElement; if (a && (a.localName === 'input' || a.localName === 'textarea')) { try { return a.value.substring(a.selectionStart, a.selectionEnd); } catch (e) { return ''; } } return String(getSelection()); })()"
    webView.evaluateJavaScript(code, in: target.frame, in: .defaultClient) { result in
      if case .success(let text) = result, let text = text as? String { target.selection = text }
      readMedia()
    }
  }

  private static func describe(_ menu: NSMenu) -> [[String: Any]] {
    menu.items.map { item in
      var entry: [String: Any] = [
        "id": item.tag, "label": item.isSeparatorItem ? "" : item.title, "enabled": item.isSeparatorItem || item.isEnabled,
        "type": item.isSeparatorItem ? 4 : item.submenu != nil ? 5 : 1, "visible": !item.isHidden,
      ]
      if let submenu = item.submenu { entry["submenu"] = describe(submenu) }
      return entry
    }
  }

  private static func find(_ label: String, in menu: NSMenu) -> (NSMenu, Int)? {
    for (index, item) in menu.items.enumerated() {
      if item.title == label, !item.isSeparatorItem { return (menu, index) }
      if let submenu = item.submenu, let found = find(label, in: submenu) { return found }
    }
    return nil
  }

  private func showOrDump(_ menu: NSMenu, target: WebKitMenuTarget) -> NSMenu {
    let config = LaunchConfig.shared
    guard config.background || config.testFlag("contextMenu") else { return menu }
    let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title).joined(separator: " | ")
    guard config.testFlag("contextMenu"), let dir = config.dataDirectory else {
      NSLog("[webkit] context menu (not shown): %@", titles)
      return NSMenu()
    }
    let path = (dir as NSString).appendingPathComponent("context-menu.json")
    let dump: [String: Any] = ["url": target.page?.absoluteString ?? "", "link": target.link?.absoluteString ?? "", "items": Self.describe(menu)]
    if let data = try? JSONSerialization.data(withJSONObject: dump) { try? data.write(to: URL(fileURLWithPath: path), options: .atomic) }
    let pickPath = path + ".pick"
    let pick = (try? String(contentsOfFile: pickPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    try? FileManager.default.removeItem(atPath: pickPath)
    let label = pick.split(separator: "\t", maxSplits: 1).first.map(String.init) ?? ""
    if !label.isEmpty, let (owner, index) = Self.find(label, in: menu), owner.items[index].isEnabled {
      NSLog("[webkit] context menu pick: %@", label)
      DispatchQueue.main.async { owner.performActionForItem(at: index) }
    }
    return NSMenu()
  }
}
