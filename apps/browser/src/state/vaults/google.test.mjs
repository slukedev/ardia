import assert from "node:assert/strict";
import { test } from "node:test";
const native = await import("../../test-native/index.ts");
const { useBrowser } = await import("../browser/store.ts");
const { webviews } = await import("../../platform/webviews.ts");
const { saveOutcome } = await import("../../platform/vaults.ts");
const { useToasts } = await import("../app/toasts.ts");
const store = await import("./store.ts");
const google = await import("./google.ts");
const googleImport = await import("./googleImport.ts");
const offers = await import("./saveOffer.ts");
const { menuRows } = await import("./menuModel.ts");

const S = () => useBrowser.getState();
const caps = { totp: false, save: true, selfHosted: false, masterPassword: false, touchID: true };
const googleState = (state, over = {}) => ({ id: "google", name: "Google Password Manager", state, capabilities: caps, install: { command: "", url: "https://www.google.com/chrome/" }, setup: { kind: "chrome" }, ...over });
const settle = () => new Promise((r) => setTimeout(r, 0));
const toastOf = (w) => useToasts.getState().toasts[w] ?? null;

test("the status line says whose passwords these are, when they were last read, or that Google needs you", () => {
  const now = new Date(2026, 10, 10, 15, 0).getTime();
  const account = "me@gmail.com";
  assert.equal(google.chromeStatusLine(googleState("notInstalled"), now), "Not connected");
  assert.equal(google.chromeStatusLine(googleState("signedOut"), now), "Not connected");
  assert.equal(google.chromeStatusLine(googleState("locked", { account }), now), "me@gmail.com · Locked");
  assert.equal(google.chromeStatusLine(googleState("locked", { account, message: "Ardia wasn't allowed to read Chrome's passwords." }), now), "Ardia wasn't allowed to read Chrome's passwords.");
  assert.equal(google.chromeStatusLine(googleState("unlocked", { account }), now), account);
  assert.equal(google.chromeStatusLine(googleState("unlocked", { account, refreshedAt: now - 30_000 }), now), "me@gmail.com · Updated just now");
  assert.match(google.chromeStatusLine(googleState("unlocked", { account, refreshedAt: new Date(2026, 10, 10, 9, 5).getTime() }), now), /^me@gmail\.com · Updated at 9:05\s?AM$/);
  assert.equal(google.chromeStatusLine(googleState("unlocked", { account, refreshedAt: new Date(2026, 10, 9, 23, 0).getTime() }), now), "me@gmail.com · Updated yesterday");
  assert.equal(google.chromeStatusLine(googleState("unlocked", { account, refreshedAt: new Date(2026, 10, 2, 12, 0).getTime() }), now), "me@gmail.com · Updated Nov 2");
  assert.equal(google.chromeStatusLine(googleState("unlocked", { account, refreshedAt: now - 30_000, hold: "twoStep" }), now), "me@gmail.com · Google needs you to confirm");
  assert.equal(google.chromeStatusLine(googleState("unavailable", { message: "Couldn't read Chrome's passwords." }), now), "Couldn't read Chrome's passwords.");
});

test("profile names only gain the email when two profiles share a name", () => {
  const options = google.chromeProfileOptions([
    { directory: "Default", name: "Person 1", email: "a@gmail.com" },
    { directory: "Profile 1", name: "Person 1", email: "b@gmail.com" },
    { directory: "Profile 2", name: "Work", email: null },
  ]);
  assert.deepEqual(options.map((o) => o.title), ["Person 1 (a@gmail.com)", "Person 1 (b@gmail.com)", "Work"]);
});

test("the chosen profile is the one native marks, then the server, then the account", () => {
  const profiles = [
    { directory: "Default", name: "Personal", email: "a@gmail.com" },
    { directory: "Profile 1", name: "Work", email: "b@gmail.com" },
  ];
  assert.equal(google.chosenChromeProfile([{ ...profiles[0] }, { ...profiles[1], selected: true }], { server: "Default" }), "Profile 1");
  assert.equal(google.chosenChromeProfile(profiles, { server: "Work" }), "Profile 1");
  assert.equal(google.chosenChromeProfile(profiles, { account: "a@gmail.com" }), "Default");
  assert.equal(google.chosenChromeProfile(profiles, {}), null);
});

test("the same login in two places is told apart by its vault, a unique one isn't", () => {
  const item = (id, username, vault) => ({ provider: "google", id, title: "github.com", username, urls: ["https://github.com"], vault, hasTotp: false });
  const rows = menuRows({
    field: "password",
    mode: "matches",
    origin: "https://github.com",
    query: "",
    providers: [googleState("unlocked")],
    items: [item("a", "octo", "Google Account"), item("b", "octo", "On This Mac"), item("c", "work", "Google Account")],
    pending: null,
    noTotp: new Set(),
  });
  const logins = rows.filter((r) => r.kind === "login").map((r) => [r.item.id, r.vault ?? null]);
  assert.deepEqual(logins.sort(), [["a", "Google Account"], ["b", "On This Mac"], ["c", null]]);
});

test("a save reply reads as saved, a confirm Google needs, or a failure with its action", () => {
  assert.deepEqual(saveOutcome({ saved: true }), { kind: "saved" });
  assert.deepEqual(saveOutcome({ saved: false, code: "confirm", importId: "i1", error: "Google wants a second step to confirm it's you." }), {
    kind: "confirm",
    importId: "i1",
    error: "Google wants a second step to confirm it's you.",
  });
  assert.deepEqual(saveOutcome({ saved: false, code: "wrongPassword", action: "updatePassword", error: "Google didn't accept the saved password." }), {
    kind: "failed",
    error: "Google didn't accept the saved password.",
    action: "updatePassword",
  });
  assert.deepEqual(saveOutcome({ saved: false, code: "confirm", error: "x" }), { kind: "failed", error: "x" });
  assert.deepEqual(saveOutcome({ saved: false, error: "failed" }), { kind: "failed", error: "" });
  assert.deepEqual(saveOutcome(null), { kind: "failed", error: "" });
});

test("profiles come from native and a missing call leaves the last list alone", async () => {
  native.vaultFakes.providers = [googleState("unlocked", { account: "a@gmail.com" })];
  native.vaultFakes.chromeProfiles = [{ directory: "Default", name: "Personal", email: "a@gmail.com", selected: true }];
  await store.loadVaultProviders();
  await google.loadChromeProfiles("google");
  assert.equal(google.useChromeProfiles.getState().google.length, 1);
});

async function savingTab(reply) {
  S().hydrate({});
  const w = S().createWindow({ url: "https://github.com/login" });
  const tabId = S().windows[w].tabIds[0];
  webviews.set(tabId, { saveToVault: async () => reply, discardVaultCapture: async () => {}, setVaultMenu: async () => {} });
  native.vaultFakes.providers = [googleState("unlocked", { account: "a@gmail.com" })];
  native.vaultFakes.items = [];
  store.clearVaultIndex();
  await store.loadVaultProviders();
  await offers.noteVaultSubmitted(tabId, { frameId: "f1", origin: "https://github.com", username: "octo" });
  return { w, tabId };
}

test("saving to Google closes the offer and says Saved to Google", async () => {
  const { w, tabId } = await savingTab({ saved: true, item: { provider: "google", id: "imported.x", title: "github.com", username: "octo", urls: ["https://github.com"], hasTotp: false } });
  assert.equal(offers.useVaultSaveOffers.getState()[tabId]?.target, "google");
  await offers.saveVaultOffer(tabId);
  assert.equal(offers.useVaultSaveOffers.getState()[tabId], null);
  assert.equal(toastOf(w)?.title, "Saved to Google");
});

test("when Google needs the person, the offer waits with Confirm, and the import's end closes it", async () => {
  const { w, tabId } = await savingTab({ saved: false, code: "confirm", importId: "imp1", reason: "twoStep", error: "Google wants a second step to confirm it's you." });
  await offers.saveVaultOffer(tabId);
  const offer = offers.useVaultSaveOffers.getState()[tabId];
  assert.equal(offer?.action, "confirm");
  assert.equal(offer?.error, "Google needs you to confirm");
  assert.equal(offer?.busy, true);
  native.vaultFakes.reveals.length = 0;
  offers.runVaultOfferAction(tabId);
  await settle();
  assert.deepEqual(native.vaultFakes.reveals, ["imp1"]);
  googleImport.applyGoogleImport({ provider: "google", id: "other", state: "saved", host: "github.com" });
  assert.ok(offers.useVaultSaveOffers.getState()[tabId]);
  googleImport.applyGoogleImport({ provider: "google", id: "imp1", state: "saved", host: "github.com" });
  assert.equal(offers.useVaultSaveOffers.getState()[tabId], null);
  assert.equal(toastOf(w)?.title, "Saved to Google");
});

test("a failed import after confirming puts its message back on the offer", async () => {
  const { tabId } = await savingTab({ saved: false, code: "confirm", importId: "imp2", error: "x" });
  await offers.saveVaultOffer(tabId);
  googleImport.applyGoogleImport({ provider: "google", id: "imp2", state: "failed", host: "github.com", code: "wrongPassword", message: "Google didn't accept the saved password." });
  const offer = offers.useVaultSaveOffers.getState()[tabId];
  assert.equal(offer?.busy, false);
  assert.equal(offer?.action, "updatePassword");
  assert.equal(offer?.error, "Google didn't accept the saved password.");
  offers.dismissVaultOffer(tabId);
});

test("a wrong stored password offers Update Password, which opens the Google password sheet", async () => {
  const { w, tabId } = await savingTab({ saved: false, code: "wrongPassword", action: "updatePassword", error: "Google didn't accept the saved password." });
  await offers.saveVaultOffer(tabId);
  const offer = offers.useVaultSaveOffers.getState()[tabId];
  assert.equal(offer?.action, "updatePassword");
  assert.equal(offer?.error, "Google didn't accept the saved password.");
  assert.equal(toastOf(w)?.title === "Saved to Google", false);
  const before = google.useGoogleAccount.getState().sheetRequest;
  offers.runVaultOfferAction(tabId);
  assert.equal(google.useGoogleAccount.getState().sheetRequest, before + 1);
  offers.dismissVaultOffer(tabId);
});

test("a failure without an action just shows Google's message", async () => {
  const { tabId } = await savingTab({ saved: false, code: "network", error: "Ardia couldn't reach Google. Check your connection." });
  await offers.saveVaultOffer(tabId);
  const offer = offers.useVaultSaveOffers.getState()[tabId];
  assert.equal(offer?.action, undefined);
  assert.match(offer?.error ?? "", /couldn't reach Google/);
  offers.dismissVaultOffer(tabId);
});

test("the Google password is stored natively and checked before it goes", async () => {
  native.vaultFakes.googlePasswords.length = 0;
  assert.equal(await google.saveGoogleAccountPassword("not-an-email", "pw"), "Enter the email of your Google Account.");
  assert.equal(await google.saveGoogleAccountPassword("me@gmail.com", ""), "Enter your Google password.");
  assert.deepEqual(native.vaultFakes.googlePasswords, []);
  assert.equal(await google.saveGoogleAccountPassword(" me@gmail.com ", "pw"), "");
  assert.deepEqual(native.vaultFakes.googlePasswords, ["me@gmail.com"]);
  assert.equal(google.useGoogleAccount.getState().hasPassword, true);
  await google.forgetGoogleAccountPassword();
  assert.equal(google.useGoogleAccount.getState().hasPassword, false);
});

test("the sign-in check reads native's answer and falls back when it fails", async () => {
  native.vaultFakes.googleSignIn = "signIn";
  assert.equal(await google.checkGoogleSignInState(), "signIn");
  native.vaultFakes.googleSignIn = "signedIn";
  assert.equal(await google.checkGoogleSignInState(), "signedIn");
  assert.equal(google.GOOGLE_SIGN_IN_TEXT.signIn, "Not signed in to Google in Ardia");
});

const savedItem = { provider: "google", id: "pending.octo", title: "github.com", username: "octo", urls: ["https://github.com"], hasTotp: false, pending: true };
const instantReply = (importId) => ({ saved: true, importId, item: savedItem });

test("an instant Google save says Saved to Google once, and the import's own end doesn't say it again", async () => {
  const { w, tabId } = await savingTab(instantReply("fast1"));
  await offers.saveVaultOffer(tabId);
  assert.equal(offers.useVaultSaveOffers.getState()[tabId], null);
  const first = toastOf(w);
  assert.equal(first?.title, "Saved to Google");
  googleImport.applyGoogleImport({ provider: "google", id: "fast1", state: "saved", host: "github.com" });
  assert.equal(toastOf(w)?.id, first.id);
  assert.equal(toastOf(w)?.title, "Saved to Google");
});

test("an instant Google save that fails later says so, and a wrong password offers Update Password", async () => {
  const { w, tabId } = await savingTab(instantReply("fast2"));
  await offers.saveVaultOffer(tabId);
  googleImport.applyGoogleImport({ provider: "google", id: "fast2", state: "failed", host: "github.com", code: "wrongPassword", message: "Google didn't accept the saved password." });
  const toast = toastOf(w);
  assert.equal(toast?.title, "Couldn't Save to Google");
  assert.equal(toast?.message, "Google didn't accept the saved password.");
  assert.equal(toast?.action?.title, "Update Password…");
  const before = google.useGoogleAccount.getState().sheetRequest;
  toast.action.run();
  assert.equal(google.useGoogleAccount.getState().sheetRequest, before + 1);
  googleImport.applyGoogleImport({ provider: "google", id: "fast2", state: "failed", host: "github.com", code: "network", message: "late duplicate" });
  assert.equal(toastOf(w)?.message, "Google didn't accept the saved password.");
});

test("a failure without a fixable cause has no action and falls back to plain copy", async () => {
  const { w, tabId } = await savingTab(instantReply("fast3"));
  await offers.saveVaultOffer(tabId);
  googleImport.applyGoogleImport({ provider: "google", id: "fast3", state: "failed", host: "github.com", code: "timeout" });
  assert.equal(toastOf(w)?.title, "Couldn't Save to Google");
  assert.equal(toastOf(w)?.message, "Couldn't save to Google. Try again.");
  assert.equal(toastOf(w)?.action, undefined);
});

test("when Google needs the person after an instant save, one Confirm toast reveals the page, then the end says Saved", async () => {
  const { w, tabId } = await savingTab(instantReply("fast4"));
  await offers.saveVaultOffer(tabId);
  googleImport.applyGoogleImport({ provider: "google", id: "fast4", state: "confirm", host: "github.com", code: "twoStep" });
  const ask = toastOf(w);
  assert.equal(ask?.title, "Google needs you to confirm");
  assert.equal(ask?.action?.title, "Confirm…");
  googleImport.applyGoogleImport({ provider: "google", id: "fast4", state: "confirm", host: "github.com", code: "twoStep" });
  assert.equal(toastOf(w)?.id, ask.id);
  native.vaultFakes.reveals.length = 0;
  ask.action.run();
  await settle();
  assert.deepEqual(native.vaultFakes.reveals, ["fast4"]);
  googleImport.applyGoogleImport({ provider: "google", id: "fast4", state: "saved", host: "github.com" });
  assert.equal(toastOf(w)?.title, "Saved to Google");
});

test("an import that ends before its save reply arrives still gets its failure shown", async () => {
  const { w, tabId } = await savingTab(instantReply("fast5"));
  webviews.set(tabId, {
    saveToVault: async () => {
      googleImport.applyGoogleImport({ provider: "google", id: "fast5", state: "failed", host: "github.com", code: "network", message: "Ardia couldn't reach Google. Check your connection." });
      return instantReply("fast5");
    },
    discardVaultCapture: async () => {},
    setVaultMenu: async () => {},
  });
  await offers.saveVaultOffer(tabId);
  assert.equal(toastOf(w)?.title, "Couldn't Save to Google");
});

test("a confirm event while the offer is still open lands on the offer, not in a toast", async () => {
  const { w, tabId } = await savingTab({ saved: false, code: "confirm", importId: "slow1", error: "x" });
  await offers.saveVaultOffer(tabId);
  const before = toastOf(w);
  googleImport.applyGoogleImport({ provider: "google", id: "slow1", state: "confirm", host: "github.com" });
  assert.equal(offers.useVaultSaveOffers.getState()[tabId]?.action, "confirm");
  assert.equal(toastOf(w), before);
  offers.dismissVaultOffer(tabId);
});

test("an import the person cancelled ends quietly: no toast, and an open offer just stops waiting", async () => {
  const { w, tabId } = await savingTab(instantReply("fast6"));
  await offers.saveVaultOffer(tabId);
  const saved = toastOf(w);
  googleImport.applyGoogleImport({ provider: "google", id: "fast6", state: "failed", host: "github.com", code: "cancelled", message: "Cancelled." });
  assert.equal(toastOf(w), saved);
  const slow = await savingTab({ saved: false, code: "confirm", importId: "slow2", error: "x" });
  await offers.saveVaultOffer(slow.tabId);
  const before = toastOf(slow.w);
  googleImport.applyGoogleImport({ provider: "google", id: "slow2", state: "failed", host: "github.com", code: "cancelled", message: "Cancelled." });
  const offer = offers.useVaultSaveOffers.getState()[slow.tabId];
  assert.equal(offer?.busy, false);
  assert.equal(offer?.error, "");
  assert.equal(offer?.action, undefined);
  assert.equal(toastOf(slow.w), before);
  offers.dismissVaultOffer(slow.tabId);
});
