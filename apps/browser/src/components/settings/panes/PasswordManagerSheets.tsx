import { useEffect, useRef, useState, type ReactNode } from "react";
import { View } from "react-native";
import { closeSettingsSheet, showSettingsSheet } from "../../../state/settings/sheet";
import {
  cancelProviderSignIn,
  copyInstallCommand,
  installCommandOf,
  openApprovalPage,
  openProviderApp,
  refreshProvider,
  signInError,
  signInProvider,
  unlockProvider,
  type VaultProviderState,
} from "../../../state/vaults/actions";
import {
  checkGoogleSignInState,
  GOOGLE_SIGN_IN_TEXT,
  isChromeVault,
  saveGoogleAccountPassword,
  showGoogleSignIn,
  useGoogleAccount,
  watchGoogleSignIn,
  type GoogleSignInState,
} from "../../../state/vaults/google";
import { useVaultProvider } from "../../../state/vaults/hooks";
import { useSettings } from "../../../state/browser/hooks";
import { updateSettings } from "../../../state/settings/actions";
import { ActivitySpinner, Box, Button, DialogActions, DialogTitle, proseLineHeight, Sheet, space, Text, TextField, Toggle } from "../../ui";
import { useTheme } from "../../ui/theme";
import { BrandBadge } from "../../vaults/VaultParts";
import { VAULT_SETTINGS } from "../../vaults/tokens";
import { FormField, Group, Row } from "../Form";
import { BitwardenSheet } from "./BitwardenSheet";
import { SheetError, SheetHead, SheetText, TouchIdRow, Waiting } from "../../vaults/VaultSheetParts";

export const showConnectSheet = (provider: string) => showSettingsSheet(<ConnectSheet provider={provider} />);
export const showUnlockSheet = (provider: string) => showSettingsSheet(<UnlockSheet provider={provider} />);
export const showGoogleSaveSheet = (provider: string) => showSettingsSheet(<GoogleSaveSheet provider={provider} />);

function useCloseWhenUnlocked(provider: VaultProviderState | undefined) {
  const was = useRef(provider?.state);
  useEffect(() => {
    if (provider?.state === "unlocked" && was.current !== "unlocked") closeSettingsSheet();
    was.current = provider?.state;
  }, [provider?.state]);
}

function ConnectSheet({ provider: id }: { provider: string }) {
  const provider = useVaultProvider(id);
  useCloseWhenUnlocked(provider);
  if (!provider) return null;
  if (isChromeVault(provider)) return <GoogleSaveSheet provider={provider.id} />;
  if (provider.state === "notInstalled") return <InstallSheet provider={provider} />;
  switch (provider.setup?.kind) {
    case "desktopIntegration":
      return <OnePasswordSheet provider={provider} />;
    case "browserSignIn":
      return <ProtonPassSheet provider={provider} />;
    default:
      return <BitwardenSheet provider={provider} />;
  }
}

function CommandBox({ command }: { command: string }) {
  const theme = useTheme();
  const [copied, setCopied] = useState(false);
  useEffect(() => {
    if (!copied) return;
    const timer = setTimeout(() => setCopied(false), VAULT_SETTINGS.copiedMs);
    return () => clearTimeout(timer);
  }, [copied]);
  return (
    <Box row gap="m" center radius="tile" padX="ml" style={[COMMAND, { backgroundColor: theme.field, borderColor: theme.fieldBorder }]}>
      <Text selectable lines={1} style={MONO}>
        {command}
      </Text>
      <Button
        variant="text"
        plate="hover"
        title={copied ? "Copied" : "Copy"}
        onPress={() => {
          copyInstallCommand(command);
          setCopied(true);
        }}
      />
    </Box>
  );
}

function InstallSheet({ provider }: { provider: VaultProviderState }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const check = async () => {
    setBusy(true);
    setError("");
    const state = await refreshProvider(provider.id);
    setBusy(false);
    if (!state || state.state === "notInstalled") setError(`${provider.name} isn't installed yet. Run the command, then check again.`);
  };
  return (
    <Sheet onClose={closeSettingsSheet}>
      <SheetHead provider={provider.id} title={`Connect ${provider.name}`} />
      <SheetText>Run in Terminal:</SheetText>
      <CommandBox command={installCommandOf(provider)} />
      <SheetError text={error} />
      <DialogActions leading={provider.install?.url ? <Button title="Download…" onPress={() => openProviderApp(provider.install.url)} /> : undefined}>
        <Button title="Cancel" onPress={closeSettingsSheet} />
        <Button title={busy ? "Checking…" : "Check Again"} kind="primary" disabled={busy} onPress={() => void check()} />
      </DialogActions>
    </Sheet>
  );
}

function OnePasswordSheet({ provider }: { provider: VaultProviderState }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const proceed = async () => {
    setBusy(true);
    setError("");
    const result = await unlockProvider(provider.id, null);
    setBusy(false);
    if (result.ok) return closeSettingsSheet();
    setError(signInError(result, provider.name));
  };
  return (
    <Sheet onClose={closeSettingsSheet}>
      <SheetHead provider={provider.id} title={`Connect ${provider.name}`} />
      <SheetText>In 1Password, open Settings › Developer and turn this on:</SheetText>
      <View style={GAP_TOP}>
        <Group>
          <Row title="Integrate with 1Password CLI">
            <Toggle value onChange={() => {}} disabled />
          </Row>
        </Group>
      </View>
      {busy ? <Waiting text={`Approve in ${provider.name}…`} /> : <SheetError text={error} />}
      <DialogActions leading={provider.setup?.appURL ? <Button title="Open 1Password" onPress={() => openProviderApp(provider.setup!.appURL!)} /> : undefined}>
        <Button title="Cancel" onPress={closeSettingsSheet} />
        <Button title="Continue" kind="primary" disabled={busy} onPress={() => void proceed()} />
      </DialogActions>
    </Sheet>
  );
}

function ProtonPassSheet({ provider }: { provider: VaultProviderState }) {
  const [mode, setMode] = useState<"browser" | "token">("browser");
  const [token, setToken] = useState("");
  const [busy, setBusy] = useState(false);
  const [waiting, setWaiting] = useState(false);
  const [error, setError] = useState("");
  const begin = async () => {
    setBusy(true);
    setError("");
    const result = await signInProvider(provider.id, {});
    setBusy(false);
    if (result.ok) return closeSettingsSheet();
    if (result.needs === "approval" && result.approvalURL) {
      openApprovalPage(result.approvalURL);
      return setWaiting(true);
    }
    setError(signInError(result, provider.name));
  };
  const cancel = () => {
    if (waiting) void cancelProviderSignIn(provider.id);
    closeSettingsSheet();
  };
  const withToken = async () => {
    setBusy(true);
    setError("");
    const result = await signInProvider(provider.id, { method: "accessToken", clientSecret: token.trim() });
    setToken("");
    setBusy(false);
    if (result.ok) return closeSettingsSheet();
    setError(signInError(result, provider.name));
  };
  return (
    <Sheet onClose={cancel}>
      <SheetHead provider={provider.id} title={`Connect ${provider.name}`} />
      {mode === "token" ? (
        <FormField label="Access Token">
          <TextField value={token} onChangeText={setToken} secure autoFocus width="100%" onSubmit={() => token.trim() && void withToken()} />
        </FormField>
      ) : waiting ? (
        <Waiting text="Waiting for you to sign in to Proton…" />
      ) : (
        <SheetText>Sign in to Proton in a new tab, then come back here.</SheetText>
      )}
      {waiting ? null : <SheetError text={error || (provider.state === "locked" ? provider.message ?? "" : "")} />}
      <DialogActions
        leading={waiting ? undefined : <Button title={mode === "token" ? "Use Browser" : "Use Access Token"} kind="plain" onPress={() => (setError(""), setMode(mode === "token" ? "browser" : "token"))} />}
      >
        <Button title="Cancel" onPress={cancel} />
        {waiting ? null : mode === "token" ? (
          <Button title="Connect" kind="primary" disabled={busy || !token.trim()} onPress={() => void withToken()} />
        ) : (
          <Button title="Continue in Browser" kind="primary" disabled={busy} onPress={() => void begin()} />
        )}
      </DialogActions>
    </Sheet>
  );
}

function GoogleSaveSheet({ provider: id }: { provider: string }) {
  const provider = useVaultProvider(id);
  const account = useGoogleAccount();
  const [email, setEmail] = useState(account.email ?? provider?.account ?? "");
  useEffect(() => {
    if (account.email) setEmail((typed) => typed || account.email!);
  }, [account.email]);
  const [password, setPassword] = useState("");
  const [signIn, setSignIn] = useState<GoogleSignInState | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  useEffect(() => {
    let live = true;
    const check = () => {
      setSignIn(null);
      void checkGoogleSignInState().then((state) => live && setSignIn(state));
    };
    check();
    const subscription = watchGoogleSignIn(check);
    return () => {
      live = false;
      subscription.remove();
    };
  }, []);
  const save = async () => {
    if (busy) return;
    setBusy(true);
    setError("");
    const problem = await saveGoogleAccountPassword(email, password);
    setPassword("");
    if (problem) {
      setBusy(false);
      return setError(problem);
    }
    const state = await refreshProvider(id);
    if (state?.state === "locked") {
      const result = await unlockProvider(id, null);
      if (!result.ok) {
        setBusy(false);
        return setError(signInError(result, provider?.name ?? "Google Password Manager"));
      }
    }
    setBusy(false);
    closeSettingsSheet();
  };
  const connecting = !account.hasPassword;
  return (
    <Sheet onClose={closeSettingsSheet}>
      <SheetHead provider={id} title={connecting ? "Connect Google Password Manager" : "Google Password"} />
      <SheetText>Ardia syncs with passwords.google.com in the background. Google asks for your password each time, so Ardia keeps it in your keychain behind Touch ID.</SheetText>
      <View style={GAP_TOP}>
        <Group>
          <Row title="Google in Ardia" description={signIn ? GOOGLE_SIGN_IN_TEXT[signIn] : "Checking…"}>
            {signIn === "signIn" ? <Button title="Sign In…" onPress={showGoogleSignIn} /> : null}
          </Row>
        </Group>
      </View>
      <FormField label="Google Account">
        <TextField value={email} onChangeText={setEmail} placeholder="name@gmail.com" width="100%" />
      </FormField>
      <FormField label="Google Password">
        <TextField value={password} onChangeText={setPassword} secure autoFocus width="100%" onSubmit={() => void save()} />
      </FormField>
      <SheetError text={error} />
      <DialogActions>
        <Button title="Cancel" onPress={closeSettingsSheet} />
        <Button title={busy ? (connecting ? "Connecting…" : "Saving…") : connecting ? "Connect" : "Update Password"} kind="primary" disabled={busy || !password || !email.trim() || signIn === "signIn"} onPress={() => void save()} />
      </DialogActions>
    </Sheet>
  );
}

function UnlockSheet({ provider: id }: { provider: string }) {
  const provider = useVaultProvider(id);
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  useCloseWhenUnlocked(provider);
  if (!provider) return null;
  const unlock = async () => {
    if (!password || busy) return;
    setBusy(true);
    setError("");
    const result = await unlockProvider(provider.id, password);
    setPassword("");
    setBusy(false);
    if (result.ok) return closeSettingsSheet();
    setError(result.error && result.error !== "failed" ? result.error : "That password didn't work. Try again.");
  };
  return (
    <Sheet size="s" onClose={closeSettingsSheet}>
      <SheetHead provider={provider.id} title={`Unlock ${provider.name}`} />
      <FormField label="Master Password">
        <TextField value={password} onChangeText={setPassword} secure autoFocus width="100%" onSubmit={() => void unlock()} />
      </FormField>
      <TouchIdRow provider={provider} />
      <SheetError text={error} />
      <DialogActions>
        <Button title="Cancel" onPress={closeSettingsSheet} />
        <Button title={busy ? "Unlocking…" : "Unlock"} kind="primary" disabled={busy || !password} onPress={() => void unlock()} />
      </DialogActions>
    </Sheet>
  );
}

const BODY = { marginTop: space.l, lineHeight: proseLineHeight.small } as const;
const GAP_TOP = { marginTop: space.l } as const;
const WAITING = GAP_TOP;
const SPINNER = { width: VAULT_SETTINGS.spinner, height: VAULT_SETTINGS.spinner } as const;
const COMMAND = { marginTop: space.m, minHeight: VAULT_SETTINGS.commandMinHeight, borderWidth: 1 } as const;
const MONO = { flex: 1, fontFamily: "Menlo" } as const;
