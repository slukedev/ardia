import { isDefaultBrowser, systemInfo } from "../../platform/app";
import { setAsDefaultBrowser } from "./appSettings";
import { PLATFORM_FEATURES } from "../../lib/platformFeatures";
import { readDocument, saveDocument } from "../../platform/documents";
import { maybeStartOnboarding, onboardingCompletedAt, useOnboarding } from "../onboarding/onboarding";
import { trackAppVersion } from "../releaseNotes/releaseNotes";
import { afterFirstWindow } from "../../lib/afterFirstWindow";
import { offerDefaultBrowserAgain } from "../onboarding/defaultBrowserOffer";
import { openReleaseNotesAfterUpdate } from "../releaseNotes/releaseNotesPage";
import { startWebKitNotifications } from "../site/webKitNotificationEvents";
import { startWebKitCounts } from "../telemetry/engineSwitchCounts";
import { startNotificationResponses } from "./notificationResponses";
import { startHandoff } from "./handoff";
import { startScripting } from "./scripting";
import { noteReleaseNotesHeldForFirstRun } from "../telemetry/firstRunCounts";
import { consentToken } from "../telemetry/client";
import { warnFor } from "../telemetry/logs";

export function startAppIntegration() {
  startNotificationResponses();
  if (PLATFORM_FEATURES.webKit) {
    startWebKitNotifications();
    startWebKitCounts();
  }
  startHandoff();
  startScripting();
  const updated = trackAppVersion();
  const firstRun = maybeStartOnboarding();
  if (updated && firstRun) noteReleaseNotesHeldForFirstRun();
  if (updated && !firstRun) openReleaseNotesAfterUpdate();
  afterFirstWindow(() => {
    if (!PLATFORM_FEATURES.setsDefaultBrowser) return;
    const consent = consentToken();
    void offerDefaultBrowserAgain({
      read: readDocument,
      save: saveDocument,
      testInstance: systemInfo().isolatedInstance !== false,
      onboarding: !onboardingCompletedAt() || useOnboarding.getState().windowId !== null,
      isDefault: isDefaultBrowser,
      setDefault: setAsDefaultBrowser }).catch((error) => warnFor(consent, "[defaultBrowserOffer]", error));
  });
}
