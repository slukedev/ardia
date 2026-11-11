import Foundation

enum GoogleImportScripts {
  static func snapshot(_ selectors: GoogleImportSelectors = .current) -> String {
    """
    const s = \(json(selectors));
    const visible = (el) => !!el && el.isConnected && el.getClientRects().length > 0 && getComputedStyle(el).visibility !== "hidden" && !el.closest('[aria-hidden="true"]');
    const all = (q) => Array.from(document.querySelectorAll(q));
    const label = (b) => (b.innerText || b.textContent || "").trim();
    const dialog = all(s.dialogs).filter(visible).pop() || null;
    const importButton = s.importButtons.some((q) => all(q).some((b) => visible(b) && !(dialog && dialog.contains(b))));
    const exportButton = !dialog && s.exportButtons.some((q) => all(q).some(visible));
    post("result", JSON.stringify({
      url: location.href,
      text: (document.body ? document.body.innerText : "").slice(0, 6000),
      dialog: dialog ? (dialog.innerText || "").slice(0, 2000) : null,
      dialogButtons: dialog ? Array.from(dialog.querySelectorAll(s.buttons)).filter(visible).map(label).filter(Boolean) : [],
      importButton,
      exportButton,
      fileInput: all(s.fileInputs).length > 0,
      preparing: all(s.preparing).some(visible),
      passwordField: all(s.passwordFields).some(visible),
      passwordInvalid: all(s.invalidFields).some(visible),
      captcha: all(s.captchaFrames).some(visible),
      ready: document.readyState !== "loading",
    }));
    """
  }

  enum Target: String {
    case importButton
    case exportButton
    case confirmExport
    case selectFile
    case confirmImport
    case done
  }

  static func click(_ target: Target, _ selectors: GoogleImportSelectors = .current) -> String {
    """
    const s = \(json(selectors));
    const target = \(json(target.rawValue));
    const visible = (el) => !!el && el.isConnected && el.getClientRects().length > 0 && getComputedStyle(el).visibility !== "hidden" && !el.closest('[aria-hidden="true"]');
    const all = (q, root) => Array.from((root || document).querySelectorAll(q));
    const label = (b) => (b.innerText || b.textContent || "").trim();
    const dialog = all(s.dialogs).filter(visible).pop() || null;
    let button = null;
    if (target === "importButton") {
      button = s.importButtons.map((q) => all(q).find((b) => visible(b) && !(dialog && dialog.contains(b)))).find(Boolean)
        || all(s.buttons).find((b) => visible(b) && label(b) === s.importButtonText && !(dialog && dialog.contains(b)));
    } else if (target === "exportButton") {
      button = dialog ? null : s.exportButtons.map((q) => all(q).find(visible)).find(Boolean) || null;
    } else if (dialog) {
      const text = target === "selectFile" ? s.selectFileText : target === "confirmImport" ? s.confirmImportText : target === "confirmExport" ? s.confirmExportText : s.doneText;
      button = all(s.buttons, dialog).find((b) => visible(b) && label(b) === text);
    }
    if (button) button.click();
    post("result", JSON.stringify(!!button));
    """
  }

  private static func json<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
  }
}
