import { create } from "zustand";
import { refreshVault } from "../../platform/vaults";
import { applyProviderState, currentVaultProviders, loadVaultItems, useVaults, vaultProviderOf } from "./store";

export type VaultSyncStatus = "syncing" | "synced";

const SYNCED_SHOWN_MS = 2000;
const NATIVE_SYNC_LIMIT_MS = 120_000;

export const EVERY_VAULT = "*";

export const useVaultSync = create<Record<string, VaultSyncStatus>>()(() => ({}));

export const syncStatusOf = (nativeSyncing: boolean, pressed: VaultSyncStatus | null | undefined): VaultSyncStatus | null =>
  nativeSyncing || pressed === "syncing" ? "syncing" : (pressed ?? null);

const clearing = new Map<string, ReturnType<typeof setTimeout>>();

function mark(key: string, status: VaultSyncStatus | null) {
  clearTimeout(clearing.get(key));
  clearing.delete(key);
  useVaultSync.setState((s) => {
    const { [key]: _old, ...rest } = s;
    return status ? { ...rest, [key]: status } : rest;
  }, true);
  if (status !== "synced") return;
  clearing.set(key, setTimeout(() => mark(key, null), SYNCED_SHOWN_MS));
}

export function nativeSyncSettled(provider: string, limit = NATIVE_SYNC_LIMIT_MS): Promise<void> {
  const syncingNow = () => !!vaultProviderOf(provider)?.syncing;
  if (!syncingNow()) return Promise.resolve();
  return new Promise((resolve) => {
    let stop = () => {};
    const timer = setTimeout(() => finish(), limit);
    const finish = () => {
      clearTimeout(timer);
      stop();
      resolve();
    };
    stop = useVaults.subscribe(() => !syncingNow() && finish());
  });
}

async function syncOne(provider: string) {
  try {
    applyProviderState(await refreshVault(provider));
    await nativeSyncSettled(provider);
    await loadVaultItems(provider, true);
    const state = vaultProviderOf(provider);
    return state?.state === "unlocked" && !state.hold;
  } catch {
    return false;
  }
}

export async function syncVault(provider: string) {
  if (useVaultSync.getState()[provider] === "syncing") return;
  mark(provider, "syncing");
  mark(provider, (await syncOne(provider)) ? "synced" : null);
}

export async function syncEveryVault() {
  if (useVaultSync.getState()[EVERY_VAULT] === "syncing") return;
  const unlocked = currentVaultProviders().filter((p) => p.state === "unlocked").map((p) => p.id);
  if (!unlocked.length) return;
  mark(EVERY_VAULT, "syncing");
  const results = await Promise.all(unlocked.map(syncOne));
  mark(EVERY_VAULT, results.some(Boolean) ? "synced" : null);
}
