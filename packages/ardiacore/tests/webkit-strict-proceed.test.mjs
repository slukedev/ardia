import test from "node:test";
import { runSwiftTests } from "./swift-testing.mjs";

test("Proceed on a strict-block page ends the error page through a new load", (t) => {
  runSwiftTests(t, "strict-proceed-test", ["../ios/WebKitStrictProceed.swift", "./webkit-strict-proceed.test.swift"]);
});
