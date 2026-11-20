import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { runSwiftTests } from "./swift-testing.mjs";
import { runInNewContext } from "node:vm";
import { webKitPageScript } from "./webkit-page-source.mjs";

const path = (name) => fileURLToPath(new URL(name, import.meta.url));
const sources = [
  "../ios/WebKitTab.swift",
  "../ios/WebKitTab+AutoPictureInPicture.swift",
  "../ios/WebKitTab+PageTab.swift",
  "../ios/WebKitWebView.swift",
  "../ios/WebKitAutoPictureInPicture.swift",
  "../ios/ArdiaChromeWindowHost.h",
  "../ios/ArdiaChromeWindowHost.mm",
  "./webkit-auto-pip.test.swift",
];
const read = (name) => (existsSync(path(name)) ? readFileSync(path(name), "utf8") : "");
const tab = read("../ios/WebKitTab.swift");
const sight = read("../ios/WebKitTab+AutoPictureInPicture.swift");
const pageTab = read("../ios/WebKitTab+PageTab.swift");
const webView = read("../ios/WebKitWebView.swift");
const windowHostHeader = read("../ios/ArdiaChromeWindowHost.h");
const windowHost = read("../ios/ArdiaChromeWindowHost.mm");

function pageWithVideos(videos) {
  const noop = () => {};
  const document = {
    readyState: "complete",
    addEventListener: noop,
    removeEventListener: noop,
    querySelectorAll: (selector) => (selector === "video" ? videos.slice() : []),
    dispatchEvent: () => true,
    pictureInPictureElement: null,
    body: null,
    documentElement: {},
  };
  const window = { document, addEventListener: noop, location: { protocol: "https:", origin: "https://example.test" }, navigator: {}, performance: { now: () => 0 }, setTimeout: noop, requestAnimationFrame: noop, EventTarget: class { addEventListener() {} } };
  window.window = window;
  window.top = window;
  runInNewContext(webKitPageScript.replace("\\#(WebKitMediaFaults.sitesJSON)", "[]"), window);
  return window.__ardia;
}

function video(name, { paused, ended = false, width = 640, height = 360 }) {
  const v = { name, paused, ended, clientWidth: width, clientHeight: height, webkitPresentationMode: "inline", entered: false };
  v.webkitSupportsPresentationMode = (mode) => mode === "picture-in-picture";
  v.webkitSetPresentationMode = (mode) => {
    v.webkitPresentationMode = mode;
    v.entered = mode === "picture-in-picture";
  };
  return v;
}

test("every source the checks read exists", () => {
  const missing = sources.filter((name) => !existsSync(path(name)));
  assert.deepEqual(missing, []);
});

test("WebKit tabs keep the autoPictureInPicture flag instead of a stub that reads false", () => {
  assert.doesNotMatch(pageTab, /var autoPictureInPicture\b[^\n]*get \{ false \}/);
  assert.match(tab, /^ {2}var autoPictureInPicture = false \{ didSet \{ autoPictureInPictureInputsChanged\(\) \} \}$/m);
});

test("WebKit tabs follow the user's sight of their window the way Chromium views do", () => {
  assert.match(sight, /return visible && ArdiaChromeWindowHost\.userSees\(window\)/);
  assert.match(sight, /forName: (?:NSNotification\.Name\.)?ArdiaWindowSeenDidChange, object: window/);
  assert.match(sight, /return !playingFrames\.isEmpty \|\| view\.cameraCaptureState == \.active \|\| view\.microphoneCaptureState == \.active/);
  assert.match(sight, /playing: playsMedia\)/);
  const movedStart = tab.indexOf("override func viewDidMoveToWindow() {");
  assert.ok(movedStart >= 0, "viewDidMoveToWindow not found");
  const moved = tab.slice(movedStart, tab.indexOf("\n  }\n", movedStart));
  assert.match(moved, /^ {4}super\.viewDidMoveToWindow\(\)$/m);
  assert.match(moved, /^ {4}if window != nil \{ followInterfaceScale\(\) \}$/m);
  assert.match(moved, /^ {4}watchSight\(\)$/m);
  assert.match(tab, /^ {2}var visible = true \{ didSet \{[^\n]*\bupdateSight\(\)[^\n]*\} \}$/m);
  assert.match(tab, /^ {2}var visible = true \{ didSet \{[^\n]*\bnoteShownChanged\(\)[^\n]*\} \}$/m);
});

test("WebKit tabs report why automatic picture in picture held back, as Chromium views do", () => {
  assert.match(sight, /let kept = seen && ArdiaChromeWindowHost\.userSeesOnlyThroughWindowServer\(window\)/);
  assert.match(sight, /emit\("autoPictureInPictureKept", ArdiaConsentStamp\.begin\(\)\.onto\(\["appSwitch": false\]\)\)/);
  assert.match(sight, /note\.userInfo\?\[Self\.leftAppKey\] as\? Bool\) == true \{ self\?\.noteStayedOnAppSwitch\(\) \}/);
  assert.match(sight, /emit\("autoPictureInPictureKept", ArdiaConsentStamp\.begin\(\)\.onto\(\["appSwitch": true\]\)\)/);
  assert.match(sight, /ArdiaChromeWindowHost\.playsForAutoPictureInPictureHandler = \{ window in/);
  assert.match(windowHostHeader, /\+ \(BOOL\)userSeesOnlyThroughWindowServer:\(nullable NSWindow \*\)window NS_SWIFT_NAME\(userSeesOnlyThroughWindowServer\(_:\)\);/);
  assert.match(read("../ios/ArdiaWebView+PictureInPicture.mm"), /BOOL \(\^webKitPlays\)\(NSWindow \*\) = ArdiaChromeWindowHost\.playsForAutoPictureInPictureHandler;\n\s+return webKitPlays && webKitPlays\(window\);/);
});

test("leaving opens picture in picture and returning closes it through the page's own player call", () => {
  assert.match(sight, /case \.open:\s*let stamp = ArdiaConsentStamp\.begin\(\)\s*setPictureInPicture\(true, automatic: true\) \{ \[weak self\] answer in if answer == \.nothingPlaying \{ self\?\.emit\("autoPictureInPictureKept", stamp\.onto\(\["reason": "nothingPlaying"\]\)\) \} \}/);
  assert.match(sight, /case \.close: setPictureInPicture\(false\) \{ _ in \}/);
  assert.match(sight, /autoPictureInPictureRule\.sight\(seen, enabled: autoPictureInPicture, playing: playsMedia\)/);
});

test("the page's picture in picture reports reach the rule", () => {
  assert.match(tab, /case "pip":\n\s+let active = dict\?\["active"\] as\? Bool \?\? false\n\s+autoPictureInPictureRule\.reported\(active: active\)/);
});

test("the sight observer is dropped when the window changes or the tab closes or gives its view away", () => {
  assert.match(tab, /private\(set\) var closed = false \{ didSet \{ if closed \{ stopWatchingSight\(\) \} \} \}/);
  assert.match(sight, /func watchSight\(\) \{\n\s+stopWatchingSight\(\)/);
  const relinquish = tab.slice(tab.indexOf("func relinquish() -> WebKitWebView? {"), tab.indexOf("\n  }\n", tab.indexOf("func relinquish() -> WebKitWebView? {")));
  assert.match(relinquish, /closed = true/);
});

test("the rule travels with the page view, so a tab that takes the view over still closes the picture in picture its predecessor opened", () => {
  assert.match(webView, /^ {2}var autoPictureInPictureRule = WebKitAutoPictureInPicture\(\)$/m);
  assert.doesNotMatch(tab, /var autoPictureInPictureRule = WebKitAutoPictureInPicture\(\)/);
  assert.match(
    sight,
    /var autoPictureInPictureRule: WebKitAutoPictureInPicture \{\n\s+get \{ webView\?\.autoPictureInPictureRule \?\? WebKitAutoPictureInPicture\(\) \}\n\s+set \{ webView\?\.autoPictureInPictureRule = newValue \}\n\s+\}/,
  );
  const attach = tab.slice(tab.indexOf("func attach(_ view: WebKitWebView) {"), tab.indexOf("private func observe("));
  assert.match(attach, /webView = view\n[\s\S]*\n {4}updateSight\(\)\n {4}pushFieldProvider\(\)\n {2}\}/);
});

test("ArdiaCore's public window host gives Swift the same sight rule as Chromium views", () => {
  assert.match(windowHostHeader, /\+ \(BOOL\)userSeesWindow:\(nullable NSWindow \*\)window NS_SWIFT_NAME\(userSees\(_:\)\);/);
  assert.match(windowHostHeader, /extern NSNotificationName const ArdiaWindowSeenDidChange;/);
  assert.match(windowHost, /\+ \(BOOL\)userSeesWindow:\(NSWindow \*\)window \{\n\s+return \[ArdiaWindowController userSees:window\];/);
});

test("the leave and return rule opens once per leave and closes on return (Swift Testing)", (t) => {
  runSwiftTests(t, "auto-pip-test", ["../ios/WebKitAutoPictureInPicture.swift", "./webkit-auto-pip.test.swift"]);
});

test("automatic picture in picture leaves a paused video where it is", () => {
  const paused = video("paused", { paused: true });
  const ardia = pageWithVideos([paused]);
  assert.equal(ardia.pictureInPicture(true, true), "nothingPlaying");
  assert.equal(paused.entered, false);
  assert.equal(pageWithVideos([]).pictureInPicture(true, true), "nothingPlaying");
});

test("a playing video the page can't pop out is a failure, not nothing playing", () => {
  const stuck = { ...video("stuck", { paused: false }), webkitSupportsPresentationMode: undefined, webkitSetPresentationMode: undefined };
  assert.equal(pageWithVideos([stuck]).pictureInPicture(true, true), false);
  assert.equal(pageWithVideos([video("paused", { paused: true })]).pictureInPicture(true), true);
  assert.equal(pageWithVideos([]).pictureInPicture(true), false);
});

test("automatic picture in picture takes the playing video, not the largest", () => {
  const big = video("big", { paused: true, width: 1280, height: 720 });
  const small = video("small", { paused: false });
  const done = video("done", { paused: false, ended: true, width: 1920, height: 1080 });
  const ardia = pageWithVideos([big, done, small]);
  assert.equal(ardia.pictureInPicture(true, true), true);
  assert.deepEqual([big.entered, done.entered, small.entered], [false, false, true]);
});

test("a picture in picture the user asks for still takes the largest video when none plays", () => {
  const small = video("small", { paused: true });
  const big = video("big", { paused: true, width: 1280, height: 720 });
  const ardia = pageWithVideos([small, big]);
  assert.equal(ardia.pictureInPicture(true), true);
  assert.deepEqual([small.entered, big.entered], [false, true]);
});

test("the tab asks the page for an automatic picture in picture and a manual request stays manual", () => {
  assert.match(tab, /func setPictureInPicture\(_ on: Bool, automatic: Bool = false, completion: @escaping \(PictureInPictureAnswer\) -> Void\)/);
  assert.match(tab, /completion\(value as\? String == "nothingPlaying" \? \.nothingPlaying : \(value as\? NSNumber\)\?\.boolValue == true \? \.opened : \.failed\)/);
  assert.match(tab, /window\.__ardia\.pictureInPicture\(\\\(on \? "true" : "false"\), \\\(automatic \? "true" : "false"\)\)/);
  assert.match(pageTab, /setPictureInPicture\(true\) \{ completion\(\$0 == \.opened\) \}/);
});
