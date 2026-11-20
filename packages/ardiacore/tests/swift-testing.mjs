import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const path = (name) => fileURLToPath(new URL(name, import.meta.url));

export function swiftTesting() {
  const platform = spawnSync("xcrun", ["--show-sdk-platform-path"], { encoding: "utf8" });
  const selected = spawnSync("xcode-select", ["-p"], { encoding: "utf8" });
  if (platform.status !== 0 || selected.status !== 0) return { missing: "Xcode isn't available" };
  const frameworks = join(platform.stdout.trim(), "Developer/Library/Frameworks");
  const libraries = join(platform.stdout.trim(), "Developer/usr/lib");
  const plugins = join(selected.stdout.trim(), "Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing");
  if (!existsSync(join(frameworks, "Testing.framework")) || !existsSync(plugins)) return { missing: "Swift Testing isn't available" };
  return { frameworks, libraries, plugins };
}

export function runSwiftTests(t, name, sources, { env = {}, flags = [] } = {}) {
  const kit = swiftTesting();
  if (kit.missing) return t.skip(kit.missing);
  const dir = mkdtempSync(join(tmpdir(), `ardia-${name}-`));
  try {
    const binary = join(dir, name);
    const built = spawnSync(
      "xcrun",
      [
        "swiftc", "-parse-as-library", ...flags, "-F", kit.frameworks, "-plugin-path", kit.plugins,
        "-Xlinker", "-rpath", "-Xlinker", kit.frameworks, "-Xlinker", "-rpath", "-Xlinker", kit.libraries,
        ...sources.map(path), path("./swift-testing-main.swift"), "-o", binary,
      ],
      { encoding: "utf8" },
    );
    assert.equal(built.status, 0, built.stderr);
    const ran = spawnSync(binary, [], { encoding: "utf8", env: { ...process.env, ...env } });
    assert.equal(ran.status, 0, ran.stdout + ran.stderr);
    return ran.stdout + ran.stderr;
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}
