import { useEffect, useState } from "react";
import { View } from "react-native";
import { resolveInput } from "@ardia/core";
import { defaultEngine, ENGINE_NAMES, PROTECTED_VIDEO_SITES, RECOMMENDED_ENGINE, siteOf, type PageEngine } from "../../../state/engines/engines";
import { setWebsiteEngine } from "../../../state/engines/actions";
import { useSettings } from "../../../state/browser/hooks";
import { updateSettings } from "../../../state/settings/actions";
import { closeSettingsSheet, showSettingsSheet } from "../../../state/settings/sheet";
import { Button, DialogActions, DialogTitle, PopUp, Sheet, space, Symbol, Text, TextField } from "../../ui";
import { useTheme } from "../../ui/theme";
import { Favicon } from "../../favicon/Favicon";
import { FormField, Group, Row, SectionHeader, SettingToggle } from "../Form";
import { PasskeyAccessRow } from "./PasskeyAccessRow";
import { ABOUT_ENGINES_TITLE, showWebKitLimits } from "./WebKitLimitsSheet";

const ENGINE_OPTIONS: { value: PageEngine; title: string }[] = [
  { value: "chromium", title: ENGINE_NAMES.chromium },
  { value: "webkit", title: ENGINE_NAMES.webkit },
];

const DEFAULT_ENGINE_OPTIONS = ENGINE_OPTIONS.map((o) => (o.value === RECOMMENDED_ENGINE ? { ...o, title: `${o.title} (recommended)` } : o));

const SHOWN_STREAMING_SITES = 5;

const siteLabel = (site: string) => site.replace(/^https:\/\//, "");

export function WebEngineSection() {
  const engine = useSettings((settings) => defaultEngine({ settings }));
  const rules = useSettings((s) => s.websiteEngines);
  const protectedVideo = useSettings((s) => s.protectedVideoInWebKit);
  const automatic = useSettings((s) => s.engineMode === "automatic");
  const sites = Object.keys(rules).sort((a, b) => siteLabel(a).localeCompare(siteLabel(b)));
  return (
    <>
      <SectionHeader title="Web engine" />
      <Group>
        <Row anchor="advanced.pageEngine">
          <PopUp value={engine} options={DEFAULT_ENGINE_OPTIONS} onChange={(value) => updateSettings({ pageEngine: value })} minWidth={190} />
        </Row>
        <Row anchor="advanced.websiteEngines">
          {!protectedVideo && <Button title="Add Streaming Sites" onPress={() => updateSettings({ protectedVideoInWebKit: true })} />}
          <Button title="Add Rule…" icon="plus" onPress={() => showSettingsSheet(<RuleSheet />)} />
        </Row>
        {automatic && protectedVideo && <StreamingSitesRow />}
        {automatic && sites.map((site) => <RuleRow key={site} site={site} engine={rules[site]!} />)}
        <SettingToggle anchor="advanced.offerWebKitForProtectedVideo" />
      </Group>
      <SectionHeader title="Switching engines" />
      <Group>
        <SettingToggle anchor="advanced.engineSwitchKeepsPage" />
        <SettingToggle anchor="advanced.engineSwitchAsksAboutUnsavedWork" />
      </Group>
      <SectionHeader title="WebKit pages" />
      <Group>
        <Row anchor="advanced.enginesDiffer" onPress={() => showSettingsSheet(<EnginesDifferSheet />)} />
      </Group>
    </>
  );
}

function StreamingSitesRow() {
  const theme = useTheme();
  const shown = PROTECTED_VIDEO_SITES.slice(0, SHOWN_STREAMING_SITES).join(", ");
  const more = PROTECTED_VIDEO_SITES.length - SHOWN_STREAMING_SITES;
  return (
    <Row
      icon={<Symbol name="play.tv" size={14} color={theme.icon} style={STREAMING_ICON} />}
      title="Streaming sites"
      description={`${shown}${more > 0 ? ` and ${more} more` : ""} open in WebKit, which plays their protected video.`}
    >
      <Text tone="textSecondary">{ENGINE_NAMES.webkit}</Text>
      <Button variant="icon" icon="trash" size="m" onPress={() => updateSettings({ protectedVideoInWebKit: false })} tooltip="Remove" />
    </Row>
  );
}

function RuleRow({ site, engine }: { site: string; engine: PageEngine }) {
  return (
    <Row icon={<Favicon url={site} />} title={siteLabel(site)}>
      <PopUp value={engine} options={ENGINE_OPTIONS} onChange={(value) => setWebsiteEngine(site, value)} minWidth={110} />
      <Button variant="icon" icon="pencil" size="m" onPress={() => showSettingsSheet(<RuleSheet site={site} engine={engine} />)} tooltip="Edit" />
      <Button variant="icon" icon="trash" size="m" onPress={() => setWebsiteEngine(site, null)} tooltip="Remove" />
    </Row>
  );
}

function RuleSheet({ site, engine: initial }: { site?: string; engine?: PageEngine }) {
  const [address, setAddress] = useState(site ? siteLabel(site) : "");
  const [engine, setEngine] = useState<PageEngine>(initial ?? "webkit");
  const [error, setError] = useState<string | null>(null);
  const save = () => {
    const typed = address.trim();
    const target = siteOf(/^[a-z][\w+.-]*:\/\//i.test(typed) ? typed : resolveInput(typed, ""));
    if (!target) return setError("Enter a website address, like netflix.com.");
    if (site && site !== target) setWebsiteEngine(site, null);
    setWebsiteEngine(target, engine);
    closeSettingsSheet();
  };
  return (
    <Sheet onClose={closeSettingsSheet}>
      <DialogTitle subtitle="A rule matches the site's address exactly: its scheme, host and port. Subdomains need their own rule.">{site ? "Edit Rule" : "Add Rule"}</DialogTitle>
      <FormField label="Website">
        <TextField value={address} onChangeText={setAddress} placeholder="netflix.com" onSubmit={save} onEscape={closeSettingsSheet} />
      </FormField>
      <FormField label="Opens in" inline>
        <PopUp value={engine} options={ENGINE_OPTIONS} onChange={setEngine} />
      </FormField>
      {error && (
        <Text size="caption" tone="destructive" style={ERROR}>
          {error}
        </Text>
      )}
      <DialogActions
        leading={
          site ? (
            <Button
              title="Remove"
              kind="destructive"
              onPress={() => {
                setWebsiteEngine(site, null);
                closeSettingsSheet();
              }}
            />
          ) : null
        }
      >
        <Button title="Cancel" onPress={closeSettingsSheet} />
        <Button title={site ? "Save" : "Add"} kind="primary" onPress={save} />
      </DialogActions>
    </Sheet>
  );
}

const PASSKEYS_WAITING = "WebKit pages can't use passkeys until Apple grants Ardia its browser passkey entitlement. Sign in with a passkey in Chromium meanwhile.";

function EnginesDifferSheet() {
  return (
    <Sheet size="l" onClose={closeSettingsSheet}>
      <DialogTitle subtitle="Every page opens in Chromium or WebKit. Here's what changes between them.">How engines differ</DialogTitle>
      <View style={DIFFER_LIST}>
        <Group>
          <Row
            title="Separate sign-ins"
            description="Each engine keeps its own cookies and site data in every profile. With Bring sign-ins along on, a site's cookies and saved data follow it to the other engine; other offline data stays put."
          />
          <PasskeyAccessRow waiting={PASSKEYS_WAITING} />
          <Row title={ABOUT_ENGINES_TITLE} description="How Automatic picks an engine, and what WebKit pages can't do." onPress={() => showWebKitLimits("enginesPane")} />
        </Group>
      </View>
      <DialogActions>
        <Button title="Done" kind="primary" onPress={closeSettingsSheet} />
      </DialogActions>
    </Sheet>
  );
}

const STREAMING_ICON = { width: 20, height: 20 } as const;
const DIFFER_LIST = { marginTop: space.m } as const;
const ERROR = { marginTop: space.ml } as const;
