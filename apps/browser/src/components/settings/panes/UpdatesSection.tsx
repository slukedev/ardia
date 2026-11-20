import { useEffect } from "react";
import { AppState, View } from "react-native";
import { checkForUpdates } from "../../../state/app/appSettings";
import { systemInfo } from "../../../state/app/system";
import { openUrls } from "../../../state/browser/actions";
import { ActivitySpinner, Button, lineHeight, Segmented, space, Text, Toggle } from "../../ui";
import { perLook } from "../../ui/tokens";
import { SHARING_COPY } from "../../../state/telemetry/copy";
import { engineVersion, followUpdater, setUpdaterPrefs, updater } from "../../../state/settings/paneData";
import { checkNowControl, switchCheckLine, updaterBusy } from "../../../state/settings/updateStatus";
import { useResource } from "../../../state/settings/resources";
import { UI_LOCALE } from "../../../lib/uiLocale";
import { Group, Row, SectionHeader } from "../Form";
import { setting } from "../settingsIndex";

const APP = "Ardia";
const REPOSITORY = "https://github.com/mantrakp04/ardia";

export function UpdatesSection() {
  const [state, reload] = useResource(updater);
  const refresh = () => void reload();
  useEffect(() => {
    const sub = AppState.addEventListener("change", refresh);
    return () => sub.remove();
  }, []);
  const busy = updaterBusy(state);
  useEffect(() => {
    if (busy) followUpdater();
  }, [busy]);
  const live = state?.available ? state : null;
  const ready = !!live?.configured;
  const lastCheck = live?.lastCheck
    ? `Last checked ${new Date(live.lastCheck).toLocaleString(UI_LOCALE, { dateStyle: "medium", timeStyle: "short" })}.`
    : "Not checked yet.";
  const status = ready ? (switchCheckLine(state, APP) ?? lastCheck) : null;
  const checkNow = checkNowControl(state);
  const version = live ? (live.displayVersion ?? live.version) : systemInfo().appVersion;
  const setAutoInstall = (on: boolean) => {
    if (!live) return;
    setUpdaterPrefs({ automaticChecks: on, automaticDownloads: on });
  };

  return (
    <>
      <SectionHeader title="Updates" description={live && !ready ? "Updates aren't set up for this build." : undefined} />
      <Group>
        {live && (
          <Row anchor="general.autoUpdate" description={`${setting("general.autoUpdate").description} ${SHARING_COPY.updateChecks} ${SHARING_COPY.switchFile}`}>
            <Toggle value={ready && live.automaticChecks && live.automaticDownloads} disabled={!ready} accessibilityLabel={setting("general.autoUpdate").title} onChange={setAutoInstall} />
          </Row>
        )}
        {live?.channel && (
          <Row anchor="general.updateChannel">
            <Segmented
              value={live.channel}
              options={[
                { value: "stable", title: "Stable" },
                { value: "nightly", title: "Nightly" },
              ]}
              onChange={(channel) => ready && setUpdaterPrefs({ channel })}
            />
          </Row>
        )}
        <Row anchor="general.version" title={`${APP} ${version}`} description={<VersionDetails status={status} />}>
          {live && (
            <View style={CHECK_NOW}>
              {checkNow.checking ? <ActivitySpinner style={CHECK_SPINNER} /> : null}
              <Button title={checkNow.title} disabled={checkNow.disabled} onPress={() => checkNow.pressable && void checkForUpdates().finally(() => followUpdater())} />
            </View>
          )}
        </Row>
      </Group>
    </>
  );
}

function VersionDetails({ status }: { status: string | null }) {
  const [info] = useResource(engineVersion);
  const engines = `Chromium ${info?.chromiumVersion ?? "…"}`;
  return (
    <View>
      {status ? (
        <Text size="caption" tone="textSecondary" style={DETAIL()}>
          {status}
        </Text>
      ) : null}
      <Text selectable size="caption" tone="textSecondary" style={DETAIL()}>
        {engines}
      </Text>
      <View style={LINKS}>
        <Button variant="text" look="link" pad="none" title="Source code" onPress={() => openUrls([`${REPOSITORY}/tree/v${systemInfo().appVersion}`])} />
        <Button variant="text" look="link" pad="none" title="Licenses" onPress={() => openUrls(["chrome://credits"])} />
      </View>
    </View>
  );
}

const CHECK_NOW = { flexDirection: "row", alignItems: "center", gap: space.m } as const;
const CHECK_SPINNER = { width: 14, height: 14 } as const;
const DETAIL = perLook(() => ({ marginTop: space.xxs, lineHeight: lineHeight.caption }) as const);
const LINKS = { flexDirection: "row", gap: space.ml, marginTop: space.xs } as const;
