import type { Plugin } from "vite";
import type { Wording } from "./credentialWording";
import { hasMacModifiers, linuxShortcutText } from "./shortcutText";
import { PHRASES_ONLY_WITH } from "../browser/src/state/telemetry/platformWording";

export const LINUX_WORDING: readonly Wording[] = [
  {
    file: "state/live/engine.ts",
    replacements: [
      [
        "    case \"signedOut\":\n      return `Sign back in to ${name}`;\n",
        "    case \"signedOut\":\n      return `Sign back in to ${name}`;\n    case \"keyringLocked\":\n      return `Unlock your keyring to refresh ${name}`;\n    case \"keyringUnavailable\":\n      return `Start your keyring to refresh ${name}`;\n",
      ],
    ],
  },
  {
    file: "components/onboarding/LookStep.tsx",
    replacements: [
      [`subtitle: "Buttons and panels catch the light, as in Tahoe"`, `subtitle: "Buttons and panels catch the light"`],
      ["subtitle: `Light by day, dark by night, like your ${PLATFORM_TERMS.computer}`", `subtitle: "Light by day, dark by night, like your desktop"`],
    ],
  },
  {
    file: "components/onboarding/HomeStep.tsx",
    replacements: [
      [
        `        {system && system.dockAvailable && !system.inDock ? (
          <OptionCard control="check" icon="dock.rectangle" title="Add Ardia to Dock" subtitle="Quick access whenever you need it" selected={dock} onPress={() => setExtras({ dock: !dock })} />
        ) : null}
`,
        "",
      ],
      ["        {PLATFORM_FEATURES.dock ? chip(dock, \"dock.rectangle\", \"In your Dock\") : null}\n", ""],
    ],
  },
  {
    file: "components/onboarding/previews/MockWindow.tsx",
    replacements: [["{`Auto · ${look.dark ? \"Dark\" : \"Light\"} like your ${PLATFORM_TERMS.computer}`}", "{`Auto · ${look.dark ? \"Dark\" : \"Light\"} like your desktop`}"]],
  },
  {
    file: "components/onboarding/previews/scenes/LookScenes.tsx",
    replacements: [["`Auto · ${toDark ? \"Dark\" : \"Light\"} like your ${PLATFORM_TERMS.computer}`", "`Auto · ${toDark ? \"Dark\" : \"Light\"} like your desktop`"]],
  },
  {
    file: "components/settings/panes/General.tsx",
    replacements: [["label: PLATFORM_FEATURES.quitsWithLastWindow ? `Quitting when you close the last window` : `Quitting with ${keyText(\"⌘Q\")}`", `label: "Quitting with Ctrl+Shift+Q"`]],
  },
  {
    file: "state/telemetry/copy.ts",
    replacements: [
      ...[PHRASES_ONLY_WITH.freezeWatch ?? []].flat().map((phrase): [string, string] => [phrase, ""]),
      ["how many tab changes this Mac sent,", "how many tab changes this computer sent,"],
      ["Sent to ardia.dev with a random ID made on this Mac, and kept", "Sent to ardia.dev with a random ID made on this computer, and kept"],
      [`keptOnThisMac: "Kept on this Mac"`, `keptOnThisMac: "Kept on this computer"`],
      ["browsing data removed from this Mac and", "browsing data removed from this computer and"],
      ["switched Auto-hide tabs on or off on this Mac,", "switched Auto-hide tabs on or off on this computer,"],
      ["how many times this Mac's WebKit couldn't mute a whole page", "how many times this computer's WebKit couldn't mute a whole page"],
      ["and how many times ⌘-scroll changed the zoom", "and how many times Ctrl-scroll changed the zoom"],
      ["more were loaded than your Mac's memory allows for", "more were loaded than your computer's memory allows for"],
      ["turned Minimalism mode on and off on this Mac, from Settings, the View menu or ⌃⌘M,", "turned Minimalism mode on and off on this computer, from Settings, the View menu or Ctrl+Super+M,"],
      ["whether macOS Increase Contrast is on", "whether the desktop's high contrast setting is on"],
      [
        "whether macOS returned an error, whether Ardia or the app that opened it was asked, whether System Settings opened, and how long it took.",
        "whether Evolution Data Server returned an error, and how long it took.",
      ],
      ["app version, update channel, macOS version, chip,", "app version, update channel, operating system version, chip,"],
      [
        `dailyCountShort: "Either way, Ardia sends one anonymous “opened today” count a day, with its version and macOS version and no persistent ID."`,
        `dailyCountShort: "Either way, Ardia sends one anonymous “opened today” count a day, with its version and operating system version and no persistent ID."`,
      ],
      [
        "change it any time in Settings › Privacy & Security. Either way, Ardia sends one anonymous “opened today” count a day, with its version and macOS version and no persistent ID.",
        "change it any time in Settings › Privacy & Security. Either way, Ardia sends one anonymous “opened today” count a day, with its version and operating system version and no persistent ID.",
      ],
      [
        "After a crash: the exception type and name (never its message), and the function names where it was thrown and on the crashing thread, from this app's crash report",
        "After a crash: the signal and its code, and for each step on the crashing thread the file it ran in (like chrome or libc.so.6) and the position inside that file, with the build IDs of Ardia's own files, read from the crash dump Chromium's crash handler keeps on this computer. Never the dump itself, which can hold page content",
      ],
      [
        "plus the version that crashed, how long the process had run, the total size of its writable memory regions, and how the system ended it (its termination reason, like a signal or a code-signing kill)",
        "plus the engine version that crashed, how long the process had run, and the signal that ended it",
      ],
      ["A random install ID, made on this Mac once", "A random install ID, made on this computer once"],
      ["App version and build, macOS version, chip", "App version and build, operating system version, chip"],
      [
        "Every 10 minutes Ardia notes on this Mac its tab, window and profile counts, its memory use, rough free disk space, the Mac's memory pressure, how long it has been open, and which of Ardia's own pages (like Settings or History) the tab in front was on, never a website's address. Ardia also takes that note when you open or leave one of those pages, and keeps the last 3 of those pages with how many minutes ago you were on each. That note is sent only with a crash report, or at the next launch after Ardia didn't quit cleanly, with whether the Mac restarted since.",
        "Every 10 minutes Ardia notes on this computer its tab, window and profile counts, its memory use, rough free disk space, the system's memory pressure, how long it has been open, and which of Ardia's own pages (like Settings or History) the tab in front was on, never a website's address. Ardia also takes that note when you open or leave one of those pages, and keeps the last 3 of those pages with how many minutes ago you were on each. That note is sent only with a crash report, or at the next launch after Ardia didn't quit cleanly, with whether the computer restarted since.",
      ],
      [
        "how much memory the Mac has, how many displays and their scale, and whether the Mac decodes",
        "how much memory the computer has, how many displays and their scale, and whether the computer decodes",
      ],
      ["whether it's the first launch since the Mac started", "whether it's the first launch since the computer started"],
      ["Also at launch: the Mac's load average", "Also at launch: the system's load average"],
      ["a link no app on this Mac opens", "a link no app on this computer opens"],
      ["Its version, whether it's a release or test build, and this Mac's install ID", "Its version, whether it's a release or test build, and this computer's install ID"],
      ["Leaves this Mac only as the events above", "Leaves this computer only as the events above"],
      ["whether macOS and Ardia agree that Ardia is the app in front", "whether the system and Ardia agree that Ardia is the app in front"],
      ["window was still on a screen, either though macOS reported it covered", "window was still on a screen, either though the system reported it covered"],
      ["one the ardia command or a debugger started and left behind, or one macOS refused to start.", "one the ardia command or a debugger started and left behind, or one the system refused to start."],
      [
        "whether macOS gave Ardia location access, you said no in macOS's prompt, it was already off in System Settings, or the check failed, one event each time.",
        "whether the desktop's location service (GeoClue) let Ardia ask for the location, refused it, or the check failed, one event each time.",
      ],
      ["and the copy kept on this Mac is deleted.", "and the copy kept on this computer is deleted."],
      [`title: "Kept on this Mac"`, `title: "Kept on this computer"`],
      ["Saves the local copy to your Downloads folder and shows it in Finder.", "Saves the local copy to your Downloads folder and shows it in your file manager."],
      ["Never leaves this Mac unless sharing is on", "Never leaves this computer unless sharing is on"],
      ["and how many times its Open System Settings button was pressed", "and how many times its settings button was pressed"],
      ["how many Dock icon clicks brought a browser window forward", "how many taskbar icon clicks brought a browser window forward"],
      ["How many times ⌘T kept a New Tab bar", "How many times Ctrl+T kept a New Tab bar"],
      ["How many times ⇧⌘C went to a focused Developer Tools", "How many times Ctrl+Shift+C went to a focused Developer Tools"],
      ["and how many use ⌥ without ⌘ or ⌃,", "and how many use Alt without Ctrl or Super,"],
      ["How many times ⌥↩ in the command bar", "How many times Alt+Enter in the command bar"],
      ["how often the ⌃Tab switcher opens", "how often the Ctrl+Tab switcher opens"],
      ["how many tabs were closed from it with ⌃W", "how many tabs were closed from it with Ctrl+W"],
      ["because the Touch ID or password request before it was declined", "because the system password request before it was declined"],
      ["How many times ⌘W closed several", "How many times Ctrl+W closed several"],
      ["closing the Top App in front (⌘W, or a middle click on it)", "closing the Top App in front (Ctrl+W, or a middle click on it)"],
      ["Bringing your last window back from the Dock or at launch", "Bringing your last window back from the taskbar or at launch"],
      ["How many times ⌘Y asked for the History", "How many times Ctrl+Y asked for the History"],
      [
        "summed up once an hour, and when Ardia can't post one or the system refuses it: how long its title and message were, whether it asked for an icon and whether one was sent, what happened to the icon (one of a few fixed outcomes, such as it failed to download or the system refused it, with the system's error code for that), that it came through Ardia's notification page script, whether posting failed in Ardia itself and the kind of error it was, and the error code the system gave with which of a few known system error families it came from. Never the notification's text or which site",
        "summed up once an hour. Never the notification's text or which site",
      ],
    ],
  },
  {
    file: "state/commands/appCommands.ts",
    replacements: [["`${PLATFORM_TERMS.os} ${app.osVersion} (${app.osBuild}), ${app.arch}", "`${app.osVersion} (${app.osBuild}), ${app.arch}"]],
  },
  {
    file: "state/report/details.ts",
    replacements: [["`${PLATFORM_TERMS.os} ${app.osVersion}`, app.model", "`Linux ${app.osVersion}`, app.model"]],
  },
  {
    file: "components/report/ReportSheet.tsx",
    replacements: [
      ["Recordings, contact and details stay private.", "Contact and details stay private."],
      ["Help confirm the fix: share crash reports and usage for 14 days", "Help confirm the fix: share errors and usage for 14 days"],
    ],
  },
  {
    file: "components/report/AttachedRow.tsx",
    replacements: [[`title: "Usage, errors and crashes, last 7 days"`, `title: "Usage and errors, last 7 days"`]],
  },
  {
    file: "components/import/steps/SafariStep.tsx",
    replacements: [["`macOS protects ${source.name}'s data from other apps. To import", "`${source.name}'s data is protected from other apps. To import"]],
  },
  {
    file: "state/import/runImport.ts",
    replacements: [
      [
        "`macOS didn't allow access to ${source.name}'s keychain item. Try again, or skip the encrypted data.`",
        "`The system keyring didn't allow access to ${source.name}'s Safe Storage key. Try again, or skip the encrypted data.`",
      ],
      [
        "`${NOT_BROUGHT} macOS didn't allow Ardia to ask Dia for them. Allow it in System Settings › Privacy & Security › Automation, then import again.`",
        "`${NOT_BROUGHT} Ardia wasn't allowed to ask Dia for them.`",
      ],
      [
        "\"Dia's Favorites weren't imported: they're in its sidebar file, which needs the keychain access you skipped.\"",
        "\"Dia's Favorites weren't imported: they're in its sidebar file, which needs the keyring access you skipped.\"",
      ],
    ],
  },
  {
    file: "components/downloads/Downloads.tsx",
    replacements: [
      ["tooltip={`Show in ${PLATFORM_TERMS.fileManager}`}", "tooltip=\"Show in Folder\""],
    ],
  },
  {
    file: "components/pages/DownloadsPage.tsx",
    replacements: [
      ["<Button title={`Show in ${PLATFORM_TERMS.fileManager}`}", "<Button title=\"Show in Folder\""],
    ],
  },
  {
    file: "state/downloads/downloadMenu.ts",
    replacements: [
      ["{ id: \"reveal\", title: `Show in ${PLATFORM_TERMS.fileManager}`", "{ id: \"reveal\", title: \"Show in Folder\""],
    ],
  },
  {
    file: "state/bookmarks/exportHtml.ts",
    replacements: [
      ["action: { title: `Show in ${PLATFORM_TERMS.fileManager}`", "action: { title: \"Show in Folder\""],
    ],
  },
  {
    file: "state/onboarding/tour.ts",
    replacements: [
      ["${keyText(\"⌘L\")} brings the command bar up from any page, and ${keyText(\"⌘T\")} opens a new tab.", "Ctrl+L brings the command bar up from any page, and Ctrl+T opens a new tab."],
      ["${keyText(\"⌘S\")} hides the sidebar.", "Ctrl+S hides the sidebar."],
      ["or press ${keyText(\"⌃⇧=\")}. ${keyText(\"⌃⇧]\")} and ${keyText(\"⌃⇧[\")} move between the panes.", "or press Super+Shift+=. Super+Shift+] and Super+Shift+[ move between the panes."],
      ["Everything else is in the menu bar and in Settings (⌘,).", "Everything else is in the menu button's menus and in Settings (Ctrl+,)."],
      ["`Everything else is in Settings (${keyText(\"⌘,\")}).`", "\"Everything else is in Settings (Ctrl+,).\""],
    ],
  },
  {
    file: "state/presets/setupCode.ts",
    replacements: [
      ["auto: `Appearance follows your ${PLATFORM_TERMS.computer}`", "auto: \"Appearance follows your desktop\""],
      ["`${keyText(\"⌘T\")} opens the command bar` : `${keyText(\"⌘T\")} opens the New Tab page`", "\"Ctrl+T opens the command bar\" : \"Ctrl+T opens the New Tab page\""],
    ],
  },
  {
    file: "state/releaseNotes/releaseNotes.ts",
    replacements: [
      ["or from any page with ⌘L.", "or from any page with Ctrl+L."],
    ],
  },
];

const marker = "/apps/browser/src/";
const sharedPath = (id: string) => {
  const at = id.indexOf(marker);
  return at < 0 ? null : (id.slice(at + marker.length).split("?")[0] ?? "");
};

export function rewordForLinux(id: string, code: string): string | null {
  const path = sharedPath(id);
  const wording = path === null ? undefined : LINUX_WORDING.find((entry) => entry.file === path);
  if (!wording) return null;
  let reworded = code;
  for (const [from, to] of wording.replacements) {
    const found = reworded.includes(from) ? from : hasMacModifiers(from) && reworded.includes(linuxShortcutText(from)) ? linuxShortcutText(from) : null;
    if (found === null) throw new Error(`${path} no longer contains ${JSON.stringify(from.slice(0, 80))}; update apps/linux/linuxWording.ts`);
    reworded = reworded.replace(found, () => to);
  }
  return reworded;
}

const sharesWording = (path: string) => /^components\/(settings|import|onboarding)\//.test(path);

export function linuxWording(): Plugin {
  const applied = new Set<string>();
  let building = false;
  return {
    name: "ardia-linux:wording",
    enforce: "pre",
    configResolved(config) {
      building = config.command === "build";
    },
    transform(code, id) {
      const reworded = rewordForLinux(id, code);
      if (reworded === null) return null;
      applied.add(sharedPath(id) ?? "");
      return { code: reworded, map: null };
    },
    buildEnd(error) {
      if (!building || error) return;
      const loaded = [...this.getModuleIds()].map(sharedPath).filter((path): path is string => path !== null);
      if (!loaded.some(sharesWording)) return;
      const missing = LINUX_WORDING.map((entry) => entry.file).filter((file) => !applied.has(file));
      if (missing.length) this.error(`linuxWording.ts never reworded ${missing.join(", ")}; update apps/linux/linuxWording.ts`);
    },
  };
}
