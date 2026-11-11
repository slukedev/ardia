import assert from "node:assert/strict";
import { test } from "node:test";
const native = await import("../../test-native/index.ts");
const store = await import("./store.ts");
const source = await import("./googleSource.ts");

const caps = { totp: false, save: true, selfHosted: false, masterPassword: false, touchID: true };
const googleState = (state, over = {}) => ({ id: "google", name: "Google Password Manager", state, capabilities: caps, install: { command: "", url: "" }, setup: { kind: "chrome" }, ...over });

test("the status line names Chrome when it is the source, and says when Ardia fell back to the web", () => {
  const now = new Date(2026, 10, 10, 15, 0).getTime();
  const account = "me@gmail.com";
  assert.equal(source.googleStatusLine(googleState("unlocked", { account, source: "chrome", refreshedAt: now - 30_000 }), now), "me@gmail.com · Google Chrome");
  assert.equal(source.googleStatusLine(googleState("unlocked", { account, source: "web", refreshedAt: now - 30_000 }), now), "me@gmail.com · Updated just now");
  assert.equal(
    source.googleStatusLine(googleState("unlocked", { account, source: "web", fallback: "Chrome's keychain access was denied.", refreshedAt: now - 30_000 }), now),
    "me@gmail.com · Couldn't read Chrome · Updated just now",
  );
  assert.equal(source.googleStatusLine(googleState("unlocked", { account, source: "web", fallback: "x", hold: "twoStep" }), now), "me@gmail.com · Couldn't read Chrome · Google needs you to confirm");
  assert.equal(source.googleStatusLine(googleState("locked", { account, source: "chrome" }), now), "me@gmail.com · Locked");
});

test("the source menu checks the current choice and shows why Chrome isn't used", () => {
  const plain = source.googleSourceMenu({});
  assert.deepEqual(plain.children.map((c) => [c.id, c.checked]), [["source.automatic", true], ["source.chrome", false], ["source.web", false]]);
  const fell = source.googleSourceMenu({ sourceChoice: "web", fallback: "Chrome isn't signed in to Google." });
  assert.equal(fell.children.find((c) => c.checked)?.id, "source.web");
  assert.deepEqual(fell.children.at(-1), { id: "source.why", title: "Chrome isn't signed in to Google.", enabled: false });
  assert.equal(source.sourceChoiceOf("source.chrome"), "chrome");
  assert.equal(source.sourceChoiceOf("source.why"), null);
  assert.equal(source.sourceChoiceOf("lock"), null);
});

test("switching the source unlocks again only when the old session can't serve it", async () => {
  native.vaultFakes.unlocks.length = 0;
  native.vaultFakes.providers = [googleState("unlocked", { account: "a@gmail.com", sourceChoice: "automatic" })];
  store.applyProviderState(native.vaultFakes.providers[0]);
  await source.chooseGoogleSource(store.vaultProviderOf("google"), "automatic");
  assert.equal(native.vaultFakes.unlocks.length, 0);
  await source.chooseGoogleSource(store.vaultProviderOf("google"), "web");
  assert.deepEqual(native.vaultFakes.unlocks, [{ provider: "google", withPassword: false }]);
  assert.equal(store.vaultProviderOf("google").sourceChoice, "web");
});
