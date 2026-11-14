import { listExtensions, onExtensionsChanged, type InstalledExtension } from "../../platform/extensions";
import {
  onWebKitCount,
  onWebKitExtensionCall,
  onWebKitExtensionListeners,
  onWebKitExtensionsWanted,
  replyToWebKitExtension,
  syncWebKitExtensions,
  type WebKitExtension,
  type WebKitExtensionCall,
} from "../../platform/webkit";
import { noteWebKitCount, noteWebKitExtensions } from "../telemetry/engineSwitchCounts";
import { answerExtensionCall } from "./webKitExtensionApis";
import { noteExtensionListeners } from "./webKitExtensionEvents";

const signatures = new Map<string, string>();
const running = new Map<string, Promise<void>>();
const again = new Set<string>();
let listening = false;

export function forWebKit(list: readonly InstalledExtension[]): WebKitExtension[] {
  return list
    .filter((x) => x.enabled && x.state === "ENABLED" && !x.blockedByPolicy)
    .map((x) => ({
      id: x.id,
      path: x.path,
      version: x.version,
      name: x.name,
      sites: x.siteAccess === "ON_SPECIFIC_SITES" ? [...x.sites].sort() : [],
      allSites: x.siteAccess === "ON_ALL_SITES" || x.siteAccess === null,
      incognito: x.incognito,
    }))
    .sort((a, b) => a.id.localeCompare(b.id));
}

async function pass(profile: string) {
  const extensions = forWebKit(await listExtensions(profile));
  const signature = JSON.stringify(extensions);
  if (signatures.get(profile) === signature) return;
  const result = await syncWebKitExtensions(profile, extensions);
  signatures.set(profile, signature);
  if (result.available) noteWebKitExtensions(result.loaded.length, result.failed.length);
}

export function syncExtensionsToWebKit(profile: string): Promise<void> {
  listen();
  const current = running.get(profile);
  if (current) {
    again.add(profile);
    return current;
  }
  const run = pass(profile)
    .catch(() => {})
    .finally(() => {
      running.delete(profile);
      if (again.delete(profile)) void syncExtensionsToWebKit(profile);
    });
  running.set(profile, run);
  return run;
}

export async function answerWebKitExtension(call: WebKitExtensionCall) {
  const reply = await answerExtensionCall(call);
  await replyToWebKitExtension(call.id, reply).catch(() => {});
}

function listen() {
  if (listening) return;
  listening = true;
  onExtensionsChanged(({ profile }) => {
    if (signatures.has(profile)) void syncExtensionsToWebKit(profile);
  });
  onWebKitCount(({ name }) => noteWebKitCount(name));
  onWebKitExtensionCall((call) => void answerWebKitExtension(call));
  onWebKitExtensionListeners(noteExtensionListeners);
  onWebKitExtensionsWanted(({ profile }) => {
    signatures.delete(profile);
    void syncExtensionsToWebKit(profile);
  });
}

listen();
