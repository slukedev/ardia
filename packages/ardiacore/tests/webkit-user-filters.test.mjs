import { test } from "node:test";
import { runSwiftTests } from "./swift-testing.mjs";

const flags = ["-enable-bare-slash-regex"];

test("user filters parse without overflowing a background thread's stack", (t) => {
  runSwiftTests(t, "user-filters", ["../ios/WebKitContentBlockerUserFilters.swift", "./webkit-user-filters.test.swift"], { flags });
});

test("rule lists keep exclusion groups away from the rules they could undo, and the search finds the filters that don't compile", (t) => {
  runSwiftTests(
    t,
    "rule-packer",
    ["../ios/WebKitRulePacker.swift", "../ios/WebKitContentBlockerUserFilters.swift", "./webkit-rule-packer.test.swift"],
    { flags },
  );
});
