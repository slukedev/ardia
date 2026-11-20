import Foundation
import Testing

enum WebKitContentBlocker {
  static func inflate(_ url: URL) -> Data? { nil }
}

@main struct HSTSPreloadTestRunner {
  static func main() async {
    await Testing.__swiftPMEntryPoint() as Never
  }
}

struct PreloadedHSTSTests {
  let lists: WebKitPreloadedHSTS.Lists

  init() throws {
    let directory = try #require(ProcessInfo.processInfo.environment["HSTS_HOSTS_DIR"])
    lists = try #require(WebKitPreloadedHSTS.Lists(directory: URL(fileURLWithPath: directory, isDirectory: true)))
  }

  @Test(arguments: ["google.com", "GOOGLE.com", "accounts.google.com", "a.b.google.com", "google.com.", "example.dev", "aa.example", "a-b.example"])
  func `listed hosts and their subdomains require HTTPS`(host: String) {
    #expect(lists.requiresHTTPS(host))
  }

  @Test func `an exact entry covers only itself`() {
    #expect(lists.requiresHTTPS("exact-only.example"))
    #expect(!lists.requiresHTTPS("www.exact-only.example"))
  }

  @Test(arguments: ["pins-only.example", "notgoogle.com", "google.co", "oogle.com", "example.com", "test-only.test", "", "8.8.8.8", "[::1]", "a.example", "b.example"])
  func `everything else is left alone`(host: String) {
    #expect(!lists.requiresHTTPS(host))
  }

  @Test func `a missing resource requires nothing`() {
    #expect(WebKitPreloadedHSTS.Lists(directory: URL(fileURLWithPath: "/nonexistent-hsts")) == nil)
    #expect(!WebKitPreloadedHSTS.Lists.empty.requiresHTTPS("google.com"))
  }
}
