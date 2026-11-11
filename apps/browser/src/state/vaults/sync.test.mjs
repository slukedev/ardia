import assert from "node:assert/strict";
import { mock, test } from "node:test";
const native = await import("../../test-native/index.ts");
const { useBrowser } = await import("../browser/store.ts");
const { DEFAULT_SETTINGS, parseSettings, VAULT_SYNC_INTERVALS } = await import("../settings/settings.ts");
const { CONFIG_SETTING_KEYS } = await import("../settings/configAllowlist.ts");
const { startNativeSettings } = await import("../settings/nativeSettings.ts");
const { vaultSyncSeconds } = await import("./syncInterval.ts");
const { EVERY_VAULT, syncEveryVault, syncStatusOf, syncVault, useVaultSync } = await import("./sync.ts");
const store = await import("./store.ts");

const S = () => useBrowser.getState();
const caps = { totp: true, save: true, selfHosted: true, masterPassword: true, touchID: false };
const provider = (id, state) => ({ id, name: id, state, capabilities: caps, install: { command: "", url: "" } });
const settle = () => new Promise((r) => setImmediate(r));

async function setup(providers) {
  native.vaultFakes.providers = providers;
  native.vaultFakes.items = [];
  native.vaultFakes.refreshed.length = 0;
  useVaultSync.setState({}, true);
  store.clearVaultIndex();
  await store.loadVaultProviders();
}

test("passwords sync automatically by default, which native reads as today's on-use refresh", () => {
  assert.equal(DEFAULT_SETTINGS.vaultSyncInterval, "automatic");
  assert.equal(vaultSyncSeconds("automatic"), null);
  assert.ok(CONFIG_SETTING_KEYS.includes("vaultSyncInterval"));
});

test("each interval sends its seconds, and Manually sends zero", () => {
  assert.deepEqual(
    VAULT_SYNC_INTERVALS.map(vaultSyncSeconds),
    [null, 300, 900, 3600, 0],
  );
});

test("an unknown saved interval reads as Automatically", () => {
  assert.equal(parseSettings({ vaultSyncInterval: "hourly" }).vaultSyncInterval, "automatic");
  assert.equal(parseSettings({ vaultSyncInterval: "manual" }).vaultSyncInterval, "manual");
});

test("changing the interval sends it to native with the other vault options", async () => {
  S().hydrate({});
  const stop = startNativeSettings();
  await settle();
  assert.equal(native.vaultFakes.options.syncIntervalSeconds, null);
  S().updateSettings({ vaultSyncInterval: "every15Minutes" });
  await settle();
  assert.equal(native.vaultFakes.options.syncIntervalSeconds, 900);
  assert.equal(native.vaultFakes.options.idleLockMinutes, DEFAULT_SETTINGS.vaultIdleLockMinutes);
  S().updateSettings({ vaultSyncInterval: "manual" });
  await settle();
  assert.equal(native.vaultFakes.options.syncIntervalSeconds, 0);
  stop();
});

test("Sync Now refreshes one manager, says Synced, then clears after two seconds", async () => {
  await setup([provider("bitwarden", "unlocked")]);
  mock.timers.enable({ apis: ["setTimeout"] });
  try {
    const running = syncVault("bitwarden");
    assert.equal(useVaultSync.getState().bitwarden, "syncing");
    await running;
    assert.deepEqual(native.vaultFakes.refreshed, ["bitwarden"]);
    assert.equal(useVaultSync.getState().bitwarden, "synced");
    mock.timers.tick(1999);
    assert.equal(useVaultSync.getState().bitwarden, "synced");
    mock.timers.tick(1);
    assert.equal(useVaultSync.getState().bitwarden, undefined);
  } finally {
    mock.timers.reset();
  }
});

test("a second press while syncing doesn't start another sync", async () => {
  await setup([provider("bitwarden", "unlocked")]);
  await Promise.all([syncVault("bitwarden"), syncVault("bitwarden")]);
  assert.deepEqual(native.vaultFakes.refreshed, ["bitwarden"]);
});

test("Sync Now for every manager skips locked and signed-out ones", async () => {
  await setup([provider("bitwarden", "unlocked"), provider("1password", "locked"), provider("protonpass", "signedOut")]);
  await syncEveryVault();
  assert.deepEqual(native.vaultFakes.refreshed, ["bitwarden"]);
  assert.equal(useVaultSync.getState()[EVERY_VAULT], "synced");
});

test("with nothing unlocked, syncing every manager does nothing and shows nothing", async () => {
  await setup([provider("bitwarden", "locked")]);
  await syncEveryVault();
  assert.deepEqual(native.vaultFakes.refreshed, []);
  assert.equal(useVaultSync.getState()[EVERY_VAULT], undefined);
});

test("a manager that locks during Sync Now shows no Synced", async () => {
  await setup([provider("bitwarden", "unlocked")]);
  native.vaultFakes.providers = [provider("bitwarden", "locked")];
  await syncVault("bitwarden");
  assert.equal(useVaultSync.getState().bitwarden, undefined);
});

test("a manager shows syncing while native syncs or a Sync Now runs, and Synced only once both are done", () => {
  assert.equal(syncStatusOf(false, undefined), null);
  assert.equal(syncStatusOf(true, undefined), "syncing");
  assert.equal(syncStatusOf(false, "syncing"), "syncing");
  assert.equal(syncStatusOf(true, "synced"), "syncing");
  assert.equal(syncStatusOf(false, "synced"), "synced");
});

test("Sync Now keeps syncing until native's own sync ends, then says Synced", async () => {
  await setup([provider("google", "unlocked")]);
  store.startVaultIndex();
  native.vaultFakes.providers = [{ ...provider("google", "unlocked"), syncing: true }];
  const running = syncVault("google");
  await settle();
  await settle();
  assert.equal(useVaultSync.getState().google, "syncing");
  assert.equal(store.vaultProviderOf("google")?.syncing, true);
  native.emitEvent("vaults.changed", { provider: provider("google", "unlocked") });
  await running;
  assert.equal(useVaultSync.getState().google, "synced");
});

test("Sync Now that ends with Google asking for the person shows no Synced", async () => {
  await setup([provider("google", "unlocked")]);
  native.vaultFakes.providers = [{ ...provider("google", "unlocked"), hold: "twoStep" }];
  await syncVault("google");
  assert.equal(useVaultSync.getState().google, undefined);
});
