import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const read = (name) => readFileSync(new URL(`../ios/${name}`, import.meta.url), "utf8");
const method = (source, signature) => {
  const start = source.indexOf(signature);
  assert.notEqual(start, -1, signature);
  const body = source.indexOf("{", start);
  let depth = 1, end = body + 1;
  for (; depth && end < source.length; end++) depth += Number(source[end] === "{") - Number(source[end] === "}");
  assert.equal(depth, 0, signature);
  return source.slice(start, end);
};
const run = (compiler, args, source, extension) => {
  const dir = mkdtempSync(join(tmpdir(), "ardia-clear-data-"));
  try {
    const file = join(dir, `main.${extension}`), binary = join(dir, "test");
    writeFileSync(file, source);
    const built = spawnSync(compiler, [...args, file, "-o", binary], { encoding: "utf8", timeout: 60_000 });
    assert.equal(built.status, 0, built.stderr || String(built.error));
    const result = spawnSync(binary, [], { encoding: "utf8", timeout: 10_000 });
    assert.equal(result.status, 0, result.stdout + result.stderr);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
};

test("the production service accepts only boolean true and preserves engine errors", { skip: process.platform !== "darwin" && "requires macOS Foundation" }, () => {
  const service = method(read("ArdiaServices.mm"), "+ (void)clearBrowsingData:");
  run("xcrun", ["clang++", "-std=c++20", "-fobjc-arc", "-fblocks", "-framework", "Foundation"], `
#import <Foundation/Foundation.h>
#include <cassert>
static NSDictionary *answer;
static int calls = 0;
static int pictures = 0;
@interface ArdiaEarlyWindow : NSObject
+ (void)forgetPictures;
@end
@implementation ArdiaEarlyWindow
+ (void)forgetPictures { pictures++; }
@end
@interface ArdiaServices : NSObject
+ (void)call:(NSString *)name profile:(NSString *)profile args:(NSDictionary *)args completion:(void (^)(NSDictionary *))completion;
@end
@implementation ArdiaServices
+ (void)call:(NSString *)name profile:(NSString *)profile args:(NSDictionary *)args completion:(void (^)(NSDictionary *))completion {
  assert([name isEqualToString:@"ac_browsing_data_clear"]);
  assert([profile isEqualToString:@"unloaded-profile"]);
  assert(([args[@"types"] isEqual:@[@"history", @"cache"]]));
  assert([args[@"since"] doubleValue] == 1234567);
  calls++;
  completion(answer);
}
${service}
@end
int main() {
  @autoreleasepool {
    NSArray *answers = @[@{@"ok": @YES}, @{@"ok": @NO}, @{}, @{@"ok": @1}, @{@"ok": @"true"}, @{@"ok": NSNull.null}, @{@"error": @"engine refused", @"ok": @YES}];
    for (NSUInteger i = 0; i < answers.count; i++) {
      answer = answers[i];
      __block int replies = 0;
      [ArdiaServices clearBrowsingData:@"unloaded-profile" types:@[@"history", @"cache"] since:1234567 completion:^(NSString *error) {
        replies++;
        assert((error == nil) == (i == 0));
        if (i == answers.count - 1) assert([error isEqualToString:@"engine refused"]);
      }];
      assert(replies == 1);
    }
    assert(calls == answers.count && pictures == answers.count);
  }
}
`, "mm");
});

test("the production engine aggregate waits for both engines and rejects the module call on failure", (t) => {
  const compiler = process.env.SWIFTC || "swiftc";
  const probe = spawnSync(compiler, ["--version"], { encoding: "utf8" });
  if (probe.error || probe.status !== 0) return t.skip("swiftc is not available");
  const source = read("PageEngine.swift");
  const chromium = method(source.slice(source.indexOf("struct ChromiumPageEngine")), "func clearBrowsingData(");
  const webKit = method(source.slice(source.indexOf("struct WebKitPageEngine")), "func clearBrowsingData(");
  const aggregate = method(source, "static func clearBrowsingData(");
  const handler = method(read("ProfilesModule.swift"), '"clearBrowsingData":').replace(/^"clearBrowsingData": /, "");
  const service = method(read("EngineCall.swift"), "func service(");
  run(compiler, ["-swift-version", "5"], `
import Foundation
var chromiumDone: ((String?) -> Void)?
var webKitDone: (() -> Void)?
var requests: [(String, [String], Double)] = []
var replies: [String] = []
protocol PageEngine {
  func clearBrowsingData(profile: String, types: [String], since: Double, done: @escaping (String?) -> Void)
}
enum ArdiaServices {
  static func clearBrowsingData(profile: String, types: [String], since: Double, completion: @escaping (String?) -> Void) {
    requests.append((profile, types, since)); chromiumDone = completion
  }
}
class WebKitHub {
  static let shared = WebKitHub()
  func clearBrowsingData(profile: String, types: [String], since: Double, completion: @escaping () -> Void) {
    requests.append((profile, types, since)); webKitDone = completion
  }
}
struct ChromiumPageEngine: PageEngine { ${chromium} }
struct WebKitPageEngine: PageEngine {
  var hub: WebKitHub { WebKitHub.shared }
  static func hasData(_ profile: String) -> Bool { true }
  ${webKit}
}
enum PageEngines {
  static let all: [PageEngine] = [WebKitPageEngine(), ChromiumPageEngine()]
  ${aggregate}
}
struct Args {
  let profile = "requested-profile"
  func strings(_ key: String) throws -> [String] { precondition(key == "types"); return ["history", "siteData"] }
  func optionalDouble(_ key: String) throws -> Double? { precondition(key == "since"); return 1234567 }
}
struct Reply {
  func ok(_ value: Any?) { precondition(value == nil); replies.append("ok") }
  func fail(_ code: String, _ error: String) { replies.append(code + ":" + error) }
  ${service}
}
let handler: (Args, Reply) throws -> Void = ${handler}
func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
let errors: [String?] = [nil, "failed to clear"]
for chromiumFirst in [true, false] {
  for error in errors {
    requests = []; replies = []
    try handler(Args(), Reply())
    precondition(requests.count == 2)
    for request in requests { precondition(request.0 == "requested-profile" && request.1 == ["history", "siteData"] && request.2 == 1234567) }
    if chromiumFirst { chromiumDone?(error) } else { webKitDone?() }
    drain()
    precondition(replies.isEmpty)
    if chromiumFirst { webKitDone?() } else { chromiumDone?(error) }
    drain()
    precondition(replies == [error.map { "ERR_ENGINE:" + $0 } ?? "ok"])
  }
}
`, "swift");
});
