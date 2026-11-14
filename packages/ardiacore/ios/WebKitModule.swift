import AppKit
import ExpoModulesCore
import WebKit

public class WebKitModule: Module {
  public func definition() -> ModuleDefinition {
    Name(Self.calls.moduleName)
    Events(Self.calls.domain)
    Self.calls.forwardEvents(to: self)

    Self.calls.function

    PageViewDefinition.of(WebKitTabView.self)
  }
  static let calls = CallTable(domain: "webKit", handlers: [
    "removeDownloadStaging": { args, reply in
      reply.ok(WebKitDownloads.removeStaging(try args.text("path")))
    },
    "endPrivateSession": { args, reply in
      WebKitHub.shared.endPrivateSession(try args.text("session"))
      reply.ok()
    },
    "cookieStoreKey": { args, reply in reply.ok(WebKitHub.shared.stores.id(of: args.profile).wireKey) },
    "importCookies": { args, reply in
      let cookies = try args.dicts("cookies")
      WebKitHub.shared.importCookies(cookies, profile: args.profile, storeKey: try args.text("storeKey")) { reply.ok($0) }
    },
    "exportCookies": { args, reply in
      let urls = try args.strings("urls").compactMap(URL.init(string:))
      WebKitHub.shared.exportCookies(profile: args.profile, urls: urls) { reply.ok($0) }
    },
    "setZoom": { args, reply in
      WebKitHub.shared.setZoom(try args.double("zoom"), profile: args.profile, host: try args.text("host").lowercased())
      reply.ok()
    },
    "syncExtensions": { args, reply in
      WebKitExtensions.shared.sync(profile: args.profile, entries: try args.dicts("extensions")) { reply.ok($0) }
    },
    "extensionReply": { args, reply in
      WebKitExtensions.shared.reply(try args.text("id"), payload: try args.dict("reply"))
      reply.ok()
    },
    "extensionEvent": { args, reply in
      WebKitExtensions.shared.event(profile: args.profile, payload: try args.dict("event"))
      reply.ok()
    },
    "passkeyAccess": { _, reply in reply.ok(WebKitPasskeys.access()) },
    "requestPasskeyAccess": { _, reply in WebKitPasskeys.requestAccess { reply.ok($0) } },
  ].merging(LaunchConfig.shared.testInstance ? testInstanceCalls : [:]) { call, _ in call })

  private static let testInstanceCalls: [String: CallHandler] = [
    "devStoreExists": { args, reply in WebKitHub.shared.storeExists(args.profile) { reply.ok($0) } },
    "devHoldStore": { args, reply in
      WebKitHub.shared.stores.holdForTest(args.profile)
      reply.ok()
    },
    "devTouchStore": { args, reply in WebKitHub.shared.touchStore(args.profile) { reply.ok($0) } },
    "devParkedTransfers": { _, reply in reply.ok(WebKitHub.shared.transfers.parkedKeys) },
    "devContentBlocker": { _, reply in reply.ok(WebKitContentBlocker.shared.state) },
  ]
}
