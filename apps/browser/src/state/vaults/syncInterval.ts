import type { VAULT_SYNC_INTERVALS } from "../settings/settings";

export type VaultSyncInterval = (typeof VAULT_SYNC_INTERVALS)[number];

const SECONDS: Record<VaultSyncInterval, number | null> = { automatic: null, every5Minutes: 300, every15Minutes: 900, everyHour: 3600, manual: 0 };

export const vaultSyncSeconds = (interval: VaultSyncInterval) => SECONDS[interval];
