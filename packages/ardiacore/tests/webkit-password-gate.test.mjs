import test from "node:test";
import { runSwiftTests } from "./swift-testing.mjs";

test("WebKit password save and fill follow the profile's password manager choice", (t) => {
  runSwiftTests(t, "password-gate-test", ["../ios/WebKitPasswordGate.swift", "./webkit-password-gate.test.swift"]);
});
