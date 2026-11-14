import AppKit

final class WebKitLoginsDropdown: NSObject {
  private static let rowHeight: CGFloat = 36
  private static let inset: CGFloat = 5
  private static let gap: CGFloat = 2
  private static let maxRows = 6
  private static let minWidth: CGFloat = 240
  private static let maxWidth: CGFloat = 420

  var onPick: ((WebKitLogins.Login) -> Void)?
  var onDismiss: (() -> Void)?
  var onSelect: (() -> Void)?

  private var panel: NSPanel?
  private var scroll: NSScrollView?
  private var rows: [WebKitLoginsRow] = []
  private var logins: [WebKitLogins.Login] = []
  private(set) var selected: Int?
  private weak var parent: NSWindow?
  private var parentObservers: [NSObjectProtocol] = []

  var isShown: Bool { panel?.isVisible == true }
  var selectedLogin: WebKitLogins.Login? { selected.flatMap { logins.indices.contains($0) ? logins[$0] : nil } }

  func show(_ logins: [WebKitLogins.Login], under field: NSRect, in window: NSWindow) {
    let kept = selectedLogin
    self.logins = logins
    let panel = panel ?? makePanel()
    self.panel = panel
    let width = min(Self.maxWidth, max(Self.minWidth, field.width))
    let height = CGFloat(min(logins.count, Self.maxRows)) * Self.rowHeight + Self.inset * 2
    let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: -100_000, y: -100_000, width: 200_000, height: 200_000)
    var origin = NSPoint(x: field.minX, y: field.minY - Self.gap - height)
    if origin.y < screen.minY, field.maxY + Self.gap + height <= screen.maxY { origin.y = field.maxY + Self.gap }
    origin.x = max(screen.minX, min(origin.x, screen.maxX - width))
    panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: false)
    build(width: width, height: height)
    select(kept.flatMap { logins.firstIndex(of: $0) }, notify: false)
    if parent !== window { watch(window) }
    if panel.parent !== window {
      panel.parent?.removeChildWindow(panel)
      window.addChildWindow(panel, ordered: .above)
    }
    panel.orderFront(nil)
    panel.invalidateShadow()
  }

  func move(_ step: Int) {
    guard !logins.isEmpty else { return }
    let count = logins.count
    let next = selected.map { (($0 + step) % count + count) % count } ?? (step > 0 ? 0 : count - 1)
    select(next, notify: true)
  }

  func close() {
    selected = nil
    unwatch()
    guard let panel else { return }
    panel.parent?.removeChildWindow(panel)
    panel.orderOut(nil)
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = true
    panel.becomesKeyOnlyIfNeeded = true
    panel.hasShadow = true
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.animationBehavior = .none
    panel.setAccessibilityRole(.menu)
    let effect = NSVisualEffectView()
    effect.material = .menu
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.wantsLayer = true
    effect.layer?.cornerRadius = 8
    effect.layer?.masksToBounds = true
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    scroll.documentView = WebKitLoginsList()
    effect.addSubview(scroll)
    panel.contentView = effect
    self.scroll = scroll
    return panel
  }

  private func build(width: CGFloat, height: CGFloat) {
    guard let scroll, let list = scroll.documentView else { return }
    scroll.frame = NSRect(x: 0, y: Self.inset, width: width, height: height - Self.inset * 2)
    rows.forEach { $0.removeFromSuperview() }
    rows = logins.enumerated().map { index, login -> WebKitLoginsRow in
      let row = WebKitLoginsRow(login: login)
      row.frame = NSRect(x: Self.inset, y: CGFloat(index) * Self.rowHeight, width: width - Self.inset * 2, height: Self.rowHeight)
      row.autoresizingMask = [.width]
      row.onHover = { [weak self] in self?.select(index, notify: true) }
      row.onClick = { [weak self] in
        guard let self, self.logins.indices.contains(index) else { return }
        self.onPick?(self.logins[index])
      }
      list.addSubview(row)
      return row
    }
    list.frame = NSRect(x: 0, y: 0, width: width, height: CGFloat(logins.count) * Self.rowHeight)
    scroll.contentView.scroll(to: .zero)
    scroll.reflectScrolledClipView(scroll.contentView)
  }

  private func select(_ index: Int?, notify: Bool) {
    selected = index.flatMap { logins.indices.contains($0) ? $0 : nil }
    for (i, row) in rows.enumerated() { row.highlighted = i == selected }
    if let selected { rows[selected].scrollToVisible(rows[selected].bounds) }
    if notify { onSelect?() }
  }

  private func watch(_ window: NSWindow) {
    unwatch()
    parent = window
    let center = NotificationCenter.default
    let dismiss: (Notification) -> Void = { [weak self] _ in
      guard let self, self.isShown else { return }
      self.close()
      self.onDismiss?()
    }
    parentObservers = [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.didResizeNotification, NSWindow.willEnterFullScreenNotification].map {
      center.addObserver(forName: $0, object: window, queue: .main, using: dismiss)
    }
  }

  private func unwatch() {
    parentObservers.forEach { NotificationCenter.default.removeObserver($0) }
    parentObservers = []
    parent = nil
  }
}

private final class WebKitLoginsList: NSView {
  override var isFlipped: Bool { true }
}

private final class WebKitLoginsRow: NSView {
  var onHover: (() -> Void)?
  var onClick: (() -> Void)?
  var highlighted = false {
    didSet {
      guard highlighted != oldValue else { return }
      needsDisplay = true
      paint()
    }
  }

  private let icon = NSImageView()
  private let title = NSTextField(labelWithString: "")
  private let detail = NSTextField(labelWithString: "")
  private let named: Bool

  init(login: WebKitLogins.Login) {
    named = !login.username.isEmpty
    super.init(frame: .zero)
    icon.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
    title.stringValue = named ? login.username : "No username"
    title.font = .menuFont(ofSize: 13)
    title.lineBreakMode = .byTruncatingTail
    detail.stringValue = login.match == "exact" ? String(repeating: "•", count: 8) : Self.site(login.realm)
    detail.font = .menuFont(ofSize: 11)
    detail.lineBreakMode = .byTruncatingMiddle
    for view in [icon, title, detail] { addSubview(view) }
    setAccessibilityElement(true)
    setAccessibilityRole(.menuItem)
    setAccessibilityLabel(login.match == "exact" ? title.stringValue : "\(title.stringValue), \(detail.stringValue)")
    paint()
  }

  required init?(coder: NSCoder) { nil }

  private static func site(_ realm: String) -> String { URL(string: realm)?.host ?? realm }

  override var isFlipped: Bool { true }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func layout() {
    super.layout()
    let text = bounds.insetBy(dx: 0, dy: 3)
    icon.frame = NSRect(x: 8, y: (bounds.height - 16) / 2, width: 16, height: 16)
    let left: CGFloat = 32
    title.frame = NSRect(x: left, y: text.minY + 1, width: bounds.width - left - 10, height: 16)
    detail.frame = NSRect(x: left, y: text.minY + 17, width: bounds.width - left - 10, height: 13)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach { removeTrackingArea($0) }
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
  }

  override func mouseEntered(with event: NSEvent) { onHover?() }

  override func mouseMoved(with event: NSEvent) { if !highlighted { onHover?() } }

  override func mouseDown(with event: NSEvent) {}

  override func mouseUp(with event: NSEvent) {
    if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
  }

  override func accessibilityPerformPress() -> Bool {
    onClick?()
    return true
  }

  override func draw(_ dirtyRect: NSRect) {
    guard highlighted else { return }
    NSColor.selectedContentBackgroundColor.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
  }

  private func paint() {
    let selectedText = NSColor.alternateSelectedControlTextColor
    title.textColor = highlighted ? selectedText : named ? .labelColor : .secondaryLabelColor
    detail.textColor = highlighted ? selectedText.withAlphaComponent(0.8) : .secondaryLabelColor
    icon.contentTintColor = highlighted ? selectedText : .secondaryLabelColor
  }
}
