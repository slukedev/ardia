import Foundation

extension WebKitTab {
  static func errorPage(_ url: URL, _ error: NSError) -> String {
    let escape = { (text: String) in
      text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
    return """
      <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark"><title>Can't Open This Page</title>
      <style>body{font:13px -apple-system,system-ui;display:flex;align-items:center;justify-content:center;height:90vh;margin:0;color:#555}
      @media (prefers-color-scheme: dark){body{color:#bbb;background:#1e1e1e}}main{max-width:460px;text-align:center}
      h1{font-size:20px;font-weight:600;color:CanvasText;margin:0 0 8px}p{margin:4px 0;word-break:break-word}</style></head>
      <body><main><h1>Can't open this page</h1><p>\(escape(url.host ?? url.absoluteString))</p><p>\(escape(error.localizedDescription))</p></main></body></html>
      """
  }
}
