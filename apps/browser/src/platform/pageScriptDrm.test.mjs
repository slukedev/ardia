import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const script = readFileSync(new URL("../../../../packages/ardiacore/ios/page_script.js", import.meta.url), "utf8");
const start = script.indexOf("    const NavigatorType = window.Navigator;\n");
const end = script.indexOf("  } catch (e) {}\n", start);
assert.ok(start > 0 && end > start, "page_script.js has the DRM block");
const source = script.slice(start, end);
const helperStart = script.indexOf("  const asNative = ");
const helperEnd = script.indexOf("  const { keys, setPrototypeOf } = Object;\n", helperStart);
assert.ok(helperStart > 0 && helperEnd > helperStart, "page_script.js has asNative");
const asNative = new Function(`${script.slice(helperStart, helperEnd)}return asNative;`)();

class HTMLMediaElement {
  constructor(state = {}) {
    Object.assign(this, { paused: true, ended: false, readyState: 0, currentTime: 0, mediaKeys: null, error: null }, state);
    this.listeners = {};
  }
  addEventListener(type, fn) {
    (this.listeners[type] ??= []).push(fn);
  }
}

class MediaKeyStatusMap {
  #statuses;
  constructor(statuses) {
    this.#statuses = statuses;
  }
  forEach(fn) {
    for (const [keyId, status] of this.#statuses) fn(status, keyId, this);
  }
}

function page(supported, { keyless = null, cdm = null } = {}) {
  if (cdm) keyless ??= [];
  const sent = [];
  class MediaKeySession extends EventTarget {
    statuses = new Map();
    get keyStatuses() {
      return new MediaKeyStatusMap(this.statuses);
    }
    update(response) {
      return cdm.licence === "rejected" ? Promise.reject(new Error("license request failed")) : Promise.resolve();
    }
    showStatus(status) {
      this.statuses.set("key", status);
      this.dispatchEvent(new Event("keystatuseschange"));
    }
  }
  class MediaKeys {
    createSession() {
      return new MediaKeySession();
    }
  }
  const timers = [];
  let now = 0;
  const inDocument = [];
  const documentListeners = {};
  class MediaKeySystemAccess {
    #keySystem;
    constructor(keySystem) {
      this.#keySystem = keySystem;
    }
    get keySystem() {
      return this.#keySystem;
    }
  }
  Object.defineProperty(MediaKeySystemAccess.prototype, "createMediaKeys", {
    value: {
      createMediaKeys() {
        if (!(this instanceof MediaKeySystemAccess)) return Promise.reject(new TypeError("Illegal invocation"));
        return keyless.includes(this.keySystem) ? Promise.reject(new Error("NotSupportedError")) : Promise.resolve(cdm ? new MediaKeys() : {});
      },
    }.createMediaKeys,
    writable: true,
    enumerable: true,
    configurable: true,
  });
  class Navigator {}
  Object.defineProperty(Navigator.prototype, "requestMediaKeySystemAccess", {
    value: {
      requestMediaKeySystemAccess(keySystem, configurations) {
        if (!supported.includes(keySystem)) return Promise.reject(new Error("NotSupportedError"));
        return Promise.resolve(keyless ? new MediaKeySystemAccess(keySystem) : { keySystem });
      },
    }.requestMediaKeySystemAccess,
    writable: true,
    enumerable: true,
    configurable: true,
  });
  const navigator = new Navigator();
  navigator.userActivation = { isActive: false };
  const document = {
    querySelectorAll: () => inDocument,
    addEventListener: (type, fn) => (documentListeners[type] ??= []).push(fn),
  };
  const setTimeout = (fn, ms) => timers.push({ at: now + ms, fn });
  const guard = (fn) =>
    function () {
      try {
        return Reflect.apply(fn, this, arguments);
      } catch (e) {}
    };
  const detachedMediaWatchers = [];
  const run = new Function("window", "apply", "asNative", "send", "document", "navigator", "HTMLMediaElement", "setTimeout", "guard", "detachedMediaWatchers", source);
  const window = cdm ? { Navigator, MediaKeySystemAccess, MediaKeys, MediaKeySession, MediaKeyStatusMap, EventTarget } : keyless ? { Navigator, MediaKeySystemAccess } : { Navigator };
  run(window, Reflect.apply, asNative, (kind, data) => sent.push({ kind, data }), document, navigator, HTMLMediaElement, setTimeout, guard, detachedMediaWatchers);
  const advance = (ms) => {
    now += ms;
    for (let due; (due = timers.filter((t) => t.at <= now).sort((a, b) => a.at - b.at)[0]); ) {
      timers.splice(timers.indexOf(due), 1);
      due.fn();
    }
  };
  const fire = (m, type) => {
    for (const fn of documentListeners[type] ?? []) fn({ type, target: m });
  };
  const fireDetached = (m, type) => {
    for (const fn of m.listeners[type] ?? []) fn({ type, target: m });
  };
  const addMedia = (state) => {
    const m = new HTMLMediaElement(state);
    inDocument.push(m);
    return m;
  };
  const detachedPlay = (state) => {
    const m = new HTMLMediaElement(state);
    for (const watch of detachedMediaWatchers) watch(m);
    return m;
  };
  const refuse = async (keySystem = "com.widevine.alpha") => {
    await assert.rejects(navigator.requestMediaKeySystemAccess(keySystem, []));
    await settle();
  };
  const keysFor = async (keySystem = "com.widevine.alpha") => (await navigator.requestMediaKeySystemAccess(keySystem, [])).createMediaKeys();
  const sessionFor = async (keySystem) => (await keysFor(keySystem)).createSession();
  return { navigator, Navigator, MediaKeySystemAccess, MediaKeys, MediaKeySession, sent, advance, fire, fireDetached, addMedia, detachedPlay, refuse, keysFor, sessionFor };
}

const settle = () => new Promise((resolve) => setImmediate(resolve));
const drm = (keySystem = "com.widevine.alpha", stage = "access") => [{ kind: "drm", data: { keySystem, stage } }];

test("a refused capability check alone never prompts, with or without media on the page", async () => {
  const p = page(["org.w3.clearkey"]);
  await p.refuse();
  p.advance(10000);
  p.addMedia({ readyState: 4 });
  await p.refuse("com.microsoft.playready");
  p.advance(10000);
  assert.deepEqual(p.sent, []);
});

test("a clear video waiting for Play at 0 s doesn't count as failed protected playback", async () => {
  const p = page([]);
  p.addMedia({ paused: true, readyState: 4, currentTime: 0 });
  await p.refuse();
  p.advance(6000);
  assert.deepEqual(p.sent, []);
});

test("a clear video that plays after a refused probe keeps the page quiet", async () => {
  const p = page([]);
  await p.refuse();
  const video = p.addMedia({ paused: false, readyState: 1 });
  p.fire(video, "play");
  Object.assign(video, { readyState: 4, currentTime: 3 });
  p.advance(6000);
  assert.deepEqual(p.sent, []);
});

test("playback that never starts after a refusal prompts once, naming the first refused system", async () => {
  const p = page([]);
  await p.refuse();
  await p.refuse("com.microsoft.playready");
  const video = p.addMedia({ paused: false, readyState: 1 });
  p.fire(video, "play");
  p.advance(4999);
  assert.deepEqual(p.sent, []);
  p.advance(1);
  p.fire(p.addMedia({ paused: false, readyState: 1 }), "play");
  p.advance(6000);
  assert.deepEqual(p.sent, drm());
});

test("a play attempt before the refusal is judged once the refusal is known", async () => {
  const p = page([]);
  const video = p.addMedia({ paused: false, readyState: 1 });
  p.fire(video, "play");
  p.advance(1000);
  await p.refuse();
  p.advance(4000);
  assert.deepEqual(p.sent, drm());
});

test("a player still stalled when a later refusal arrives prompts after a fresh grace period", async () => {
  const p = page([]);
  const video = p.addMedia({ paused: false, readyState: 1 });
  p.fire(video, "play");
  p.advance(6000);
  assert.deepEqual(p.sent, []);
  await p.refuse();
  p.advance(4999);
  assert.deepEqual(p.sent, []);
  p.advance(1);
  assert.deepEqual(p.sent, drm());
});

test("a player that played before a later refusal stays quiet", async () => {
  const p = page([]);
  const video = p.addMedia({ paused: false, readyState: 1 });
  p.fire(video, "play");
  p.advance(6000);
  Object.assign(video, { readyState: 4, currentTime: 4 });
  await p.refuse();
  p.advance(6000);
  assert.deepEqual(p.sent, []);
});

test("a paused or ended attempt isn't a failure", async () => {
  const p = page([]);
  await p.refuse();
  const video = p.addMedia({ paused: false, readyState: 1 });
  p.fire(video, "play");
  video.paused = true;
  p.advance(6000);
  assert.deepEqual(p.sent, []);
});

test("after a quiet probe, a later refused request during a user's activation still prompts", async () => {
  const p = page([]);
  await p.refuse();
  p.advance(10000);
  assert.deepEqual(p.sent, []);
  p.navigator.userActivation.isActive = true;
  await p.refuse();
  p.advance(5000);
  assert.deepEqual(p.sent, drm());
});

test("an activated refusal stays quiet when media then plays", async () => {
  const p = page([]);
  p.navigator.userActivation.isActive = true;
  await p.refuse();
  p.addMedia({ paused: false, readyState: 4, currentTime: 2 });
  p.advance(6000);
  assert.deepEqual(p.sent, []);
});

test("media that's encrypted and still has no keys prompts, media that got keys doesn't", async () => {
  const p = page([]);
  const keyed = p.addMedia({ paused: false, readyState: 1 });
  p.fire(keyed, "encrypted");
  keyed.mediaKeys = {};
  p.advance(2000);
  assert.deepEqual(p.sent, []);
  const locked = p.addMedia({ paused: false, readyState: 1 });
  p.fire(locked, "waitingforkey");
  p.advance(2000);
  assert.deepEqual(p.sent, drm(""));
});

test("a decode error after a refusal prompts, one before any refusal doesn't", async () => {
  const p = page([]);
  const broken = p.addMedia({ error: { code: 3 } });
  p.fire(broken, "error");
  assert.deepEqual(p.sent, []);
  await p.refuse();
  p.fire(broken, "error");
  assert.deepEqual(p.sent, drm());
});

test("media the page never adds to the document is watched too", async () => {
  const p = page([]);
  await p.refuse();
  const audio = p.detachedPlay({ paused: false, readyState: 1 });
  p.fireDetached(audio, "play");
  p.advance(5000);
  assert.deepEqual(p.sent, drm());
});

test("Clear Key and supported systems aren't reported, and the method keeps its shape", async () => {
  const { navigator, Navigator, sent, advance, fire, addMedia } = page(["org.w3.clearkey", "com.widevine.alpha"]);
  assert.deepEqual(await navigator.requestMediaKeySystemAccess("com.widevine.alpha", []), { keySystem: "com.widevine.alpha" });
  await assert.rejects(navigator.requestMediaKeySystemAccess("org.w3.unknown", []));
  await settle();
  fire(addMedia({ paused: false, readyState: 1 }), "play");
  advance(6000);
  assert.deepEqual(sent, []);
  const descriptor = Object.getOwnPropertyDescriptor(Navigator.prototype, "requestMediaKeySystemAccess");
  assert.equal(descriptor.enumerable, true);
  assert.equal(descriptor.value.name, "requestMediaKeySystemAccess");
  assert.equal(descriptor.value.length, 2);
  assert.equal("prototype" in descriptor.value, false);
  assert.throws(() => new descriptor.value(), TypeError);
  assert.equal(Function.prototype.toString.call(descriptor.value), "function () { [native code] }");
  assert.equal(Object.hasOwn(navigator, "requestMediaKeySystemAccess"), false);
});

test("an access whose keys can't be created counts as a refusal, so stalled playback prompts", async () => {
  const p = page(["com.widevine.alpha"], { keyless: ["com.widevine.alpha"] });
  const access = await p.navigator.requestMediaKeySystemAccess("com.widevine.alpha", []);
  await assert.rejects(access.createMediaKeys());
  await settle();
  const video = p.addMedia({ paused: false, readyState: 1 });
  p.fire(video, "play");
  p.advance(4999);
  assert.deepEqual(p.sent, []);
  p.advance(1);
  assert.deepEqual(p.sent, drm("com.widevine.alpha", "createMediaKeys"));
});

test("keys refused after the click's activation expired still prompt when the access was requested during that click", async () => {
  const p = page(["com.widevine.alpha"], { keyless: ["com.widevine.alpha"] });
  p.navigator.userActivation.isActive = true;
  const access = await p.navigator.requestMediaKeySystemAccess("com.widevine.alpha", []);
  p.navigator.userActivation.isActive = false;
  await assert.rejects(access.createMediaKeys());
  await settle();
  p.advance(4999);
  assert.deepEqual(p.sent, []);
  p.advance(1);
  assert.deepEqual(p.sent, drm("com.widevine.alpha", "createMediaKeys"));
});

test("keys refused for an access requested without activation stay quiet without a stalled play", async () => {
  const p = page(["com.widevine.alpha"], { keyless: ["com.widevine.alpha"] });
  const access = await p.navigator.requestMediaKeySystemAccess("com.widevine.alpha", []);
  await assert.rejects(access.createMediaKeys());
  await settle();
  p.advance(10000);
  assert.deepEqual(p.sent, []);
});

test("keys that are created, Clear Key's refused keys and a wrong receiver keep the page quiet", async () => {
  const p = page(["com.widevine.alpha", "org.w3.clearkey"], { keyless: ["org.w3.clearkey"] });
  const widevine = await p.navigator.requestMediaKeySystemAccess("com.widevine.alpha", []);
  assert.deepEqual(await widevine.createMediaKeys(), {});
  const clearKey = await p.navigator.requestMediaKeySystemAccess("org.w3.clearkey", []);
  await assert.rejects(clearKey.createMediaKeys());
  await assert.rejects(p.MediaKeySystemAccess.prototype.createMediaKeys.call({}), TypeError);
  await settle();
  p.fire(p.addMedia({ paused: false, readyState: 1 }), "play");
  p.advance(6000);
  assert.deepEqual(p.sent, []);
  const descriptor = Object.getOwnPropertyDescriptor(p.MediaKeySystemAccess.prototype, "createMediaKeys");
  assert.equal(descriptor.enumerable, true);
  assert.equal(descriptor.value.name, "createMediaKeys");
  assert.equal(descriptor.value.length, 0);
  assert.equal(Function.prototype.toString.call(descriptor.value), "function () { [native code] }");
});

test("a licence the CDM's server refuses counts as a refusal once playback stalls, and the page still sees its rejection", async () => {
  const p = page(["com.widevine.alpha"], { cdm: { licence: "rejected" } });
  const session = await p.sessionFor();
  await assert.rejects(session.update(new Uint8Array()), /license request failed/);
  await settle();
  p.advance(10000);
  assert.deepEqual(p.sent, []);
  const video = p.addMedia({ paused: false, readyState: 1, mediaKeys: {} });
  p.fire(video, "play");
  p.advance(4999);
  assert.deepEqual(p.sent, []);
  p.advance(1);
  assert.deepEqual(p.sent, drm("com.widevine.alpha", "licence"));
});

test("a refused licence for keys requested during a click prompts without a play event, unless something plays", async () => {
  const quiet = page(["com.widevine.alpha"], { cdm: { licence: "rejected" } });
  quiet.navigator.userActivation.isActive = true;
  const played = await quiet.sessionFor();
  quiet.navigator.userActivation.isActive = false;
  await assert.rejects(played.update(new Uint8Array()));
  await settle();
  quiet.addMedia({ paused: false, readyState: 4, currentTime: 1 });
  quiet.advance(6000);
  assert.deepEqual(quiet.sent, []);

  const p = page(["com.widevine.alpha"], { cdm: { licence: "rejected" } });
  p.navigator.userActivation.isActive = true;
  const session = await p.sessionFor();
  p.navigator.userActivation.isActive = false;
  await assert.rejects(session.update(new Uint8Array()));
  await settle();
  p.advance(5000);
  assert.deepEqual(p.sent, drm("com.widevine.alpha", "licence"));
});

test("output-restricted or internal-error key statuses count once playback stalls, usable keys and playing fallbacks stay quiet", async () => {
  for (const status of ["output-restricted", "internal-error"]) {
    const p = page(["com.widevine.alpha"], { cdm: { licence: "granted" } });
    const session = await p.sessionFor();
    await session.update(new Uint8Array());
    const video = p.addMedia({ paused: false, readyState: 1 });
    p.fire(video, "play");
    session.showStatus(status);
    p.advance(5000);
    assert.deepEqual(p.sent, drm("com.widevine.alpha", "keystatus"), status);
  }

  const p = page(["com.widevine.alpha"], { cdm: { licence: "granted" } });
  const usable = await p.sessionFor();
  await usable.update(new Uint8Array());
  usable.showStatus("usable");
  usable.showStatus("output-downscaled");
  const restricted = await p.sessionFor();
  restricted.showStatus("output-restricted");
  const video = p.addMedia({ paused: false, readyState: 1 });
  p.fire(video, "play");
  Object.assign(video, { readyState: 4, currentTime: 2 });
  p.advance(10000);
  assert.deepEqual(p.sent, []);
});

test("a decrypt error on media keyed by a protected system prompts at once, other errors and Clear Key media don't", async () => {
  const p = page(["com.widevine.alpha", "org.w3.clearkey"], { cdm: { licence: "granted" } });
  const widevine = await p.keysFor();
  const clearKey = await p.keysFor("org.w3.clearkey");
  p.fire(p.addMedia({ mediaKeys: widevine, error: { code: 3, message: "PIPELINE_ERROR_DECODE: video decoder reinitialization failed" } }), "error");
  p.fire(p.addMedia({ mediaKeys: widevine, error: { code: 3, message: "PIPELINE_ERROR_DECODE: first buffer is not a keyframe" } }), "error");
  p.fire(p.addMedia({ mediaKeys: clearKey, error: { code: 5, message: "" } }), "error");
  p.fire(p.addMedia({ error: { code: 3, message: "PIPELINE_ERROR_DECRYPT" } }), "error");
  assert.deepEqual(p.sent, []);
  p.fire(p.addMedia({ mediaKeys: widevine, error: { code: 3, message: "PIPELINE_ERROR_DECRYPT: decrypt error" } }), "error");
  assert.deepEqual(p.sent, drm("com.widevine.alpha", "licence"));

  const encrypted = page(["com.widevine.alpha"], { cdm: { licence: "granted" } });
  const keys = await encrypted.keysFor();
  encrypted.fire(encrypted.addMedia({ mediaKeys: keys, error: { code: 5 } }), "error");
  assert.deepEqual(encrypted.sent, drm("com.widevine.alpha", "licence"));
});

test("a later licence failure takes over from an earlier refused probe, naming the system that failed", async () => {
  const p = page(["com.widevine.alpha"], { cdm: { licence: "rejected" } });
  await p.refuse("com.microsoft.playready");
  const session = await p.sessionFor();
  await assert.rejects(session.update(new Uint8Array()));
  await settle();
  p.fire(p.addMedia({ paused: false, readyState: 1 }), "play");
  p.advance(5000);
  assert.deepEqual(p.sent, drm("com.widevine.alpha", "licence"));
});

test("Clear Key sessions aren't watched, a granted licence that plays stays quiet, and the wrapped methods keep their shape", async () => {
  const p = page(["com.widevine.alpha", "org.w3.clearkey"], { cdm: { licence: "rejected" } });
  const clearKey = await p.sessionFor("org.w3.clearkey");
  await assert.rejects(clearKey.update(new Uint8Array()));
  clearKey.showStatus("internal-error");
  await settle();
  p.fire(p.addMedia({ paused: false, readyState: 1 }), "play");
  p.advance(10000);
  assert.deepEqual(p.sent, []);
  for (const [proto, name, length] of [[p.MediaKeys.prototype, "createSession", 0], [p.MediaKeySession.prototype, "update", 1]]) {
    const descriptor = Object.getOwnPropertyDescriptor(proto, name);
    assert.equal(descriptor.enumerable, false);
    assert.equal(descriptor.value.name, name);
    assert.equal(descriptor.value.length, length);
    assert.equal(Function.prototype.toString.call(descriptor.value), "function () { [native code] }");
  }

  const playing = page(["com.widevine.alpha"], { cdm: { licence: "granted" } });
  const session = await playing.sessionFor();
  await session.update(new Uint8Array());
  session.showStatus("usable");
  const video = playing.addMedia({ paused: false, readyState: 1 });
  playing.fire(video, "play");
  Object.assign(video, { readyState: 4, currentTime: 3 });
  playing.advance(10000);
  assert.deepEqual(playing.sent, []);
});
