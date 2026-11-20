import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { inflateRawSync } from "node:zlib";

const path = (name) => fileURLToPath(new URL(name, import.meta.url));
const fixture = path("./fixtures/hsts-preload/transport_security_state_static.json");

const convert = () => {
  const dir = mkdtempSync(join(tmpdir(), "ardia-hsts-preload-"));
  const ran = spawnSync("python3", ["-I", path("../scripts/hsts-preload.py"), fixture, dir], { encoding: "utf8" });
  assert.equal(ran.status, 0, ran.stderr);
  return { dir, stdout: ran.stdout };
};

const hosts = (dir, name) => inflateRawSync(readFileSync(join(dir, name))).toString("utf8").split("\n");

test("the converter keeps force-https entries, split by include_subdomains, byte-sorted and lowercase", () => {
  const { dir, stdout } = convert();
  try {
    assert.deepEqual(hosts(dir, "subdomains.hosts"), ["a-b.example", "aa.example", "dev", "google.com"]);
    assert.deepEqual(hosts(dir, "exact.hosts"), ["exact-only.example"]);
    assert.match(stdout, /4 with subdomains, 1 exact/);
    assert.match(stdout, /"non-ascii": 1, "not-https": 1, "test": 1/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("the WebKit lookup honours subdomains and exact entries (Swift Testing)", (t) => {
  const developer = spawnSync("xcrun", ["--show-sdk-platform-path"], { encoding: "utf8" });
  const selected = spawnSync("xcode-select", ["-p"], { encoding: "utf8" });
  if (developer.status !== 0 || selected.status !== 0) return t.skip("Xcode isn't available");
  const frameworks = join(developer.stdout.trim(), "Developer/Library/Frameworks");
  const libraries = join(developer.stdout.trim(), "Developer/usr/lib");
  const plugins = join(selected.stdout.trim(), "Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing");
  if (!existsSync(join(frameworks, "Testing.framework")) || !existsSync(plugins)) return t.skip("Swift Testing isn't available");
  const { dir } = convert();
  try {
    const binary = join(dir, "hsts-preload-test");
    const built = spawnSync(
      "xcrun",
      [
        "swiftc", "-parse-as-library", "-F", frameworks, "-plugin-path", plugins,
        "-Xlinker", "-rpath", "-Xlinker", frameworks, "-Xlinker", "-rpath", "-Xlinker", libraries,
        path("../ios/WebKitPreloadedHSTS.swift"), path("../ios/WebKitContentBlockerStrict.swift"), path("./hsts-preload.test.swift"),
        "-o", binary,
      ],
      { encoding: "utf8" },
    );
    assert.equal(built.status, 0, built.stderr);
    const ran = spawnSync(binary, [], { encoding: "utf8", env: { ...process.env, HSTS_HOSTS_DIR: dir } });
    assert.equal(ran.status, 0, ran.stdout + ran.stderr);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
