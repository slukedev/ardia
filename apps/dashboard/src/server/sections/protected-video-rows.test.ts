import { test } from "node:test";
import assert from "node:assert/strict";
import { protectedVideoRows } from "./protected-video-rows.ts";

const counts = { attempts: 0, successes: 0, failures: 0, refusals: 0, access: 0, createKeys: 0, licence: 0, keystatus: 0 };

test("versions with no Widevine activity drop out, refusals without a stage are kept apart, and rates stay empty without data", () => {
  const rows = protectedVideoRows(
    [
      { ...counts, version: "", people: 9, attempts: 4, successes: 3, failures: 1, refusals: 7, licence: 3, keystatus: 1, access: 1 },
      { ...counts, version: "0.2.47-nightly.2", people: 5, attempts: 4, successes: 3, failures: 1, refusals: 2, licence: 2 },
      { ...counts, version: "0.2.47", people: 3, refusals: 5, licence: 1, keystatus: 1, access: 1 },
      { ...counts, version: "0.2.46", people: 6 },
    ],
    { installed: 3, reported: 4 },
  );
  assert.equal(rows.cdmShare, 0.75);
  assert.equal(rows.total?.successRate, 0.75);
  assert.equal(rows.total?.unstaged, 2);
  assert.deepEqual(
    rows.versions.map((r) => [r.version, r.nightly, r.successRate, r.unstaged]),
    [
      ["0.2.47", false, null, 2],
      ["0.2.47-nightly.2", true, 0.75, 0],
    ],
  );
  assert.equal(protectedVideoRows([], { installed: 0, reported: 0 }).cdmShare, null);
});
