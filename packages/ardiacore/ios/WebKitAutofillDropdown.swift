import AppKit

final class WebKitAutofillDropdown: NSObject {
  struct Row: Equatable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    var enabled = true
    var muted = false
    var spokenLabel: String?
  }

  private static let rowHeight: CGFloat = 36
  private static let noticeHeight: CGFloat = 62
  private static let inset: CGFloat = 5
  private static let gap: CGFloat = 2
  private static let maxRows = 6
  private static let minWidth: CGFloat = 240
  private static let maxWidth: CGFloat = 420

  var onPick: ((Row) -> Void)?
  var onDismiss: (() -> Void)?
  var onSelect: (() -> Void)?

  private var panel: NSPanel?
  private var scroll: NSScrollView?
  private var views: [WebKitAutofillRowView] = []
  private(set) var rows: [Row] = []
  private(set) var selected: Int?
  private weak var parent: NSWindow?
  private var parentObservers: [NSObjectProtocol] = []

  var isShown: Bool { panel?.isVisible == true }
  var selectedRow: Row? { selected.flatMap { rows.indices.contains($0) ? rows[$0] : nil } }

  private static func height(of row: Row) -> CGFloat { row.enabled ? rowHeight : noticeHeight }

  func show(_ rows: [Row], under field: NSRect, in window: NSWindow) {
    let kept = selectedRow
    self.rows = rows
    let panel = panel ?? makePanel()
    self.panel = panel
    let width = min(Self.maxWidth, max(Self.minWidth, field.width))
    let content = rows.map(Self.height(of:)).reduce(0, +)
    let visible = rows.prefix(Self.maxRows).map(Self.height(of:)).reduce(0, +)
    let height = visible + Self.inset * 2
    let screen = Self.screen(showing: field, in: window)
    var origin = NSPoint(x: field.minX, y: field.minY - Self.gap - height)
    if origin.y < screen.minY, field.maxY + Self.gap + height <= screen.maxY { origin.y = field.maxY + Self.gap }
    origin.x = max(screen.minX, min(origin.x, screen.maxX - width))
    panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: false)
    build(width: width, height: height, content: content)
    select(kept.flatMap { rows.firstIndex(of: $0) }, notify: false)
    if parent !== window { watch(window) }
    if panel.parent !== window {
      panel.parent?.removeChildWindow(panel)
      window.addChildWindow(panel, ordered: .above)
    }
    panel.orderFront(nil)
    panel.invalidateShadow()
  }

  private static func screen(showing field: NSRect, in window: NSWindow) -> NSRect {
    let anchor = NSPoint(x: field.midX, y: field.midY)
    let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? window.screen ?? NSScreen.main
    return screen?.visibleFrame ?? NSRect(x: -100_000, y: -100_000, width: 200_000, height: 200_000)
  }

  func move(_ step: Int) {
    let choices = rows.indices.filter { rows[$0].enabled }
    guard !choices.isEmpty else { return }
    let position = selected.flatMap { choices.firstIndex(of: $0) }
    let count = choices.count
    let next = position.map { (($0 + step) % count + count) % count } ?? (step > 0 ? 0 : count - 1)
    select(choices[next], notify: true)
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
    scroll.documentView = WebKitAutofillList()
    effect.addSubview(scroll)
    panel.contentView = effect
    self.scroll = scroll
    return panel
  }

  private func build(width: CGFloat, height: CGFloat, content: CGFloat) {
    guard let scroll, let list = scroll.documentView else { return }
    scroll.frame = NSRect(x: 0, y: Self.inset, width: width, height: height - Self.inset * 2)
    views.forEach { $0.removeFromSuperview() }
    list.frame = NSRect(x: 0, y: 0, width: width, height: content)
    var y: CGFloat = 0
    views = rows.enumerated().map { index, row -> WebKitAutofillRowView in
      let view = WebKitAutofillRowView(row: row)
      let rowHeight = Self.height(of: row)
      view.frame = NSRect(x: Self.inset, y: y, width: width - Self.inset * 2, height: rowHeight)
      y += rowHeight
      if row.enabled {
        view.onHover = { [weak self] in self?.select(index, notify: true) }
        view.onClick = { [weak self] in
          guard let self, self.rows.indices.contains(index) else { return }
          self.onPick?(self.rows[index])
        }
      }
      list.addSubview(view)
      return view
    }
    scroll.contentView.scroll(to: .zero)
    scroll.reflectScrolledClipView(scroll.contentView)
  }

  private func select(_ index: Int?, notify: Bool) {
    selected = index.flatMap { rows.indices.contains($0) && rows[$0].enabled ? $0 : nil }
    for (i, view) in views.enumerated() { view.highlighted = i == selected }
    if let selected { views[selected].scrollToVisible(views[selected].bounds) }
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

private final class WebKitAutofillList: NSView {
  override var isFlipped: Bool { true }
}

private final class WebKitAutofillRowView: NSView {
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
  private let notice: String
  private let detail = NSTextField(labelWithString: "")
  private let enabled: Bool
  private let muted: Bool

  init(row: WebKitAutofillDropdown.Row) {
    enabled = row.enabled
    muted = row.muted
    notice = row.enabled ? "" : row.title
    super.init(frame: .zero)
    icon.image = NSImage(systemSymbolName: row.symbol, accessibilityDescription: nil)
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
    title.stringValue = row.title
    title.font = .menuFont(ofSize: enabled ? 13 : 12)
    title.lineBreakMode = .byTruncatingTail
    title.isHidden = !enabled
    detail.stringValue = row.detail
    detail.font = .menuFont(ofSize: 11)
    detail.lineBreakMode = .byTruncatingTail
    detail.isHidden = row.detail.isEmpty
    for view in [icon, title, detail] { addSubview(view) }
    setAccessibilityElement(true)
    setAccessibilityRole(enabled ? .menuItem : .staticText)
    setAccessibilityLabel(row.spokenLabel ?? (row.detail.isEmpty ? row.title : "\(row.title), \(row.detail)"))
    paint()
  }

  required init?(coder: NSCoder) { nil }

  override var isFlipped: Bool { true }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { enabled }

  override func layout() {
    super.layout()
    let left: CGFloat = 32
    let width = bounds.width - left - 10
    icon.frame = NSRect(x: 8, y: enabled ? (bounds.height - 16) / 2 : 8, width: 16, height: 16)
    guard enabled else {
      needsDisplay = true
      return
    }
    let text = bounds.insetBy(dx: 0, dy: 3)
    if detail.isHidden {
      title.frame = NSRect(x: left, y: (bounds.height - 16) / 2, width: width, height: 16)
    } else {
      title.frame = NSRect(x: left, y: text.minY + 1, width: width, height: 16)
      detail.frame = NSRect(x: left, y: text.minY + 17, width: width, height: 13)
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach { removeTrackingArea($0) }
    guard enabled else { return }
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
  }

  override func mouseEntered(with event: NSEvent) { onHover?() }

  override func mouseMoved(with event: NSEvent) { if !highlighted { onHover?() } }

  override func mouseDown(with event: NSEvent) {}

  override func mouseUp(with event: NSEvent) {
    if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
  }

  override func accessibilityPerformPress() -> Bool {
    guard enabled else { return false }
    onClick?()
    return true
  }

  override func draw(_ dirtyRect: NSRect) {
    if !notice.isEmpty {
      let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
      notice.draw(with: NSRect(x: 32, y: 6, width: bounds.width - 42, height: bounds.height - 12), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }
    guard highlighted else { return }
    NSColor.selectedContentBackgroundColor.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
  }

  private func paint() {
    let selectedText = NSColor.alternateSelectedControlTextColor
    title.textColor = highlighted ? selectedText : enabled && !muted ? .labelColor : .secondaryLabelColor
    detail.textColor = highlighted ? selectedText.withAlphaComponent(0.8) : .secondaryLabelColor
    icon.contentTintColor = highlighted ? selectedText : .secondaryLabelColor
  }
}
