import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const path = (name) => fileURLToPath(new URL(name, import.meta.url));
const swiftc = process.env.SWIFTC || "swiftc";
const CHILD_TIMEOUT_MS = 180_000;
const runChild = (command, args) => {
  const result = spawnSync(command, args, { encoding: "utf8", timeout: CHILD_TIMEOUT_MS, killSignal: "SIGKILL" });
  assert.ok(!result.error, `${command} failed to finish within ${CHILD_TIMEOUT_MS / 1000} s: ${result.error?.message}`);
  return result;
};
const webView = readFileSync(path("../ios/WebKitWebView.swift"), "utf8");
const tab = readFileSync(path("../ios/WebKitTab.swift"), "utf8");
const pageInput = readFileSync(path("../ios/WebKitTab+PageInput.swift"), "utf8");

test("the WebKit page view puts every mouse button event through the press gate", () => {
  for (const button of ["mouse", "rightMouse", "otherMouse"]) {
    for (const phase of ["Down", "Dragged", "Up"]) {
      const name = `${button}${phase}`;
      assert.match(webView, new RegExp(`override func ${name}\\(with event: NSEvent\\) \\{ if admits\\(event\\) \\{ super\\.${name}\\(with: event\\) \\} \\}`), name);
    }
  }
  assert.match(webView, /presses\.verdict\(for: event, on: self\)/);
  assert.match(webView, /case \.refuse:\n\s+onPressRefused\?\(\)\n\s+return false/);
  assert.equal(tab.match(/^ {4}listen\(to: view\)$/gm)?.length, 1);
  assert.equal(tab.match(/^ {4}stopListening\(to: view\)$/gm)?.length, 3);
  assert.match(pageInput, /view\.onPressRefused = \{ \[weak self\] in self\?\.pagePressRefused\(\) \}/);
  assert.match(pageInput, /private func pagePressRefused\(\) \{ emit\("pagePress", \["refused": true\]\) \}/);
});

test("a click on something drawn over a WebKit page stays off the page", (t) => {
  const probe = spawnSync(swiftc, ["--version"], { encoding: "utf8", timeout: CHILD_TIMEOUT_MS });
  if (probe.error || probe.status !== 0) return t.skip("swiftc is not available");
  const dir = mkdtempSync(join(tmpdir(), "ardia-page-presses-"));
  try {
    const binary = join(dir, "page-presses-test");
    const built = runChild(swiftc, ["-parse-as-library", path("../ios/WebKitPagePresses.swift"), path("./webkit-page-presses.test.swift"), "-o", binary]);
    assert.equal(built.status, 0, built.stderr);
    const ran = runChild(binary, []);
    assert.equal(ran.status, 0, ran.stdout + ran.stderr);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
