import Foundation

enum WebKitPreloadedHSTS {
  struct Lists: Sendable {
    let subdomains: WebKitHostList
    let exact: WebKitHostList

    static let empty = Lists(subdomains: WebKitHostList(Data()), exact: WebKitHostList(Data()))

    init(subdomains: WebKitHostList, exact: WebKitHostList) {
      self.subdomains = subdomains
      self.exact = exact
    }

    init?(directory: URL) {
      guard let subdomains = Self.hosts(directory.appendingPathComponent("subdomains.hosts")),
        let exact = Self.hosts(directory.appendingPathComponent("exact.hosts"))
      else { return nil }
      self.init(subdomains: subdomains, exact: exact)
    }

    private static func hosts(_ url: URL) -> WebKitHostList? {
      guard let data = try? Data(contentsOf: url), let raw = try? (data as NSData).decompressed(using: .zlib) else { return nil }
      return WebKitHostList(raw as Data)
    }

    func requiresHTTPS(_ host: String) -> Bool {
      let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
      guard !name.isEmpty, !WebKitPreloadedHSTS.isIPAddress(name) else { return false }
      var rest = Substring(name)
      if exact.contains(rest.utf8) { return true }
      while true {
        if subdomains.contains(rest.utf8) { return true }
        guard let dot = rest.firstIndex(of: ".") else { return false }
        rest = rest[rest.index(after: dot)...]
      }
    }
  }

  private static let lists: Lists = {
    guard let directory = Bundle.main.resourceURL?.appendingPathComponent("HSTS"), let loaded = Lists(directory: directory) else {
      NSLog("[webkit] the HSTS preload list isn't in the app bundle, so only hosts seen this session require HTTPS")
      return .empty
    }
    return loaded
  }()

  static func requiresHTTPS(_ host: String) -> Bool { lists.requiresHTTPS(host) }

  static func warm() {
    DispatchQueue.global(qos: .utility).async { _ = lists }
  }

  static func isIPAddress(_ host: String) -> Bool {
    var v4 = in_addr(), v6 = in6_addr()
    let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    return inet_pton(AF_INET, bare, &v4) == 1 || inet_pton(AF_INET6, bare, &v6) == 1
  }
}
