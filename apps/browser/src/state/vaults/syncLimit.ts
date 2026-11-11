import type { VaultProviderState } from "../../platform/vaults";
import { confirm } from "../app/system";
import { vaultProviderOf } from "./store";
import { syncVault } from "./sync";

export const syncAgainAt = (provider: Pick<VaultProviderState, "syncAgainAt"> | undefined, now = Date.now()) =>
  provider?.syncAgainAt && provider.syncAgainAt > now ? provider.syncAgainAt : undefined;

export const minutesUntil = (at: number, now = Date.now()) => Math.max(1, Math.ceil((at - now) / 60_000));

export const syncLimitAlert = (at: number, now = Date.now()): Parameters<typeof confirm>[0] => {
  const minutes = minutesUntil(at, now);
  return {
    title: `Sync Again in ${minutes} ${minutes === 1 ? "Minute" : "Minutes"}`,
    message: "Frequent syncs can sign you out of Google.",
    confirmTitle: "Sync Anyway",
    cancelTitle: "Cancel",
    cancelIsDefault: true,
    warning: true,
  };
};

export const FULL_SYNC_TITLE = "Full Sync";

export const offersFullSync = (provider: Pick<VaultProviderState, "state" | "source">) => provider.state === "unlocked" && provider.source === "web";

export async function fullSyncAsking(id: string) {
  const at = syncAgainAt(vaultProviderOf(id));
  if (!at) return syncVault(id, { download: true });
  const { confirmed } = await confirm(syncLimitAlert(at));
  if (confirmed) await syncVault(id, { anyway: true });
}
