import type { VaultProviderState } from "../../platform/vaults";
import { confirm } from "../app/system";
import { clockTime } from "./google";
import { currentVaultProviders, vaultProviderOf } from "./store";
import { syncEveryVault, syncVault } from "./sync";

export const syncAgainAt = (provider: Pick<VaultProviderState, "syncAgainAt"> | undefined, now = Date.now()) =>
  provider?.syncAgainAt && provider.syncAgainAt > now ? provider.syncAgainAt : undefined;

export const syncLimitAlert = (name: string, at: number): Parameters<typeof confirm>[0] => ({
  title: `${name} Synced Recently`,
  message: `You can sync again at ${clockTime(at)}. Ardia reads your passwords from passwords.google.com at most once an hour, because syncing more often can make Google ask for your password again, show a security check or pause password exports on your account for a while.`,
  confirmTitle: "Sync Anyway",
  cancelTitle: "Cancel",
});

async function askToSyncAnyway(provider: VaultProviderState, at: number) {
  const { confirmed } = await confirm(syncLimitAlert(provider.name, at));
  if (confirmed) await syncVault(provider.id, { anyway: true });
}

export async function syncVaultAsking(id: string) {
  const provider = vaultProviderOf(id);
  const at = syncAgainAt(provider);
  if (!provider || !at) return syncVault(id);
  await askToSyncAnyway(provider, at);
}

export async function syncEveryVaultAsking() {
  const limited = currentVaultProviders().flatMap((p) => {
    const at = p.state === "unlocked" ? syncAgainAt(p) : undefined;
    return at ? [{ provider: p, at }] : [];
  });
  const rest = syncEveryVault(limited.map((l) => l.provider.id));
  for (const { provider, at } of limited) await askToSyncAnyway(provider, at);
  await rest;
}
