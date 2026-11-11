import { onGoogleImport, revealGooglePage, type VaultGoogleImport } from "../../platform/vaults";
import { showToast, type ToastOptions } from "../app/toasts";
import { useBrowser } from "../browser/store";
import { requestGooglePasswordSheet } from "./google";
import { loadVaultItems } from "./store";

type Told = "saved" | "confirm" | null;
type Tracked = { tabId: string; seq: number; windowId: string | null; told: Told };
type OfferHooks = {
  saved: (tabId: string, seq: number) => boolean;
  failed: (tabId: string, seq: number, error: string, action?: "updatePassword") => boolean;
  confirm: (tabId: string, seq: number, importId: string) => boolean;
};

export const GOOGLE_SAVED_TITLE = "Saved to Google";
export const GOOGLE_CONFIRM_TEXT = "Google needs you to confirm";
export const GOOGLE_FAILED_TITLE = "Couldn't Save to Google";
export const GOOGLE_FAILED_TEXT = "Couldn't save to Google. Try again.";

const EARLY_KEPT = 20;
const SAVED_ICON = "checkmark.circle.fill";
const WARNING_ICON = "exclamationmark.triangle.fill";

const tracked = new Map<string, Tracked>();
const early = new Map<string, VaultGoogleImport>();
let hooks: OfferHooks | null = null;

export const setGoogleImportOfferHooks = (next: OfferHooks) => void (hooks = next);
export const pendingGoogleImport = (id: string) => tracked.get(id) ?? null;

const windowOf = (tabId: string) => useBrowser.getState().tabs[tabId]?.windowId ?? null;
const toastKey = (id: string) => `googleImport:${id}`;

function tell(id: string, t: Tracked, title: string, message: string | undefined, options: ToastOptions) {
  if (t.windowId) showToast(t.windowId, title, message, { key: toastKey(id), ...options });
}

function track(id: string, tabId: string, seq: number, told: Told) {
  const t: Tracked = { tabId, seq, windowId: windowOf(tabId), told };
  tracked.set(id, t);
  return t;
}

function catchUp(id: string) {
  const event = early.get(id);
  if (!event) return;
  early.delete(id);
  applyGoogleImport(event);
}

export function noteGoogleImportWaiting(id: string, tabId: string, seq: number) {
  track(id, tabId, seq, null);
  catchUp(id);
}

export function noteGoogleImportSaved(id: string, tabId: string, seq: number) {
  const t = track(id, tabId, seq, "saved");
  tell(id, t, GOOGLE_SAVED_TITLE, undefined, { icon: SAVED_ICON });
  catchUp(id);
}

function keepEarly(event: VaultGoogleImport) {
  early.set(event.id, event);
  if (early.size > EARLY_KEPT) early.delete(early.keys().next().value!);
}

export function applyGoogleImport(event: VaultGoogleImport) {
  const t = tracked.get(event.id);
  if (!t) return keepEarly(event);
  if (event.state === "confirm") {
    if (hooks?.confirm(t.tabId, t.seq, event.id) || t.told === "confirm") return;
    t.told = "confirm";
    return tell(event.id, t, GOOGLE_CONFIRM_TEXT, undefined, { icon: WARNING_ICON, action: { title: "Confirm…", run: () => void revealGooglePage(event.id).catch(() => false) } });
  }
  tracked.delete(event.id);
  void loadVaultItems(event.provider, true);
  if (event.state === "saved") {
    hooks?.saved(t.tabId, t.seq);
    if (t.told !== "saved") tell(event.id, t, GOOGLE_SAVED_TITLE, undefined, { icon: SAVED_ICON });
    return;
  }
  if (event.code === "cancelled") return void hooks?.failed(t.tabId, t.seq, "", undefined);
  const error = event.message || GOOGLE_FAILED_TEXT;
  const updatePassword = event.code === "wrongPassword" || event.code === "noPassword";
  if (hooks?.failed(t.tabId, t.seq, error, updatePassword ? "updatePassword" : undefined)) return;
  tell(event.id, t, GOOGLE_FAILED_TITLE, error, { icon: WARNING_ICON, ...(updatePassword ? { action: { title: "Update Password…", run: requestGooglePasswordSheet } } : {}) });
}

let started = false;

export function startGoogleImports() {
  if (started) return;
  started = true;
  onGoogleImport(applyGoogleImport);
}
