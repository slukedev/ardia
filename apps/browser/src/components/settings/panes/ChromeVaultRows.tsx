import { useEffect, useState } from "react";
import { View } from "react-native";
import { refreshProvider, type VaultProviderState } from "../../../state/vaults/actions";
import { chooseChromeProfile, chosenChromeProfile, isChromeVault, chromeProfileOptions, loadChromeProfiles, useChromeProfiles } from "../../../state/vaults/google";
import { Button, PopUp } from "../../ui";
import { VAULT_SETTINGS } from "../../vaults/tokens";
import { Row } from "../Form";
import { showGoogleSaveSheet } from "./PasswordManagerSheets";

export function ChromeSetupButton({ provider }: { provider: VaultProviderState }) {
  const [trying, setTrying] = useState(false);
  const retry = async () => {
    setTrying(true);
    await refreshProvider(provider.id);
    setTrying(false);
  };
  if (provider.state === "notInstalled" || provider.state === "signedOut") return <Button title="Connect…" onPress={() => showGoogleSaveSheet(provider.id)} />;
  if (provider.state === "unavailable") return <Button title="Try Again" disabled={trying} onPress={() => void retry()} />;
  return null;
}

export function useChoosesChromeProfile(providers: readonly VaultProviderState[]) {
  const profiles = useChromeProfiles();
  const chrome = providers.filter(isChromeVault);
  const watched = chrome.map((p) => `${p.id}:${p.state}:${p.server ?? ""}`).join(",");
  useEffect(() => {
    for (const p of chrome) if (p.state === "unlocked") void loadChromeProfiles(p.id);
  }, [watched]);
  return (p: VaultProviderState) => isChromeVault(p) && p.state === "unlocked" && (profiles[p.id]?.length ?? 0) > 1;
}

export function ChromeProfileRow({ provider }: { provider: VaultProviderState }) {
  const profiles = useChromeProfiles((s) => s[provider.id]) ?? [];
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const options = chromeProfileOptions(profiles);
  const chosen = chosenChromeProfile(profiles, provider) ?? options[0]?.value ?? "";
  const choose = async (directory: string) => {
    setBusy(true);
    setError("");
    setError(await chooseChromeProfile(provider.id, directory));
    setBusy(false);
  };
  return (
    <Row icon={<View style={INDENT} />} title="Chrome Profile" description={error || undefined}>
      <PopUp value={chosen} options={options} disabled={busy} onChange={(v) => void choose(v)} />
    </Row>
  );
}

const INDENT = { width: VAULT_SETTINGS.brandTile } as const;
