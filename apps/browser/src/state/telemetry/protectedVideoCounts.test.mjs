import assert from "node:assert/strict";
import { after, test } from "node:test";

globalThis.__DEV__ = false;
await import("../../test-native/index.ts");

const client = await import("./client.ts");
const { noteProtectedVideoRefusal, takeProtectedVideoCounts } = await import("./protectedVideoCounts.ts");
const { widevineSetting } = await import("./settingsSnapshot.ts");
const { WIDEVINE_COMPONENT_ID } = await import("../../platform/app.ts");
globalThis.fetch = async () => ({ status: 503 });
after(() => client.setSharing(false, "settings"));

function sharing() {
  client.loadChoice();
  client.setSharing(true, "settings");
  takeProtectedVideoCounts();
  return client.consentToken();
}

test("refusals count by the stage they stopped at, an unknown stage counts only in the total, and taking them starts again at zero", () => {
  const consent = sharing();
  noteProtectedVideoRefusal({ keySystem: "com.widevine.alpha", stage: "licence" }, consent);
  noteProtectedVideoRefusal({ keySystem: "com.widevine.alpha", stage: "keystatus" }, consent);
  noteProtectedVideoRefusal({ keySystem: "com.microsoft.playready", stage: "access" }, consent);
  noteProtectedVideoRefusal({ keySystem: "com.widevine.alpha", stage: "createMediaKeys" }, consent);
  noteProtectedVideoRefusal({ keySystem: "com.widevine.alpha", stage: "somethingNew" }, consent);
  noteProtectedVideoRefusal({ keySystem: "" }, consent);
  assert.deepEqual(takeProtectedVideoCounts(), {
    drm_refusals: 6,
    drm_refusals_access: 1,
    drm_refusals_create_keys: 1,
    drm_refusals_licence: 1,
    drm_refusals_keystatus: 1,
  });
  assert.equal(takeProtectedVideoCounts().drm_refusals, 0);
});

test("a refusal counts only under the consent period it started in, and never without one", () => {
  const before = sharing();
  client.setSharing(false, "settings");
  client.setSharing(true, "settings");
  const now = client.consentToken();
  assert.notEqual(now, before);
  noteProtectedVideoRefusal({ keySystem: "com.widevine.alpha", stage: "licence" }, before);
  noteProtectedVideoRefusal({ keySystem: "com.widevine.alpha", stage: "licence" }, null);
  noteProtectedVideoRefusal({ keySystem: "com.widevine.alpha", stage: "access" }, now);
  assert.deepEqual(takeProtectedVideoCounts(), {
    drm_refusals: 1,
    drm_refusals_access: 1,
    drm_refusals_create_keys: 0,
    drm_refusals_licence: 0,
    drm_refusals_keystatus: 0,
  });
});

test("the daily snapshot says whether the engine has a Widevine version, and says nothing when the engine can't list components", () => {
  const widevine = (version) => ({ id: WIDEVINE_COMPONENT_ID, name: "Widevine Content Decryption Module", version, state: "updated" });
  assert.equal(widevineSetting([widevine("4.10.2891.0")]).setting_widevine_installed, "true");
  assert.equal(widevineSetting([widevine("0.0.0.0")]).setting_widevine_installed, "false");
  assert.equal(widevineSetting([{ ...widevine("1.0"), id: "other" }]).setting_widevine_installed, "false");
  assert.deepEqual(widevineSetting(null), {});
});
