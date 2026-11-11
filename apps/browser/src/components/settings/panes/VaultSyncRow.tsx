import { useSettings } from "../../../state/browser/hooks";
import { updateSettings } from "../../../state/settings/actions";
import type { VAULT_SYNC_INTERVALS } from "../../../state/settings/settings";
import { useEveryVaultSyncStatus, useVaultProviders } from "../../../state/vaults/hooks";
import { syncEveryVaultAsking } from "../../../state/vaults/syncLimit";
import { Box, Button, PopUp } from "../../ui";
import { VaultSyncStatus } from "../../vaults/VaultParts";
import { Row } from "../Form";

type Interval = (typeof VAULT_SYNC_INTERVALS)[number];

const SYNC_OPTIONS: { value: Interval; title: string }[] = [
  { value: "automatic", title: "Automatically" },
  { value: "every5Minutes", title: "Every 5 Minutes" },
  { value: "every15Minutes", title: "Every 15 Minutes" },
  { value: "everyHour", title: "Every Hour" },
  { value: "manual", title: "Manually" },
];

export function VaultSyncRow() {
  const interval = useSettings((s) => s.vaultSyncInterval);
  const anyUnlocked = useVaultProviders().some((p) => p.state === "unlocked");
  const status = useEveryVaultSyncStatus();
  return (
    <Row anchor="passwords.vaultSyncInterval">
      <Box row gap="s" center>
        <VaultSyncStatus status={status} />
        {anyUnlocked ? <Button title="Sync Now" disabled={status === "syncing"} onPress={() => void syncEveryVaultAsking()} /> : null}
        <PopUp value={interval} options={SYNC_OPTIONS} onChange={(v) => updateSettings({ vaultSyncInterval: v })} />
      </Box>
    </Row>
  );
}
