import { useEffect, useState } from "react";
import { View } from "react-native";
import { confirm, showMenu } from "../../../state/app/system";
import { useSettings } from "../../../state/browser/hooks";
import { updateSettings } from "../../../state/settings/actions";
import { VAULT_LOCK_MINUTES } from "../../../state/settings/settings";
import { lockProvider, refreshProvider, reloadProviders, signInError, signOutProvider, unlockProvider, type VaultProviderState } from "../../../state/vaults/actions";
import { chromeStatusLine, googleUpdateFailed, forgetGoogleAccountPassword, isChromeVault, loadGoogleAccount, useGoogleAccount } from "../../../state/vaults/google";
import { useVaultProviders, useVaultsLoaded, useVaultSyncStatus, useVaultUnlocking } from "../../../state/vaults/hooks";
import { syncVault } from "../../../state/vaults/sync";
import { syncVaultAsking } from "../../../state/vaults/syncLimit";
import { Box, Button, PopUp, space } from "../../ui";
import { BrandBadge, VaultSyncStatus } from "../../vaults/VaultParts";
import { VAULT_SETTINGS } from "../../vaults/tokens";
import { Group, Row, SectionHeader, SettingToggle } from "../Form";
import { ChromeProfileRow, ChromeSetupButton, useChoosesChromeProfile } from "./ChromeVaultRows";
import { showConnectSheet, showGoogleSaveSheet, showUnlockSheet } from "./PasswordManagerSheets";
import { VaultSyncRow } from "./VaultSyncRow";

const LOCK_TITLES: Record<(typeof VAULT_LOCK_MINUTES)[number], string> = { 5: "5 Minutes", 15: "15 Minutes", 30: "30 Minutes", 60: "1 Hour", 0: "Never" };
const LOCK_OPTIONS = VAULT_LOCK_MINUTES.map((m) => ({ value: String(m), title: LOCK_TITLES[m] }));
const ASK = "ask";

const MINUTE_MS = 60_000;

function useMinuteTick(on: boolean) {
  const [now, setNow] = useState(Date.now);
  useEffect(() => {
    if (!on) return;
    const timer = setInterval(() => setNow(Date.now()), MINUTE_MS);
    return () => clearInterval(timer);
  }, [on]);
  return now;
}

function stateLine(p: VaultProviderState, now: number): string | undefined {
  if (isChromeVault(p)) return chromeStatusLine(p, now);
  const account = [p.account, p.server && p.capabilities.selfHosted ? p.server.replace(/^https?:\/\//, "") : null].filter(Boolean).join(" · ");
  const status = p.state === "locked" ? "Locked" : p.state === "notInstalled" ? "Not installed" : p.state === "unavailable" ? p.message || "Not available" : p.state === "signedOut" ? "Not connected" : "";
  return [account, status].filter(Boolean).join(" · ") || undefined;
}

function ProviderRow({ provider }: { provider: VaultProviderState }) {
  const busy = useVaultUnlocking(provider.id);
  const sync = useVaultSyncStatus(provider.id);
  const syncing = sync === "syncing";
  const chrome = isChromeVault(provider);
  const now = useMinuteTick(chrome && provider.state === "unlocked");
  const [error, setError] = useState("");
  useEffect(() => setError(""), [provider.state]);
  const unlock = async () => {
    setError("");
    const result = await unlockProvider(provider.id, null);
    if (result.needs === "password") return showUnlockSheet(provider.id);
    if (!result.ok) return setError(signInError(result, provider.name));
    if (chrome && !(await loadGoogleAccount())?.hasPassword) showGoogleSaveSheet(provider.id);
  };
  const googlePassword = useGoogleAccount((s) => s.hasPassword);
  const leave = chrome
    ? { menu: "Disconnect…", title: `Disconnect ${provider.name}?`, message: "Ardia stops filling from it and forgets your Google password. Your Google Account stays signed in.", confirm: "Disconnect" }
    : { menu: "Sign Out…", title: `Sign out of ${provider.name}?`, message: "Ardia stops filling from it until you connect again.", confirm: "Sign Out" };
  const more = async () => {
    const choice = await showMenu([
      ...(provider.state === "unlocked" ? [{ id: "lock", title: "Lock", symbol: "lock" }] : []),
      provider.state === "unlocked" ? { id: "sync", title: "Sync Now", symbol: "arrow.triangle.2.circlepath", enabled: !syncing } : { id: "refresh", title: "Refresh", symbol: "arrow.clockwise" },
      ...(chrome
        ? [
            { separator: true as const },
            { id: "googlePassword", title: googlePassword ? "Update Google Password…" : "Save Google Password…", symbol: "key" },
            ...(googlePassword ? [{ id: "forgetGooglePassword", title: "Forget Google Password", symbol: "trash" }] : []),
          ]
        : []),
      { separator: true },
      { id: "signOut", title: leave.menu, symbol: "rectangle.portrait.and.arrow.right" },
    ]);
    if (choice === "googlePassword") return showGoogleSaveSheet(provider.id);
    if (choice === "forgetGooglePassword") return void forgetGoogleAccountPassword();
    if (choice === "lock") await lockProvider(provider.id);
    if (choice === "refresh") await refreshProvider(provider.id);
    if (choice === "sync") void syncVaultAsking(provider.id);
    if (choice !== "signOut") return;
    const { confirmed } = await confirm({ title: leave.title, message: leave.message, confirmTitle: leave.confirm });
    if (confirmed) await signOutProvider(provider.id);
  };
  const connected = provider.state === "unlocked" || provider.state === "locked";
  return (
    <Row
      icon={<BrandBadge provider={provider.id} box={VAULT_SETTINGS.brandTile} glyph={VAULT_SETTINGS.brandGlyph} />}
      title={provider.name}
      description={error || stateLine(provider, now)}
    >
      <Box row gap="s" center>
        <VaultSyncStatus status={sync} />
        {provider.state === "locked" ? <Button title={busy ? "Unlocking…" : "Unlock"} disabled={busy} onPress={() => void unlock()} /> : null}
        {provider.state === "unlocked" && provider.hold && !syncing ? <Button title="Confirm…" onPress={() => void syncVault(provider.id, { anyway: true })} /> : null}
        {chrome && googleUpdateFailed(provider) && !syncing ? <Button title="Try Again" tooltip={provider.message} onPress={() => void syncVaultAsking(provider.id)} /> : null}
        {connected ? (
          <Button variant="icon" icon="ellipsis.circle" size="l" tooltip="More" onPress={() => void more()} />
        ) : chrome ? (
          <ChromeSetupButton provider={provider} />
        ) : (
          <Button title="Connect…" onPress={() => showConnectSheet(provider.id)} />
        )}
      </Box>
    </Row>
  );
}

export function PasswordManagersSection() {
  const providers = useVaultProviders();
  const loaded = useVaultsLoaded();
  const choosesProfile = useChoosesChromeProfile(providers);
  const saveTarget = useSettings((s) => s.vaultSaveTarget);
  const lockAfter = useSettings((s) => s.vaultIdleLockMinutes);
  const googleSheetRequest = useGoogleAccount((s) => s.sheetRequest);
  useEffect(() => void reloadProviders(), []);
  useEffect(() => void loadGoogleAccount(), []);
  useEffect(() => {
    if (googleSheetRequest) showGoogleSaveSheet("google");
  }, [googleSheetRequest]);
  const savers = providers.filter((p) => p.capabilities.save);
  const targetOptions = [{ value: ASK, title: "Ask Each Time" }, ...savers.map((p) => ({ value: p.id, title: p.name }))];
  const target = savers.some((p) => p.id === saveTarget) ? saveTarget : ASK;
  return (
    <View>
      <SectionHeader anchor="passwords.managers" description={null} />
      <Group>
        {providers.length ? null : <Row title={loaded ? "No password managers" : "…"} />}
        {providers.flatMap((p) => [<ProviderRow key={p.id} provider={p} />, ...(choosesProfile(p) ? [<ChromeProfileRow key={`${p.id}.profile`} provider={p} />] : [])])}
      </Group>
      <View style={GROUP_GAP}>
        <Group>
          <SettingToggle anchor="passwords.vaultSuggestOnFocus" />
          <SettingToggle anchor="passwords.vaultAskBeforeFilling" />
          <SettingToggle anchor="passwords.vaultLoadPasswordsWhenUsed" />
          <VaultSyncRow />
          <SettingToggle anchor="passwords.vaultMenuGlass" />
          <SettingToggle anchor="passwords.vaultSaveOffer" />
          <Row anchor="passwords.vaultSaveTarget">
            <PopUp value={target} options={targetOptions} onChange={(v) => updateSettings({ vaultSaveTarget: v === ASK ? "" : v })} />
          </Row>
          <Row anchor="passwords.vaultIdleLockMinutes">
            <PopUp value={String(lockAfter)} options={LOCK_OPTIONS} onChange={(v) => updateSettings({ vaultIdleLockMinutes: Number(v) })} />
          </Row>
        </Group>
      </View>
    </View>
  );
}

const GROUP_GAP = { marginTop: space.l } as const;
