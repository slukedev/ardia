import Foundation
import WebKit

extension WebKitHub {
  static let httpOnlyCookieKey = HTTPCookiePropertyKey("HttpOnly")

  static func httpCookie(fromEngine cookie: [String: Any]) -> HTTPCookie? {
    guard cookie["partitionKey"] == nil || cookie["partitionKey"] is NSNull, cookie["partitionKeyOpaque"] as? Bool != true,
      let name = cookie["name"] as? String, !name.isEmpty,
      let value = cookie["value"] as? String,
      let domain = cookie["domain"] as? String, !domain.isEmpty
    else { return nil }
    let path = (cookie["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "/"
    var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
    if cookie["secure"] as? Bool == true { properties[.secure] = "TRUE" }
    if cookie["httpOnly"] as? Bool == true { properties[httpOnlyCookieKey] = "TRUE" }
    if cookie["session"] as? Bool != true, let expires = cookie["expires"] as? Double, expires > 0 {
      guard expires > Date().timeIntervalSince1970 else { return nil }
      properties[.expires] = Date(timeIntervalSince1970: expires)
    }
    switch cookie["sameSite"] as? String {
    case "None": break
    case "Strict": properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict.rawValue
    default: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax.rawValue
    }
    return HTTPCookie(properties: properties)
  }

  func importCookies(_ cookies: [[String: Any]], profile: String, storeKey: String, completion: @escaping (Int) -> Void) {
    let made = cookies.compactMap(Self.httpCookie(fromEngine:))
    guard !made.isEmpty, let store = stores.liveDataStore(for: profile, wireKey: storeKey)?.httpCookieStore else { return completion(0) }
    let group = DispatchGroup()
    for cookie in made {
      group.enter()
      store.setCookie(cookie) { group.leave() }
    }
    group.notify(queue: .main) { completion(made.count) }
  }

  static func sends(_ cookie: HTTPCookie, to url: URL) -> Bool {
    guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
    let domain = cookie.domain.lowercased()
    let matchesHost = domain.hasPrefix(".") ? (host == String(domain.dropFirst()) || host.hasSuffix(domain)) : host == domain
    let path = url.path.isEmpty ? "/" : url.path
    let matchesPath = cookie.path == "/" || path == cookie.path || path.hasPrefix(cookie.path.hasSuffix("/") ? cookie.path : cookie.path + "/")
    let live = cookie.expiresDate.map { $0 > Date() } ?? true
    return matchesHost && matchesPath && live && (!cookie.isSecure || url.scheme?.lowercased() == "https")
  }

  private static func sameSite(_ cookie: HTTPCookie) -> String? {
    switch cookie.sameSitePolicy {
    case .some(.sameSiteStrict): "Strict"
    case .some(.sameSiteLax): "Lax"
    default: nil
    }
  }

  func cookies(profile: String, urls: [URL], completion: @escaping ([HTTPCookie]) -> Void) {
    guard !urls.isEmpty else { return completion([]) }
    stores.dataStore(for: profile).httpCookieStore.getAllCookies { all in
      completion(all.filter { cookie in urls.contains { Self.sends(cookie, to: $0) } })
    }
  }

  func engineCookies(profile: String, urls: [URL], completion: @escaping ([[String: Any]]?) -> Void) {
    cookies(profile: profile, urls: urls) { found in
      completion(found.map { cookie in
        var entry: [String: Any] = [
          "name": cookie.name, "value": cookie.value, "domain": cookie.domain, "path": cookie.path,
          "expires": cookie.expiresDate?.timeIntervalSince1970 ?? -1, "session": cookie.isSessionOnly,
          "httpOnly": cookie.isHTTPOnly, "secure": cookie.isSecure,
        ]
        entry["sameSite"] = Self.sameSite(cookie) ?? "None"
        return entry
      })
    }
  }

  func exportCookies(profile: String, urls: [URL], completion: @escaping (Int) -> Void) {
    guard !WebKitStores.isPrivate(profile) else { return completion(0) }
    cookies(profile: profile, urls: urls) { found in
      let wire: [[String: Any]] = found.prefix(500).map { cookie in
        var entry: [String: Any] = [
          "name": cookie.name, "value": cookie.value, "domain": cookie.domain, "path": cookie.path,
          "secure": cookie.isSecure, "httpOnly": cookie.isHTTPOnly, "sameSite": Self.sameSite(cookie)?.lowercased() ?? "none",
          "sourceScheme": cookie.isSecure ? "secure" : "nonSecure",
        ]
        if !cookie.isSessionOnly, let expires = cookie.expiresDate { entry["expires"] = expires.timeIntervalSince1970 * 1000 }
        return entry
      }
      guard !wire.isEmpty, var json = try? JSONSerialization.data(withJSONObject: ["cookies": wire]) else { return completion(0) }
      json.append(0)
      let secret = NSMutableData(data: json)
      json.resetBytes(in: 0..<json.count)
      ArdiaEngineBridge.callWithSecret("ac_cookies_import", profile: profile, args: secret) { reply in
        let parsed = (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any]
        DispatchQueue.main.async { completion((parsed?["imported"] as? NSNumber)?.intValue ?? 0) }
      }
    }
  }
}
