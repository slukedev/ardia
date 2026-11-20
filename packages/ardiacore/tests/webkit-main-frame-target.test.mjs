import test from "node:test";
import { runSwiftTests } from "./swift-testing.mjs";

test("the sign-in prompt's main-frame target never outlives a navigation that won't commit", (t) => {
  runSwiftTests(t, "main-frame-target-test", ["../ios/WebKitMainFrameTarget.swift", "./webkit-main-frame-target.test.swift"]);
});
