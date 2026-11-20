import { test } from "node:test";
import { runSwiftTests } from "./swift-testing.mjs";

test("page dialogs wait their turn, answer once, stay a sane size, and download names stay honest (Swift Testing)", (t) => {
  runSwiftTests(t, "page-dialogs-test", ["../ios/WebKitPageDialogs.swift", "../ios/WebKitDownloadNames.swift", "./webkit-page-dialogs.test.swift"]);
});

test("certificate exceptions and HSTS follow Chromium's rules (Swift Testing)", (t) => {
  runSwiftTests(t, "certificate-policy-test", ["../ios/WebKitCertificatePolicy.swift", "./webkit-certificate-policy.test.swift"]);
});
