import assert from "node:assert/strict";
import { after, test } from "node:test";

globalThis.__DEV__ = false;
const stub = await import("../../test-native/index.ts");
globalThis.fetch = async () => ({ status: 200 });

const client = await import("../telemetry/client.ts");
const usage = await import("../telemetry/usage.ts");
const { noteProtectedVideoRefusal } = await import("../telemetry/protectedVideoCounts.ts");
const { installWidevine, useWidevineInstall, widevine } = await import("./paneData.ts");
const { cached } = await import("./resources.ts");
const { WIDEVINE_COMPONENT_ID } = await import("../../platform/app.ts");
after(() => client.setSharing(false, "settings"));

const component = (version, state) => ({ id: WIDEVINE_COMPONENT_ID, name: "Widevine Content Decryption Module", version, state });
let components = [];
const updates = [];
globalThis.acTestComponents = () => components;

const COUNT_FIELDS = ["widevine_install_attempts", "widevine_install_successes", "widevine_install_failures", "drm_refusals", "drm_refusals_access", "drm_refusals_create_keys", "drm_refusals_licence", "drm_refusals_keystatus"];

async function sentCounts() {
  usage.sessionEnding();
  await client.saveQueueNow();
  const saved = JSON.parse(stub.docs.get("telemetry-queue.json") ?? '{"events":[]}');
  const last = saved.events.filter((e) => e.event === "usage_counts").at(-1);
  return Object.fromEntries(COUNT_FIELDS.map((field) => [field, last?.properties[field]]));
}

test("Install asks the updater for Widevine, follows it until a version shows, and counts each outcome", async () => {
  client.loadChoice();
  client.setSharing(true, "onboarding");

  components = [component("0.0.0.0", "new")];
  globalThis.acTestUpdateComponent = (id) => (updates.push(id), (components = [component("4.10.2891.0", "updated")]), { ok: true });
  await installWidevine();
  assert.deepEqual(updates, [WIDEVINE_COMPONENT_ID]);
  assert.equal(useWidevineInstall.getState().phase, "idle");
  assert.equal(cached(widevine, []).version, "4.10.2891.0");

  components = [component("0.0.0.0", "new")];
  globalThis.acTestUpdateComponent = () => ({ ok: false, error: "download" });
  await installWidevine();
  assert.equal(useWidevineInstall.getState().phase, "failed");

  components = [component("0.0.0.0", "downloading")];
  globalThis.acTestUpdateComponent = () => {
    setTimeout(() => (components = [component("4.10.2891.0", "updated")]), 200);
    return { ok: false, error: "inProgress" };
  };
  const running = installWidevine();
  assert.equal(useWidevineInstall.getState().phase, "installing");
  await installWidevine();
  await running;
  assert.equal(useWidevineInstall.getState().phase, "idle");

  components = [component("0.0.0.0", "updateError")];
  globalThis.acTestUpdateComponent = () => {
    setTimeout(() => (components = [component("0.0.0.0", "updateError")]), 200);
    components = [component("0.0.0.0", "downloading")];
    return { ok: false, error: "inProgress" };
  };
  await installWidevine();
  assert.equal(useWidevineInstall.getState().phase, "failed");

  noteProtectedVideoRefusal({ keySystem: "com.widevine.alpha", stage: "licence" });
  noteProtectedVideoRefusal({ keySystem: "com.widevine.alpha", stage: "keystatus" });
  noteProtectedVideoRefusal({ keySystem: "com.microsoft.playready", stage: "access" });
  noteProtectedVideoRefusal({ keySystem: "com.widevine.alpha", stage: "createMediaKeys" });
  noteProtectedVideoRefusal({ keySystem: "" });
  assert.deepEqual(await sentCounts(), {
    widevine_install_attempts: 4,
    widevine_install_successes: 2,
    widevine_install_failures: 2,
    drm_refusals: 5,
    drm_refusals_access: 1,
    drm_refusals_create_keys: 1,
    drm_refusals_licence: 1,
    drm_refusals_keystatus: 1,
  });
});
