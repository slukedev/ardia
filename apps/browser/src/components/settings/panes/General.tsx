import { useEffect } from "react";
import { AppState, View } from "react-native";
import type { DownloadSettings } from "../../../state/downloads/actions";
import { setLaunchAtLogin } from "../../../state/app/appSettings";
import { confirm, pickFolder } from "../../../state/app/system";
import { Button, PopUp, Toggle } from "../../ui";
import { updateSettings } from "../../../state/settings/actions";
import { currentEngineProfile } from "../../../state/browser/current";
import { useProfiles, useSettings } from "../../../state/browser/hooks";
import { Group, Row, SectionHeader } from "../Form";
import { defaultBrowser, downloadFoldersDiffer, downloadSettings, loginItem, makeDefaultBrowser, setDownloadsFor } from "../../../state/settings/paneData";
import { useResource } from "../../../state/settings/resources";
import { goToSettingsPane, openImport, SETTINGS_DETAIL, type SettingsPlace } from "../../../state/settings/settingsWindows";
import { redoSetupFromSettings } from "../../../state/onboarding/redo";
import { onWindowEvent } from "../../../state/windows/nativeWindow";
import { keyText } from "../../../state/commands/keyText";
import { categoryOn, setBlockingCategory } from "../../../state/site/contentBlocking";
import type { FilterListCategory } from "../../../state/site/siteSettings";
import { PLATFORM_FEATURES } from "../../../lib/platformFeatures";
import { PLATFORM_TERMS } from "../../../lib/platformTerms";
import { SetupCodeRow } from "./SetupCodeRow";
import { EngineModeRow } from "./EngineModeRow";
import { CATEGORIES, useContentBlocker, writeBlocker } from "./FilterListsSheet";
import { CrashReportDetails, ShareDiagnosticsToggle } from "./ShareDiagnostics";
import { Checklist } from "./Checklist";
import { FilterListsPage } from "./FilterListsPage";
import { PaneSubPage } from "./PaneSubPage";
import { SyncSection } from "./SyncSection";
import { UpdatesSection } from "./UpdatesSection";

const APP = "Ardia";

export function GeneralPane({ detail }: SettingsPlace) {
  if (detail === SETTINGS_DETAIL.filterLists) return <FilterListsPage />;
  if (detail === SETTINGS_DETAIL.crashDetails)
    return (
      <PaneSubPage>
        <CrashReportDetails />
      </PaneSubPage>
    );
  return (
    <View>
      <DefaultBrowserSection />
      <StartupSection />
      {PLATFORM_FEATURES.webKit && <EngineSection />}
      <DownloadsSection />
      {PLATFORM_FEATURES.contentBlocker && <ContentBlockingSection />}
      {PLATFORM_FEATURES.sync && <SyncSection />}
      <UpdatesSection />
      <CrashReportsSection />
      <ImportSection />
    </View>
  );
}

function DefaultBrowserSection() {
  const [isDefault, reload] = useResource(defaultBrowser);
  useEffect(() => {
    const sub = AppState.addEventListener("change", () => void reload());
    const focus = onWindowEvent((e) => e.type === "focus" && void reload());
    return () => {
      sub.remove();
      focus.remove();
    };
  }, []);
  if (isDefault !== false) return null;
  return (
    <>
      <SectionHeader title="Default browser" />
      <Group>
        <Row anchor="general.defaultBrowser">
          <Button
            title={PLATFORM_FEATURES.setsDefaultBrowser ? `Set ${APP} as Default` : `Choose in ${PLATFORM_TERMS.os} Settings…`}
            kind="primary"
            onPress={() => void makeDefaultBrowser()}
          />
        </Row>
      </Group>
    </>
  );
}

function StartupSection() {
  const restoreSession = useSettings((s) => s.restoreSession);
  const warnBeforeQuitting = useSettings((s) => s.warnBeforeQuitting);
  const warnBeforeClosingWindow = useSettings((s) => s.warnBeforeClosingWindow);
  const warnBeforeClosingLastTab = useSettings((s) => s.warnBeforeClosingLastTab);
  const warnBeforeClosingTabGroup = useSettings((s) => s.warnBeforeClosingTabGroup);
  const warnBeforeMovingTabs = useSettings((s) => s.warnBeforeMovingTabsToProfile);
  const [loginStatus = "notRegistered", refreshLogin] = useResource(loginItem);
  return (
    <>
      <SectionHeader title="Startup and quitting" />
      <Group>
        <Row anchor="general.openAtLogin" description={loginStatus === "requiresApproval" ? `Allow it in ${PLATFORM_TERMS.loginItemsSettings}.` : undefined}>
          <Toggle
            accessibilityLabel={`Open ${APP} at login`}
            value={loginStatus === "enabled" || loginStatus === "requiresApproval"}
            onChange={(on) => void setLaunchAtLogin(on).catch(() => {}).finally(refreshLogin)}
          />
        </Row>
        <Row anchor="general.windowsAndTabs">
          <PopUp
            value={restoreSession ? "keep" : "close"}
            options={[
              { value: "keep", title: "Keep windows and tabs" },
              { value: "close", title: "Start fresh" },
            ]}
            onChange={(v) => updateSettings({ restoreSession: v === "keep" })}
            minWidth={190}
          />
        </Row>
        <Checklist
          anchor="general.askBefore"
          items={[
            {
              key: "quit",
              label: PLATFORM_FEATURES.quitsWithLastWindow ? `Quitting when you close the last window` : `Quitting with ${keyText("⌘Q")}`,
              value: warnBeforeQuitting,
              onChange: (on) => updateSettings({ warnBeforeQuitting: on }),
            },
            { key: "window", label: "Closing a window with several tabs", value: warnBeforeClosingWindow, onChange: (on) => updateSettings({ warnBeforeClosingWindow: on }) },
            { key: "lastTab", label: "Closing the last tab in a profile", value: warnBeforeClosingLastTab, onChange: (on) => updateSettings({ warnBeforeClosingLastTab: on }) },
            { key: "group", label: "Closing a tab group", value: warnBeforeClosingTabGroup, onChange: (on) => updateSettings({ warnBeforeClosingTabGroup: on }) },
            { key: "move", label: "Moving tabs to another profile", value: warnBeforeMovingTabs, onChange: (on) => updateSettings({ warnBeforeMovingTabsToProfile: on }) },
          ]}
        />
      </Group>
    </>
  );
}

function EngineSection() {
  return (
    <>
      <SectionHeader title="Web engine" />
      <Group>
        <EngineModeRow anchor="general.engineMode" />
      </Group>
    </>
  );
}

const homeRelative = (path: string) => path.replace(/^\/Users\/[^/]+(?=\/|$)/, "~");

function DownloadsSection() {
  const separate = useSettings((s) => s.separateDownloadFolders);
  const defaultProfileId = useSettings((s) => s.defaultProfileId);
  const profiles = useProfiles();
  const profile = currentEngineProfile(defaultProfileId);
  const [current] = useResource(downloadSettings, profile);
  const everyProfile = [...new Set([profile, ...profiles.map((p) => currentEngineProfile(p.id))])];
  const locked = !current || current.managed;
  const profileKey = everyProfile.join("\n");
  useEffect(() => {
    if (separate || everyProfile.length < 2) return;
    let live = true;
    void downloadFoldersDiffer(everyProfile).then((differ) => live && differ && updateSettings({ separateDownloadFolders: true }));
    return () => {
      live = false;
    };
  }, [separate, profileKey]);
  const apply = (patch: Partial<Pick<DownloadSettings, "folder" | "askWhereToSave">>, targets = everyProfile) => void setDownloadsFor(patch, targets);
  const change = async () => {
    if (!current) return;
    const folder = await pickFolder(current.folder, "Use Folder");
    if (folder) apply({ folder });
  };
  const setSeparate = (on: boolean) => {
    updateSettings({ separateDownloadFolders: on });
    if (!on && current && !current.managed) apply({ folder: current.folder, askWhereToSave: current.askWhereToSave }, everyProfile.filter((p) => p !== profile));
  };
  return (
    <>
      <SectionHeader title="Downloads" />
      <Group>
        <Row
          anchor="general.downloadsFolder"
          description={current ? (current.managed ? `${homeRelative(current.folder)}, set by your organization.` : homeRelative(current.folder)) : undefined}
        >
          <Button title="Change…" disabled={locked} onPress={() => void change()} />
        </Row>
        <Row anchor="general.separateDownloadFolders">
          <Toggle value={separate} accessibilityLabel="Separate folder for each profile" onChange={setSeparate} />
        </Row>
        <Row anchor="general.askWhereToSave">
          <Toggle value={current?.askWhereToSave ?? false} disabled={locked} onChange={(v) => apply({ askWhereToSave: v })} />
        </Row>
      </Group>
    </>
  );
}

function ContentBlockingSection() {
  const [blocker, refresh, unavailable] = useContentBlocker({ countOutages: true });
  const toggleCategory = async (c: FilterListCategory, on: boolean) => {
    if (!blocker) return;
    if (!on && c === "ads") {
      const { confirmed } = await confirm({
        title: "Turn Off Ad Blocker?",
        message: "Ardia's Ad Blocker hides ads so pages load faster and feel cleaner.",
        confirmTitle: "Turn Off",
      });
      if (!confirmed) return refresh();
    }
    await writeBlocker(() => setBlockingCategory(blocker, c, on), refresh);
  };
  return (
    <>
      <SectionHeader title="Content blocking" />
      <Group>
        {CATEGORIES.filter((c) => c.anchor).map((c) => (
          <Row key={c.id} anchor={c.anchor}>
            <Toggle value={!!blocker && categoryOn(blocker, c.id)} disabled={!blocker} onChange={(v) => void toggleCategory(c.id, v)} />
          </Row>
        ))}
        <Row anchor="general.filterLists" onPress={() => goToSettingsPane("general", null, SETTINGS_DETAIL.filterLists)} />
        {unavailable && (
          <Row title="uBlock Origin isn't answering" description="Its settings show here once it responds. Pages keep the blocking they had.">
            <Button title="Try Again" onPress={refresh} />
          </Row>
        )}
      </Group>
    </>
  );
}

function CrashReportsSection() {
  return (
    <>
      <SectionHeader title="Crash reports" />
      <Group>
        <ShareDiagnosticsToggle />
        <Row anchor="general.crashDetails" onPress={() => goToSettingsPane("general", null, SETTINGS_DETAIL.crashDetails)} />
      </Group>
    </>
  );
}

function ImportSection() {
  return (
    <>
      <SectionHeader title="Import" />
      <Group>
        <Row anchor="general.importBrowser">
          <Button title="Import…" onPress={() => openImport()} />
        </Row>
        <SetupCodeRow />
        <Row anchor="general.redoSetup">
          <Button title="Redo Setup…" onPress={redoSetupFromSettings} />
        </Row>
      </Group>
    </>
  );
}
