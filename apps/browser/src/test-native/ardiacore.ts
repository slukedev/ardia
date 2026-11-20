import type {
  ActionState,
  SiteSettings,
  BookmarkOp,
  CallArgs,
  CallName,
  CallResult,
  ChromeWindowState,
  CliControlStatus,
  CliTabTarget,
  EngineBookmark,
  EngineComponent,
  EngineEvents,
  EngineTask,
  EventData,
  EventName,
  HistoryChange,
  HistoryChangedBatch,
  InstalledExtension,
  LinkRoute,
  TabStripCommand,
  TabStripTransaction,
} from "@ardia/ardiacore";
import type { EventSubscription } from "expo-modules-core";
import { nativeEvents, unfaked } from "./events";
import type { AutofillToggle } from "../platform/autofill";


type TabStripHost = {
  listen(listener: (tx: TabStripTransaction) => void): EventSubscription;
  command(command: TabStripCommand, id: number): unknown;
  snapshot(): Promise<TabStripTransaction>;
};
type ExtensionEngine = {
  list(profile: string): Promise<InstalledExtension[]>;
  install(path: string, profile: string): Promise<string>;
  reload(id: string, profile: string): Promise<void>;
  uninstall(id: string, profile: string): Promise<void>;
  configure?(id: string, profile: string, options: Record<string, unknown>): Promise<void>; inspect?(path: string): Promise<CallResult<"extensions.inspectUnpacked">>;
};
const testGlobals = globalThis as {
  acTestTabStrip?: TabStripHost;
  acTestCliControl?: (on: boolean | null) => Promise<CliControlStatus> | undefined;
  acTestCliActive?: (tabId: string | null) => Promise<CliControlStatus> | undefined;
  acTestCliTargets?: (tabId: string) => CliTabTarget | undefined;
  acTestCliOwns?: (tabId: string) => { owned: boolean; shown: boolean };
  acTestCliMoveOffscreen?: (tabId: string) => { ok: boolean; reason?: string };
  acTestTasks?: () => EngineTask[];
  acTestComponents?: () => EngineComponent[];
  acTestEngineInfo?: () => CallResult<"engine.info">;
  acTestUserScripts?: { engine: ExtensionEngine };
  acTestSuggest?: (args: { url: string; id: number; profile: string }) => CallResult<"search.suggest"> | undefined;
};

type VerbOf<D extends string, N extends string = CallName> = N extends `${D}.${infer V}` ? V : never;
type Call<D extends string, V extends string> = `${D}.${V}` & CallName;
type Handlers<D extends string> = {
  [V in VerbOf<D>]?: (args: CallArgs<Call<D, V>> & { profile: string }) => CallResult<Call<D, V>> | Promise<CallResult<Call<D, V>>>;
};
type FakeDomain = { call(name: string, profile: string, json: string): Promise<string>; addListener: ReturnType<typeof nativeEvents>["addListener"] };

const domainEvents = new Map<string, ReturnType<typeof nativeEvents>>();
const eventsOf = (domain: string) => {
  if (!domainEvents.has(domain)) domainEvents.set(domain, nativeEvents());
  return domainEvents.get(domain)!;
};
export const emitEvent = <E extends EventName>(name: E, data: EventData<E>) => {
  const domain = name.slice(0, name.indexOf("."));
  eventsOf(domain).emit(domain, { name, data });
};

export const chromeWindowList: ChromeWindowState[] = [];
export const engineCalls: { domain: string; verb: string; profile: string }[] = [];
export const loadedEngineProfiles = new Set<string>([""]);
export const idleProfileUnloads = new Map<string, CallResult<"profiles.unloadIdle"> & { closing?: () => void }>();
export const profilesLoadedCall = { known: true };

function domain<D extends string, Sync extends object>(name: D, handlers: Handlers<D>, sync?: Sync): FakeDomain & Sync {
  const fake: FakeDomain = {
    call: (verb, profile, json) => {
      engineCalls.push({ domain: name, verb, profile });
      const handler = (handlers as Record<string, ((args: object) => unknown) | undefined>)[verb];
      if (!handler) return Promise.reject(Object.assign(new Error(`${name}.${verb} has no test fake yet`), { code: "ERR_UNKNOWN_CALL" }));
      const args = { ...(JSON.parse(json) as Record<string, unknown>), profile };
      try {
        return Promise.resolve(handler(args)).then((value) => JSON.stringify(value ?? null));
      } catch (error) {
        return Promise.reject(error);
      }
    },
    addListener: eventsOf(name).addListener,
  };
  return Object.assign(fake, sync);
}

const laterEvent = <E extends EventName>(name: E, data: EventData<E>) => queueMicrotask(() => emitEvent(name, data));
export const emitDownload = (download: EngineEvents["downloads.changed"]) => emitEvent("downloads.changed", download);
export const emitPermission = (request: EngineEvents["permissions.requested"]) => emitEvent("permissions.requested", request);

export const passwordProviders = {
  calls: [] as unknown[][],
  generation: 0,
  profiles: [] as { profile: string; fields: string[]; codeSetup: boolean }[],
  panel: { shown: true } as CallResult<"passwords.showSystemPanel">,
  handlerApp: "Passwords" as string | null,
  lastPanelGeneration: undefined as number | undefined,
  opened: [] as { tab: string; token: string; generation?: number }[],
  openResult: true,
  hold: null as Promise<void> | null,
  holdNext: null as Promise<void> | null,
  notAppliedNext: 0,
  bareReplyNext: 0,
  sessions: [] as unknown[],
  rejectNext: 0,
  handlerGate: null as Promise<void> | null,
  hints: [] as { tab: string; label: string; side: string }[],
  hintShown: true,
};
const providerFakes = {
  setFieldProviders: async (args: { generation: number; session: string; profiles: { profile: string; fields: string[]; codeSetup: boolean }[] }) => {
    const { generation, profiles } = args;
    passwordProviders.calls.push(["setFieldProviders", generation, profiles.map((p) => p.profile)]);
    passwordProviders.sessions.push(args.session);
    if (passwordProviders.rejectNext > 0) {
      passwordProviders.rejectNext -= 1;
      throw new Error("native refused the provider set");
    }
    const once = passwordProviders.holdNext;
    passwordProviders.holdNext = null;
    await once;
    await passwordProviders.hold;
    if (passwordProviders.bareReplyNext > 0) {
      passwordProviders.bareReplyNext -= 1;
      return {} as { applied: boolean };
    }
    if (passwordProviders.notAppliedNext > 0) {
      passwordProviders.notAppliedNext -= 1;
      return { applied: false };
    }
    passwordProviders.generation = generation;
    passwordProviders.profiles = profiles.map((p) => ({ ...p, fields: [...p.fields] }));
    return { applied: true };
  },
  showSystemPanel: ({ tab, generation }: { tab: string; generation?: number }) => (passwordProviders.calls.push(["showSystemPanel", tab]), (passwordProviders.lastPanelGeneration = generation), { ...passwordProviders.panel }),
  showPanelHint: ({ tab, label, side }: { tab: string; label: string; side: string }) => (passwordProviders.hints.push({ tab, label, side }), { shown: passwordProviders.hintShown }),
  systemPanelAvailable: () => ({ chromium: true, webkit: true }),
  otpauthHandler: async () => (passwordProviders.calls.push(["otpauthHandler"]), await passwordProviders.handlerGate, { app: passwordProviders.handlerApp }),
  setUpVerificationCode: ({ tab, token, generation }: { tab: string; token: string; generation?: number }) => (passwordProviders.opened.push({ tab, token, generation }), { opened: passwordProviders.openResult }),
};
export const current = { device: null as string | null };

export const siteSettingsDb = new Map<string, Record<string, string>>();
export const siteZoomDb = new Map<string, number>();
const SITE_SETTING_TYPES = ["popups", "camera", "microphone", "location", "notifications", "sound", "autoplay", "javascript", "images", "clipboard", "automaticDownloads", "cookies", "midi", "sensors", "windowManagement", "localFonts", "idleDetection", "storageAccess", "fileSystem", "keyboardLock", "pointerLock", "cameraPanTiltZoom"];
const siteSettingsOf = (profile: string, origin: string) => {
  const own = siteSettingsDb.get(`${profile}\n${origin}`) ?? {};
  return Object.fromEntries(SITE_SETTING_TYPES.map((t) => [t, own[t] && own[t] !== "default" ? { value: own[t], isDefault: false } : { value: "ask", isDefault: true }]));
};

type Login = { origin: string; url: string; username: string; password: string; created: number };
export const passwordStores = new Map<string | null, Map<string, Login>>();
const logins = () => passwordStores.get(current.device)!;
export const readLogins = async () => [...logins().values()];

type HistoryRow = { title: string; visits: number[] };
export const historyDbs = new Map<string | null, Map<string, Map<string, HistoryRow>>>();
export const chromeHistory = (profile = "", device = current.device) => {
  if (!historyDbs.has(device)) historyDbs.set(device, new Map());
  const dbs = historyDbs.get(device)!;
  if (!dbs.has(profile)) dbs.set(profile, new Map());
  return dbs.get(profile)!;
};
export const historyWatches: string[] = [];

export function chromeHistoryEvent(change: HistoryChange) {
  const wire: HistoryChangedBatch["changes"][number] =
    change.kind === "visit"
      ? { kind: "visit", u: change.url, t: change.title, n: change.visits, at: change.at }
      : change.kind === "modified"
        ? { kind: "modified", rows: change.rows.map((r) => ({ u: r.url, t: r.title, n: r.visits })) }
        : { kind: "deleted", all: change.all, urls: change.urls };
  laterEvent("history.changed", { profile: change.profile, kind: "batch", changes: [wire] });
}

function addVisit(profile: string, url: string, title: string, at: number) {
  const db = chromeHistory(profile);
  const row = db.get(url) ?? { title: "", visits: [] };
  row.visits = [...row.visits, at].sort((a, b) => a - b);
  if (title) row.title = title;
  db.set(url, row);
  chromeHistoryEvent({ kind: "visit", profile, url, title: row.title, visits: row.visits.length, at });
}
export const chromeVisit = (profile: string, url: string, title: string, at = Date.now()) => addVisit(profile, url, title, at);

export const historyQueries: { profile: string; maxUrls: number; maxVisits: number }[] = [];

function queryHistory(profile: string, { maxUrls = 5000, maxVisits = 50 }: { maxUrls?: number; maxVisits?: number }) {
  historyQueries.push({ profile, maxUrls, maxVisits });
  const entries = [...chromeHistory(profile)]
    .map(([u, r]) => ({ u, t: r.title, n: r.visits.length, v: r.visits.slice(-maxVisits) }))
    .sort((a, b) => (b.v.at(-1) ?? 0) - (a.v.at(-1) ?? 0))
    .slice(0, maxUrls);
  return { entries };
}

function addHistoryVisits(profile: string, { pages, toleranceMs = 1000 }: { pages: { u: string; t: string; v: number[] }[]; toleranceMs?: number }) {
  let added = 0;
  for (const page of pages) {
    const have = [...(chromeHistory(profile).get(page.u)?.visits ?? [])];
    for (const at of [...page.v].sort((a, b) => a - b)) {
      const match = have.findIndex((t) => Math.abs(t - at) <= toleranceMs);
      if (match >= 0) {
        have.splice(match, 1);
        continue;
      }
      addVisit(profile, page.u, chromeHistory(profile).get(page.u)?.title || page.t, at);
      added++;
    }
  }
  return { added };
}

export const ENGINE_REQUEST_LIMIT_BYTES = 8 * 1024 * 1024;
export const historyImportRequestBytes: number[] = [];
export const refusedHistoryImports = { next: 0 };
export const heldHistoryImports: { reply: Promise<void> | null } = { reply: null };
export const heldHistoryQueries: { reply: Promise<void> | null } = { reply: null };

function importHistoryRows(profile: string, { rows }: { rows: { u: string; t: string; l: number }[] }) {
  const bytes = new TextEncoder().encode(JSON.stringify({ rows })).length;
  historyImportRequestBytes.push(bytes);
  if (bytes > ENGINE_REQUEST_LIMIT_BYTES) throw Object.assign(new Error("Invalid or oversized engine request"), { code: "ERR_ENGINE" });
  if (refusedHistoryImports.next > 0) {
    refusedHistoryImports.next--;
    throw Object.assign(new Error("no history"), { code: "ERR_ENGINE" });
  }
  for (const r of rows) if (!chromeHistory(profile).has(r.u)) chromeHistory(profile).set(r.u, { title: r.t, visits: [r.l] });
  return heldHistoryImports.reply ? heldHistoryImports.reply.then(() => ({})) : {};
}

export const bookmarkModel = { loading: new Set<string>(), treeFails: false, treeHangs: false };
export const historyDeletes = { failNext: false };

function deleteHistoryUrls(profile: string, { urls }: { urls: string[] }) {
  if (historyDeletes.failNext) {
    historyDeletes.failNext = false;
    throw new Error("the history database couldn't be written");
  }
  for (const url of urls) chromeHistory(profile).delete(url);
  chromeHistoryEvent({ kind: "deleted", profile, all: false, urls });
  return {};
}

export const chromeFavicons = new Map<string, string>();
const PNG_URI = "data:image/png;base64,";
function faviconsFor(profile: string, { pages }: { pages: string[] }) {
  const known = pages.filter((p) => chromeFavicons.has(`${profile}|${p}`));
  const png = (p: string) => chromeFavicons.get(`${profile}|${p}`)!.replace(PNG_URI, "");
  return { pages: Object.fromEntries(known.map((p) => [p, { png: png(p), icon: "" }])), icons: {} };
}

type BookmarkNode = { id: string; k: "u" | "f"; t: string; u?: string; a: number; key?: string; parent: string | null; children: string[] };
export const bookmarkDbs = new Map<string | null, Map<string, Map<string, BookmarkNode>>>();
export const chromeBookmarks = (profile = "", device = current.device) => {
  if (!bookmarkDbs.has(device)) bookmarkDbs.set(device, new Map());
  const dbs = bookmarkDbs.get(device)!;
  if (!dbs.has(profile)) {
    const folder = (id: string, t: string): BookmarkNode => ({ id, k: "f", t, a: 0, parent: null, children: [] });
    dbs.set(profile, new Map([["bar", folder("bar", "Bookmarks Bar")], ["other", folder("other", "Other Bookmarks")]]));
  }
  return dbs.get(profile)!;
};

function treeOf(db: Map<string, BookmarkNode>, id: string): EngineBookmark {
  const n = db.get(id)!;
  const key = n.key ? { key: n.key } : {};
  return n.k === "u"
    ? { id: n.id, k: "u", t: n.t, u: n.u, a: n.a, ...key }
    : { id: n.id, k: "f", t: n.t, a: n.a, ...key, c: n.children.map((c) => treeOf(db, c)) };
}

function isAncestor(db: Map<string, BookmarkNode>, node: string, of: string) {
  for (let at: string | null | undefined = of; at; at = db.get(at)?.parent) if (at === node) return true;
  return false;
}

function moveTo(db: Map<string, BookmarkNode>, id: string, parent: string, index?: number) {
  const node = db.get(id)!;
  const old = node.parent ? db.get(node.parent) : undefined;
  if (old) old.children.splice(old.children.indexOf(id), 1);
  const kids = db.get(parent)!.children;
  kids.splice(Math.max(0, Math.min(index ?? kids.length, kids.length)), 0, id);
  node.parent = parent;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
function applyOp(db: Map<string, BookmarkNode>, op: BookmarkOp): boolean | "invalid" {
  const node = db.get(op.id);
  const permanent = op.id === "bar" || op.id === "other";
  if (op.op === "remove") {
    if (!node || permanent) return false;
    const drop = (id: string) => {
      db.get(id)!.children.forEach(drop);
      db.delete(id);
    };
    const parent = db.get(node.parent!)!;
    parent.children = parent.children.filter((c) => c !== op.id);
    drop(op.id);
    return true;
  }
  if (op.op === "update") {
    if (!node || permanent) return false;
    if (op.t !== undefined) node.t = op.t;
    if (op.u && node.k === "u") node.u = op.u;
    return true;
  }
  const parent = db.get(op.parent);
  if (!parent || parent.k !== "f") return false;
  if (op.op === "move") {
    if (!node || permanent || isAncestor(db, op.id, op.parent)) return false;
    moveTo(db, op.id, op.parent, op.index);
    return true;
  }
  if (node && op.ifAbsent) return true;
  if (node) {
    if (permanent || isAncestor(db, op.id, op.parent)) return false;
    moveTo(db, op.id, op.parent, op.index);
    node.t = op.t;
    if (op.u && node.k === "u") node.u = op.u;
    return true;
  }
  if (!UUID.test(op.id)) return false;
  if (op.k === "u" && !/^[a-z][a-z0-9+.-]*:/i.test(op.u ?? "")) return "invalid";
  db.set(op.id, { id: op.id, k: op.k, t: op.t, ...(op.k === "u" ? { u: op.u } : {}), children: [], a: op.a, ...(op.key ? { key: op.key } : {}), parent: null });
  moveTo(db, op.id, op.parent, op.index);
  return true;
}

export const bookmarkOpsSent: BookmarkOp[] = [];
function applyBookmarkOps(profile: string, { ops }: { ops: BookmarkOp[] }) {
  bookmarkOpsSent.push(...ops);
  const db = chromeBookmarks(profile);
  let applied = 0;
  const invalid: string[] = [];
  for (const op of ops) {
    const result = applyOp(db, op);
    if (result === "invalid") invalid.push(op.id);
    else if (result) applied++;
    else break;
  }
  return { applied, skipped: ops.length - applied - invalid.length, invalid };
}

export function chromeBookmarkEdit(profile: string, ops: BookmarkOp[]) {
  const db = chromeBookmarks(profile);
  for (const op of ops) applyOp(db, op);
  laterEvent("bookmarks.changed", { profile });
}

const cliStatus = (on: boolean | null): CliControlStatus =>
  on ? { state: "on", port: 0, connections: 0, generation: 0, file: "" } : { state: "off", connections: 0, generation: 0, file: "" };
const cliControl = (on: boolean | null) => testGlobals.acTestCliControl?.(on) ?? cliStatus(on);

export const cancelledDownloads: string[] = [];
export const downloadSettingsWrites: { profile: string; folder?: string; askWhereToSave?: boolean }[] = [];
export const clearedSiteData: { profile: string; origin: string }[] = [];
export const endedWebKitSessions: string[] = [];
export const removedStagings: string[] = [];
export const stagingRemovals = { ok: true };
export const deletedProfileData: string[] = [];
export const profileDataLeft = new Map<string, string[]>();
export const revealedTabs: string[] = [];
export const nativeTabSwitches: boolean[] = [];
export const nativeTabPresses: { byStart: Map<number, number>; dropped: number[]; splits: string[][] } = { byStart: new Map(), dropped: [], splits: [] };
export const discardedOffers: string[] = [];
export const installedCrx: { path: string; profile: string }[] = [];
export const chosenExtensionFolder: { next: string | null } = { next: null };
export const crxInstallFailure: { next: string | null } = { next: null };
export const linkRoute: { next: LinkRoute } = { next: {} };
export const resolvedPermissions: { id: string; result: string; remember: boolean }[] = [];

export const extensionAnswers = {
  actionStates: async (_tabId: string, _ids: string[], _profile?: string): Promise<Record<string, ActionState>> => ({}),
  sidePanelUrl: async (_tabId: string, _extensionId: string, _profile?: string): Promise<string | null> => null,
  change: async (_verb: string, _id: string): Promise<void> => {},
  resolveInstallPrompt: async (_requestId: string, _accepted: boolean, _profile?: string): Promise<null> => null,
};

const tabStripHost = () => testGlobals.acTestTabStrip!;
let autofillIds = 0;
export const profileToggles = {
  user: new Map<string, Partial<Record<AutofillToggle, boolean>>>(),
  extension: new Map<string, Partial<Record<AutofillToggle, boolean>>>(),
  unloaded: new Set<string>(),
  unloadable: new Set<string>(),
};
const withProfile = (profile: string) => {
  if (profileToggles.unloadable.has(profile)) throw new Error("profile not loaded");
  profileToggles.unloaded.delete(profile);
};
const profileToggle = (profile: string, name: AutofillToggle) => {
  withProfile(profile);
  return profileToggles.extension.get(profile)?.[name] ?? profileToggles.user.get(profile)?.[name] ?? true;
};
const setProfileToggle = (profile: string, name: AutofillToggle, on: boolean | undefined) => {
  withProfile(profile);
  if (on !== undefined) profileToggles.user.set(profile, { ...profileToggles.user.get(profile), [name]: on });
};

const extensionEngine = () => testGlobals.acTestUserScripts?.engine;
function withStrips<Fake extends FakeDomain>(fake: Fake): Fake {
  const addListener = fake.addListener;
  fake.addListener = (name: string, listener: (payload: never) => void) => {
    const own = addListener(name, listener);
    const strips = tabStripHost().listen((tx) => (listener as (event: { name: string; data: unknown }) => void)({ name: "tabs.strips", data: tx }));
    return { remove: () => (own.remove(), strips.remove()) };
  };
  return fake;
}

const loginKey = (args: { origin: string; username: string }) => `${args.origin}\n${args.username}`;

const fakeModules = {
  ArdiaEngine: domain(
    "engine",
    {
      components: () => testGlobals.acTestComponents?.() ?? [],
      tasks: () => testGlobals.acTestTasks?.() ?? [],
      info: () => {
        const info = testGlobals.acTestEngineInfo?.();
        if (!info) throw Object.assign(new Error("engine.info has no test fake yet"), { code: "ERR_UNKNOWN_CALL" });
        return info;
      },
      beginTracing: () => false,
      endTracing: () => null,
      isTracing: () => false,
      systemState: () => ({ onBattery: false, batteryLevel: null, lowPowerMode: false, memoryPressure: "normal", physicalMemory: 16 * 2 ** 30 }),
      batterySaver: ({ mode }) => ({ state: 0, active: mode === "on" }),
      trimMemory: () => ({ ok: true }),
      openTaskManager: () => ({ ok: true }),
      cliControlStatus: () => cliControl(null),
      setCliControl: ({ on }) => cliControl(on),
      setCliActiveTab: ({ tabId }) => testGlobals.acTestCliActive?.(tabId) ?? cliStatus(null),
      cliOwnsTab: ({ tabId }) => testGlobals.acTestCliOwns?.(tabId) ?? { owned: false, shown: false },
      cliMoveOffscreen: ({ tabId }) => testGlobals.acTestCliMoveOffscreen?.(tabId) ?? { ok: false },
      cliCloseOffscreenTabs: () => null,
      cliTabTargets: ({ tabIds }) => Object.fromEntries(tabIds.map((id) => [id, testGlobals.acTestCliTargets?.(id) ?? { targetId: null, pageGeneration: 0 }])),
    },
    { inputIdleSeconds: () => 3600 },
  ),
  ArdiaTabs: withStrips(domain(
    "tabs",
    {
      routeLinkTabs: () => linkRoute.next,
      stripCommand: async ({ id, command }) => (await tabStripHost().command(command, id), null),
      strips: () => tabStripHost().snapshot(),
      lastTabPolicy: () => ({ closesWindow: true }),
    },
    {
      prepareTransfer: () => {},
      releaseTransfer: () => {},
      claimLaunchTab: () => {},
      revealTab: (key: string, press: number) => void revealedTabs.push(press ? `${key} by press ${press}` : key),
      dropTabReveals: (key: string, press: number) => void revealedTabs.push(press ? `drop over ${key} by press ${press}` : `drop over ${key}`),
      claimTabPress: (_key: string, startedAt: number) => nativeTabPresses.byStart.get(startedAt) ?? 0,
      dropTabPress: (press: number) => void nativeTabPresses.dropped.push(press),
      setTabsInSplits: (keys: string[]) => void nativeTabPresses.splits.push(keys),
      setNativeTabSwitch: (enabled: boolean) => void nativeTabSwitches.push(enabled),
      revealOffered: (adoptId: string, key: string, press: number) => void revealedTabs.push(press ? `${adoptId} over ${key} by press ${press}` : `${adoptId} over ${key}`),
      discardOffered: async (adoptId: string) => (discardedOffers.push(adoptId), true),
    },
  )),
  ArdiaWindows: domain("windows", { list: () => chromeWindowList, dev: () => "" }),
  ArdiaDownloads: domain("downloads", {
    cancel: ({ id }) => (cancelledDownloads.push(id), null),
    pause: () => null,
    resume: () => null,
    keep: () => null,
    settings: () => ({ folder: "", askWhereToSave: false, managed: false }),
    setSettings: (args) => (downloadSettingsWrites.push(args), { folder: "", askWhereToSave: false, managed: false }),
  }),
  ArdiaPermissions: domain("permissions", {
    resolve: ({ id, result, remember }) => (resolvedPermissions.push({ id, result, remember }), null),
    resolveExternalApp: () => null,
    externalAppAllowances: () => [],
    removeExternalAppAllowance: () => null,
  }),
  ArdiaProfiles: domain("profiles", {
    loaded: () => {
      if (!profilesLoadedCall.known) throw Object.assign(new Error("profiles.loaded isn't a call"), { code: "ERR_UNKNOWN_CALL" });
      return { profiles: [...loadedEngineProfiles] };
    },
    release: () => null,
    unloadIdle: ({ profile }) => {
      const { closing, ...unload } = idleProfileUnloads.get(profile) ?? { status: "busy" as const, tabs: [] };
      closing?.();
      if (unload.status !== "busy") loadedEngineProfiles.delete(profile);
      return unload;
    },
    deleteData: ({ profile }) => (deletedProfileData.push(profile), { remaining: profileDataLeft.get(profile) ?? [] }),
    clearBrowsingData: () => null,
  }),
  ArdiaSites: domain("sites", {
    settings: ({ profile, origin }) => siteSettingsOf(profile, origin) as SiteSettings,
    setSetting: ({ profile, origin, type, value }) => (siteSettingsDb.set(`${profile}\n${origin}`, { ...(siteSettingsDb.get(`${profile}\n${origin}`) ?? {}), [type]: value }), null),
    origins: ({ profile }) => [...siteSettingsDb.keys()].filter((k) => k.startsWith(`${profile}\n`)).map((k) => k.slice(profile.length + 1)),
    reset: ({ profile, origin }) => (siteSettingsDb.delete(`${profile}\n${origin}`), null),
    clearData: ({ profile, origin }) => (clearedSiteData.push({ profile, origin }), { cookies: 0, storage: true }),
    zoomLevels: ({ profile }) => Object.fromEntries([...siteZoomDb].filter(([k]) => k.startsWith(`${profile}\n`)).map(([k, v]) => [k.slice(profile.length + 1), v])),
    setZoom: ({ profile, host, zoom }) => (siteZoomDb.set(`${profile}\n${host}`, zoom), null),
    preloadPages: () => false,
    setPreloadPages: () => null,
  }),
  ArdiaPasswords: domain(
    "passwords",
    {
      list: () => ({
        passwords: [...(passwordStores.get(current.device)?.values() ?? [])].map((l) => ({ origin: l.url, username: l.username, created: l.created, modified: l.created })),
      }),
      unlock: () => ({ unlocked: true }),
      reveal: (args) => ({ password: passwordStores.get(current.device)?.get(loginKey(args))?.password ?? null }),
      remove: (args) => (logins().delete(loginKey(args)), { ok: true }),
      neverSaveOrigins: () => ({ origins: [] }),
      allowSaving: () => ({ ok: true }),
      export: () => ({ status: "cancelled" }),
      autofillEnabled: ({ profile }) => profileToggle(profile, "passwords"),
      setAutofillEnabled: ({ profile, enabled }) => {
        setProfileToggle(profile, "passwords", enabled);
        passwordProviders.calls.push(["offerToSave", profile, enabled]);
        return null;
      },
      ...providerFakes,
    },
    {
      save: async (_profile: string, origin: string, username: string, password: string) => {
        const refused = new Error("Could not save the password (invalid, or already saved)");
        if (!/^https?:\/\/[^/?#]+$/i.test(origin)) throw refused;
        const stored = new URL(origin).origin;
        const key = `${stored}\n${username}`;
        const existing = logins().get(key);
        if (existing && existing.password !== password) throw refused;
        if (!existing) logins().set(key, { origin: `${stored}/`, url: stored, username, password, created: Date.now() });
        return JSON.stringify({ ok: true });
      },
      update: async (_profile: string, origin: string, username: string, newUsername: string | null, newPassword: string | null) => {
        const entry = logins().get(`${origin}\n${username}`);
        if (!entry) throw new Error("No such password");
        const renamed = newUsername ?? username;
        logins().delete(`${origin}\n${username}`);
        logins().set(`${origin}\n${renamed}`, { ...entry, username: renamed, password: newPassword ?? entry.password });
        return JSON.stringify({ ok: true });
      },
    },
  ),
  ArdiaAutofill: domain(
    "autofill",
    {
      settings: ({ profile }) => ({ addresses: profileToggle(profile, "addresses"), cards: profileToggle(profile, "cards") }),
      setSettings: ({ profile, addresses, cards }) => {
        setProfileToggle(profile, "addresses", addresses);
        setProfileToggle(profile, "cards", cards);
        return null;
      },
      addresses: () => ({ addresses: [] }),
      saveAddress: () => ({ id: `address-${++autofillIds}` }),
      cards: () => ({ cards: [] }),
      remove: () => ({ ok: true }),
      cardNumber: () => ({ number: null }),
      showSuggestions: () => false,
    },
    { saveCard: async () => JSON.stringify({ id: `card-${++autofillIds}` }) },
  ),
  ArdiaExtensions: domain("extensions", {
    list: async ({ profile }) => ({ extensions: (await extensionEngine()?.list(profile)) ?? [] }),
    install: async ({ profile, path }) => {
      const engine = extensionEngine();
      if (!engine) throw Object.assign(new Error("no extension engine in this test"), { code: "ERR_ENGINE" });
      return { id: await engine.install(path, profile) };
    },
    setEnabled: async ({ id }) => (await extensionAnswers.change("setEnabled", id), { ok: true }),
    uninstall: async ({ profile, id }) => (await extensionAnswers.change("uninstall", id), await extensionEngine()?.uninstall(id, profile), { ok: true }),
    reload: async ({ profile, id }) => (await extensionAnswers.change("reload", id), await extensionEngine()?.reload(id, profile), { ok: true }),
    configure: async ({ profile, id, options }) => (await extensionAnswers.change("configure", id), await extensionEngine()?.configure?.(id, profile, options), { ok: true }),
    inspectUnpacked: ({ path }) => extensionEngine()?.inspect?.(path) ?? Promise.reject(Object.assign(new Error("Manifest file is missing or unreadable"), { code: "ERR_EXTENSION_INVALID" })),
    chooseFolder: () => chosenExtensionFolder.next,
    installCrx: ({ profile, path }) => {
      const failure = crxInstallFailure.next;
      crxInstallFailure.next = null;
      if (failure) throw new Error(failure);
      installedCrx.push({ path: path, profile });
      return { id: "crx" };
    },
    resolveInstallPrompt: ({ requestId, accepted, profile }) => extensionAnswers.resolveInstallPrompt(requestId, accepted, profile),
    actionStates: ({ tabId, ids, profile }) => extensionAnswers.actionStates(tabId, ids, profile),
    sidePanelUrl: ({ tabId, extensionId, profile }) => extensionAnswers.sidePanelUrl(tabId, extensionId, profile),
    watchActions: () => null,
    syncState: () => ({ ready: false, extensions: [], pending: [], settling: [], queued: [], intents: [] }),
    syncApply: () => ({ state: "pending" }),
  }),
  ArdiaSearch: domain("search", {
    engines: () => ({ list: { engines: [] } }),
    setEngineName: () => null,
    suggest: (args) => testGlobals.acTestSuggest?.(args) ?? { status: 200, body: JSON.stringify([args.url, []]) },
    stopSuggest: () => null,
  }),
  ArdiaMedia: domain("media", {
    displayMediaSources: () => [],
    selectDevice: () => null,
    cancelDeviceChooser: () => null,
    refreshDeviceChooser: () => null,
    openBluetoothSettings: () => null,
    showCastDialog: () => false,
    startCasting: () => null,
    stopCasting: () => null,
    closeCastDialog: () => null,
    watchCastRoutes: () => null,
    terminateCastRoute: () => null,
    changeCaptureSource: () => false,
    stopCapture: () => false,
  }),
  ArdiaContentBlocker: domain("contentBlocker", {
    setEnabled: () => null,
    setListEnabled: () => null,
    addList: ({ url }) => ({ id: url, custom: true, existed: false, filters: 1, failed: false }),
    removeList: () => null,
    isAllowed: () => false,
    setAllowed: () => null,
  }),
  ArdiaHistory: domain("history", {
    query: ({ profile, ...args }) => {
      const read = queryHistory(profile, args);
      return heldHistoryQueries.reply ? heldHistoryQueries.reply.then(() => read) : read;
    },
    add: ({ profile, ...args }) => addHistoryVisits(profile, args),
    import: ({ profile, ...args }) => importHistoryRows(profile, args),
    deleteUrls: ({ profile, ...args }) => deleteHistoryUrls(profile, args),
    watch: ({ profile }) => (historyWatches.push(profile), null),
  }),
  ArdiaBookmarks: domain("bookmarks", {
    tree: ({ profile }) => {
      if (bookmarkModel.treeFails) throw new Error("no bookmarks");
      if (bookmarkModel.treeHangs) return new Promise(() => {});
      bookmarkModel.loading.delete(profile);
      return { bar: treeOf(chromeBookmarks(profile), "bar"), other: treeOf(chromeBookmarks(profile), "other") };
    },
    apply: ({ profile, ...args }) => {
      if (bookmarkModel.loading.has(profile)) throw new Error("bookmarks.apply ran inside Chrome's bookmark model load");
      return applyBookmarkOps(profile, args);
    },
    watch: () => null,
  }),
  ArdiaFavicons: domain("favicons", {
    get: ({ profile, ...args }) => faviconsFor(profile, args),
    set: () => ({ stored: true }),
    fetch: () => null,
  }),
  ArdiaWebView: domain("webView", {
    setDisplayMediaPicker: () => null,
    setPeekModifier: () => null,
    setSplitLinkModifier: () => null,
    setPeekOtherSiteTabs: () => null,
    setSelectionPopover: () => null,
    setBlockAutoplayEverywhere: () => null,
    setCommandScrollZoom: () => null,
    setLittleArdiaOpensNewTabLinks: () => null,
    setPopupsOpenAsTabs: () => null,
    setAutoPictureInPicture: () => null,
    setVideoUpscaling: () => null,
    setVideoUpscalingTestConditions: () => null,
    videoUpscalingState: () => null,
    takeContentDrift: () => ({ layouts: 0, fits: 0, maxPoints: 0 }),
    takeFirstPaintHolds: () => ({ held: 0, painted: 0, loaded: 0, pressed: 0, timedOut: 0, heldMs: 0 }),
  }),
  ArdiaWebKit: domain("webKit", {
    endPrivateSession: ({ session }) => (endedWebKitSessions.push(session), null),
    removeDownloadStaging: ({ path }) => (removedStagings.push(path), stagingRemovals.ok),
    cookieStoreKey: ({ profile }) => profile,
    importCookies: ({ cookies }) => cookies.length,
    passkeyAccess: () => ({ entitled: false, status: "entitlementRequired" }),
    requestPasskeyAccess: () => ({ entitled: false, status: "entitlementRequired" }),
  }),
  ArdiaSwipe: {
    haptic: () => {},
    switchPager: () => Promise.resolve(false),
    stepPager: () => Promise.resolve(false),
    selectPager: () => Promise.resolve(false),
    pagerState: () => null,
    devPagerState: () => Promise.resolve(null),
    devSimulate: () => unfaked("ArdiaSwipe", "devSimulate"),
  },
};

export const ardiaCoreNativeModules: Record<string, object> = fakeModules;
