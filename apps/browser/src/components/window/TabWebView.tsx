import { WebView } from "../ui";
import { type OpenWindowRequest, openFromPage } from "../../state/tabs/openFromPage";
import type { PageEngine } from "../../state/engines/engines";
import { memo, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { StyleSheet } from "react-native";
import { focus, switchToTab } from "../../state/browser/actions";
import { notePictureInPictureBackToTab, notePictureInPictureClickSkip, notePictureInPictureDragged, notePictureInPictureHandleUnstash, notePictureInPictureResized, notePictureInPictureStandIn } from "../../state/telemetry/pictureInPictureCounts";
import { noteRendererResponsive, noteRendererUnresponsive } from "../../state/telemetry/freezes";
import { noteFavicon } from "../../state/favicons/favicons";
import { adoptIconPage, dropOutlivedFavicon, noteIconPage } from "../../state/favicons/iconPage";
import { endThemeHold, heldThemeColor } from "../../state/windows/launchLook";
import { noteTabReady } from "../../state/app/programControl";
import { isQuitting } from "../../state/app/quit";
import { useProfileTheme } from "./ThemeScope";
import { opaqueCard } from "../ui/opaqueCard";
import { handOff, takeHandOff, wantsPage } from "../../state/tabs/tabPages";
import { noteDiscarded, noteGone, noteReady } from "../../state/tabs/tabLifecycle";
import { noteWebKitPage, offerWebKit, persistEngine } from "../../state/engines/actions";
import { heldBySwap, watchFirstPaint } from "../../state/engines/engineSwap";
import { useRetiringEngine } from "../../state/engines/hooks";
import { noteProtectedVideoRefusal } from "../../state/telemetry/protectedVideoCounts";
import { consentToken } from "../../state/telemetry/client";
import { webviewRef, webviews } from "../../state/tabs/webviewHandles";
import { noteIssued, takeStartedNavigation } from "../../state/tabs/earlyNavigate";
import { currentEngineProfile, currentTab, isTabSilenced } from "../../state/browser/current";
import { updateLive, updateTab } from "../../state/tabs/actions";
import { returnRefusedMove, setFind } from "../../state/windows/actions";
import { activateFocusedPane, currentTabEngine, downloadNavigated, useTabEngine } from "../../state/windows/card";
import { setPageProgress } from "../../state/tabs/pageProgress";
import { shallowEqual, useBrowserWhile, useProfilesValue, useTabValue } from "../../state/tabs/tabWatch";
import { isIncognitoProfile, navigationTo } from "../../state/browser/model";
import type { Tab } from "../../state/browser/types";
import { zoomChangedByUser } from "../../state/site/zoomBubble";
import { markTabReady, patchPage, pageOf } from "../../state/tabs/pageState";
import { popupBlocked, showAutofillPrompt, showExternalApp, showPasswordPrompt } from "../../state/site/prompts";
import { fieldProviderHint, fieldProviderOpened, verificationCodeFound, type FieldProviderHint, type FieldProviderOpened, type VerificationCodeFound } from "../../state/site/passwordManager";
import { verificationCodeDocument, verificationCodeTabGone } from "../../state/site/verificationCodes";
import { hoverStatus } from "../../state/tabs/hoverStatus";
import { leftPage, pageAskedToClose, pageEnded } from "../../state/tabs/pageEvents";
import { copyLinkToSelection, searchSelection, setPageSelection } from "../../state/site/selection";
import { shareFromPage } from "../../state/site/share";
import { useAutoPictureInPicture } from "../../state/media/pip";
import { requestDisplayMedia } from "../../state/media/screenShare";
import { setNowPlaying, setPictureInPictureState } from "../../state/media/media";
import { noteScroll } from "../../state/windows/toolbarAutoHide";
import { closeWebNotification, showWebNotification } from "../../state/site/webNotifications";
import { escapePressed } from "../../state/windows/unclaimedEscape";
import { withoutFragment } from "../../lib/url";
import { adoptOf, loadedPage, navigationOf } from "../../state/tabs/pageSession";
import { noteCommit } from "../../state/automation/automationEvents";
import { forgetUnreadIfGone, noteAppBadge, noteUnreadFavicon, noteUnreadLoading, noteUnreadPageEnded } from "../../state/tabs/unread";
import { trackPageProcessGone } from "../../state/telemetry/diagnostics";
import { releaseTranslation, translateCrashContext } from "../../state/site/translate";
import { notePagePress, notePagePressRefused } from "../../state/telemetry/tabPresses";
import { noteWebKitFocusRestore } from "../../state/telemetry/pageFocusReturns";
import { noteAutoPictureInPictureKept, notePageOverlay, noteReopenedPage, noteSiteControls, noteWebKitPageKeptHidden } from "../../state/telemetry/usage";
import { noteWebKitMediaFault } from "../../state/telemetry/webkitMediaFaults";
import { isAdoptKind } from "../../state/tabs/adoptIds";
import { firstPagePending, isBlankAddress, noteFirstPagePending, reportedAddress, reportedTitle } from "../../state/tabs/pendingAddress";
import { STATUS_FLIP_BAND } from "./tokens";
import { startHidingElement } from "../../state/site/hiddenElements";
import { forgetPeekHandover, notePeekRecipient, peekDonorTaken } from "../../state/peek/donors";
import { promotedFromPeek } from "../../state/peek/actions";

const webViewTab = (t: Tab | undefined) => ({ navigation: navigationOf(t), adoptId: adoptOf(t), profileId: t?.profileId ?? "", shownUrl: t?.url ?? "" });

type TabWebViewProps = { tabId: string; visible: boolean; selected?: boolean; warm: boolean; peekOf?: string };

const ARRIVING = [StyleSheet.absoluteFill, { opacity: 0 }];

export const TabWebView = memo(function TabWebView(props: TabWebViewProps) {
  const engine = useTabEngine(props.tabId);
  const retiring = useRetiringEngine(props.tabId, engine);
  const shown = useRef(engine);
  const holding = useRef<PageEngine | null>(null);
  if (shown.current !== engine) {
    const leavingUnpainted = holding.current !== null;
    holding.current = retiring === shown.current && props.visible && !leavingUnpainted ? retiring : null;
    shown.current = engine;
  }
  if (holding.current && (retiring !== holding.current || !props.visible)) holding.current = null;
  const held = holding.current;
  const live = <EngineWebView key={engine} engine={engine} arriving={!!held} {...props} />;
  if (!held) return live;
  const old = <EngineWebView key={held} engine={held} retired {...props} />;
  return held === "chromium" ? [old, live] : [live, old];
});

function EngineWebView({ tabId, visible, selected = true, warm, peekOf, engine, retired = false, arriving = false }: TabWebViewProps & { engine: PageEngine; retired?: boolean; arriving?: boolean }) {
  const asPeek = peekOf !== undefined;
  const isDonor = () => asPeek && promotedFromPeek(tabId);
  const handedToTab = () => isDonor() && peekDonorTaken(tabId);
  const { navigation, adoptId, profileId, shownUrl } = useTabValue(tabId, webViewTab, shallowEqual);
  const neighbour = useBrowserWhile(warm, (s) => warm && s.windows[s.tabs[tabId]?.windowId ?? ""]?.profileId !== profileId);
  const tab = () => currentTab(tabId);
  const ref = useMemo(() => {
    const register = webviewRef(tabId);
    return (handle: Parameters<typeof register>[0]) => (handle && peekOf !== undefined && promotedFromPeek(tabId) ? undefined : register(handle));
  }, [tabId]);
  const autoPictureInPicture = useAutoPictureInPicture(tabId, visible);
  const pageColor = useProfilesValue(profileId, (profiles) => (isIncognitoProfile(profileId) ? "incognito" : (profiles[profileId]?.color ?? "plum")));
  const theme = useProfileTheme(profileId);
  const backdrop = useMemo(() => opaqueCard(theme), [theme.card, theme.windowTint[0], theme.windowTint[1]]);

  const lastPage = useRef<string | null>(null);
  const restore = useRef<string | null>(null);
  const reopening = useRef(engine === "chromium" && isAdoptKind(adoptId, "restore"));
  const pending = useRef<string | null>(navigation?.url ?? (adoptId ? (tab()?.url ?? null) : null));

  const seq = navigation?.seq;
  const adopted = useRef<string | null>(null);
  const [handoff] = useState(() => takeHandOff(tabId, engine));
  const arrived = useRef(!!handoff && (handoff.seq === navigation?.seq || isBlankAddress(navigation?.url ?? "")));
  const loadsOnCreate = useRef(engine === "webkit" && !handoff ? navigation?.seq : undefined);
  useEffect(() => {
    if (!navigation || retired || isDonor()) return;
    noteIssued(tabId, navigation.seq);
    if (arrived.current) {
      arrived.current = false;
      return;
    }
    if (navigation.url === adopted.current) {
      adopted.current = null;
      return;
    }
    pending.current = navigation.url;
    if (pageOf(tabId).newTabShown) patchPage(tabId, { newTabShown: null });
    if (loadsOnCreate.current === navigation.seq) {
      loadsOnCreate.current = undefined;
      return;
    }
    if (takeStartedNavigation(tabId, navigation.seq)) return;
    void webviews.get(tabId)?.loadUrl(navigation.url, { userInitiated: !!navigation.userInitiated });
  }, [seq]);
  const fromNewTab = useRef(pageOf(tabId).wasNewTab && !adoptId);
  useEffect(() => {
    persistEngine(tabId, engine);
    return () => {
      if (wentRetired.current) return;
      if (handedToTab()) return forgetPeekHandover(tabId);
      noteGone(tabId);
      endThemeHold(tabId);
      verificationCodeTabGone(tabId);
      noteFirstPagePending(tabId, false);
      forgetUnreadIfGone(tabId);
    };
  }, []);
  const waitsOffScreen = engine === "webkit" && warm && !visible;
  useEffect(() => {
    if (waitsOffScreen) noteWebKitPageKeptHidden();
  }, [waitsOffScreen]);
  const mountedProfile = useRef(profileId);
  const wentRetired = useRef(false);
  useLayoutEffect(() => {
    const revived = wentRetired.current && !retired;
    wentRetired.current = retired;
    if (revived) watchFirstPaint(tabId, engine, visible);
    if (!retired) return;
    setPageProgress(tabId, 0);
    pageEnded(tabId);
    noteGone(tabId);
    noteFirstPagePending(tabId, false);
  }, [retired]);
  useLayoutEffect(
    () => () => {
      if (wentRetired.current || handedToTab()) return;
      const t = tab();
      const sameEngine = currentTabEngine(tabId) === engine;
      if (wantsPage(t) && sameEngine && currentEngineProfile(t.profileId) === currentEngineProfile(mountedProfile.current) && !isQuitting()) handOff(tabId, currentEngineProfile(t.profileId), engine);
      else {
        setPageProgress(tabId, 0);
        if (!isQuitting()) pageEnded(tabId);
      }
    },
    [],
  );

  const prewarmOnly = () => !navigationOf(tab()) && !adoptId;

  const onOpenWindow = (request: OpenWindowRequest) => {
    const t = tab();
    if (t) openFromPage(request, { windowId: t.windowId, profileId: t.profileId, tabId });
  };

  return (
    <WebView
      ref={retired ? undefined : ref}
      engine={engine}
      retired={retired}
      style={arriving ? ARRIVING : StyleSheet.absoluteFill}
      url={navigation?.url ?? (adoptId ? tab()?.url : undefined)}
      profile={currentEngineProfile(profileId)}
      adoptId={adoptId}
      tabId={tabId}
      temporary={peekOf !== undefined}
      temporarySource={peekOf}
      visible={visible}
      selected={selected}
      warm={warm}
      neighbour={neighbour}
      autoPictureInPicture={autoPictureInPicture}
      pageColor={pageColor}
      contentsBackgroundColor={backdrop}
      shownUrl={shownUrl}
      onReady={() => {
        if (peekOf === undefined) notePeekRecipient(tabId);
        markTabReady(tabId);
        noteTabReady(tabId);
        noteReady(tabId);
        void webviews.get(tabId)?.setMuted(isTabSilenced(tabId));
        watchFirstPaint(tabId, engine, visible);
      }}
      onNavigationChange={({ url: reported, title: reportedPageTitle, canGoBack, canGoForward, isLoading, themeColor, themeColorSource, initialDocumentAccessed, committedInitial, committedUrl, committedAt, httpStatus }) => {
        noteCommit(tabId, committedUrl, committedAt, httpStatus);
        verificationCodeDocument(tabId, committedAt);
        if (reopening.current && reported && !isBlankAddress(reported)) {
          reopening.current = false;
          noteReopenedPage(canGoBack);
        }
        noteUnreadLoading(tabId, isLoading);
        adoptIconPage(tabId);
        const { url, untouched } = reportedAddress({ url: reported, initialDocumentAccessed, committedInitial }, { adoptId, openedByPage: !!tab()?.openerId });
        const title = reportedTitle(reportedPageTitle, url);
        const target = pending.current ?? (lastPage.current === null ? (navigationOf(tab())?.url ?? null) : null);
        if (target === null && prewarmOnly()) {
          if (isBlankAddress(url)) return;
          adopted.current = url;
          updateTab(tabId, { page: loadedPage(navigationTo(url)) });
        }
        if (lastPage.current === null && target !== null && !target.startsWith("about:")) restore.current = target;
        if (!isLoading || (committedUrl && !isBlankAddress(committedUrl))) restore.current = null;
        const restoring = restore.current !== null;
        if (target !== null && isBlankAddress(url) && !target.startsWith("about:") && untouched) {
          noteFirstPagePending(tabId, true);
          if (!heldBySwap(tabId, { isLoading: true })) updateLive(tabId, { isLoading: true });
          return;
        }
        noteFirstPagePending(tabId, firstPagePending({ url, committedInitial, isLoading }));
        const shownTheme = heldThemeColor(tabId, url, themeColor, isLoading);
        pending.current = null;
        const kept = pageOf(tabId).newTabShown;
        if (kept) {
          if (url === kept.url) {
            patchPage(tabId, { newTabShown: { ...kept, title } });
            updateLive(tabId, { isLoading, canGoBack, canGoForward, themeColor: shownTheme });
            return;
          }
          patchPage(tabId, { newTabShown: null });
        }
        if (fromNewTab.current && url && !isBlankAddress(url)) patchPage(tabId, { backToNewTab: true });
        const held = heldBySwap(tabId, { isLoading });
        const shownTitle = !title && (restoring || held) ? (tab()?.title ?? title) : title;
        updateTab(tabId, { url, title: shownTitle }, { isLoading: isLoading && !held, canGoBack, canGoForward, themeColor: shownTheme });
        dropOutlivedFavicon(tabId, url, isLoading);
        if (engine === "webkit") noteWebKitPage(tabId, { url, title, isLoading, committedUrl: committedUrl ?? "" });
        if (lastPage.current !== null && withoutFragment(url) !== lastPage.current) leftPage(tabId, url, lastPage.current, engine, peekOf !== undefined);
        lastPage.current = withoutFragment(url);
        patchPage(tabId, { themeColorSource: themeColorSource ?? null });
      }}
      onLoadError={() => {
        pending.current = null;
      }}
      onDownloadNavigation={({ committedUrl, skipped }) => {
        pending.current = null;
        downloadNavigated(tabId, committedUrl, skipped);
      }}
      onProgress={(progress) => !prewarmOnly() && !heldBySwap(tabId, { progress }) && setPageProgress(tabId, progress)}
      onZoom={({ zoom, user }) => {
        updateTab(tabId, { zoom });
        if (user) zoomChangedByUser(tabId);
      }}
      onFindResult={({ count, active }) => setFind(tabId, { count, active })}
      onFavicon={(favicon) => {
        if (!favicon || !tab()) return;
        noteIconPage(tabId);
        updateTab(tabId, { favicon });
        noteFavicon(tabId, favicon);
        noteUnreadFavicon(tabId, tab()?.url ?? "", favicon);
      }}
      onAppBadge={(badge) => noteAppBadge(tabId, badge)}
      onMedia={({ playing, muted }) => {
        updateLive(tabId, { playingAudio: playing });
        if (!muted && isTabSilenced(tabId)) void webviews.get(tabId)?.setMuted(true);
      }}
      onNowPlaying={(state) => setNowPlaying(tabId, state)}
      onPictureInPicture={(state) => setPictureInPictureState(tabId, state)}
      onAutoPictureInPictureKept={noteAutoPictureInPictureKept}
      onPictureInPictureDragged={notePictureInPictureDragged}
      onPictureInPictureResized={notePictureInPictureResized}
      onPictureInPictureSkip={notePictureInPictureClickSkip}
      onPictureInPictureUnstashed={notePictureInPictureHandleUnstash}
      onPictureInPictureStandIn={notePictureInPictureStandIn}
      onMediaFault={noteWebKitMediaFault}
      onDisplayMediaRequest={(request) => requestDisplayMedia(tabId, request)}
      onOpenWindow={onOpenWindow}
      onStatus={(status, fromBottom) => {
        const statusAtTop = !!status && fromBottom !== null && fromBottom < STATUS_FLIP_BAND;
        if (statusAtTop) notePageOverlay("statusAtTop");
        patchPage(tabId, status ? { status: hoverStatus(status), statusAtTop } : { status });
      }}
      onCrashed={(crashed) => {
        if (!isQuitting()) {
          pageEnded(tabId);
          patchPage(tabId, { crashed, unresponsive: false, fullscreen: false, status: "" });
          trackPageProcessGone(crashed, visible, translateCrashContext(tabId));
          releaseTranslation(tabId);
        }
        noteUnreadPageEnded(tabId);
      }}
      onUnresponsive={() => {
        noteRendererUnresponsive(tabId);
        patchPage(tabId, { unresponsive: true });
      }}
      onResponsive={() => {
        noteRendererResponsive(tabId, false);
        patchPage(tabId, { unresponsive: false });
      }}
      onFullscreen={(fullscreen) => patchPage(tabId, { fullscreen })}
      onMediaAccess={(mediaAccess) => patchPage(tabId, { mediaAccess: mediaAccess.camera || mediaAccess.microphone || mediaAccess.screen ? mediaAccess : null })}
      onSecurity={(security) => !prewarmOnly() && patchPage(tabId, { security })}
      onContentBlocked={({ count }) => patchPage(tabId, { blocked: count })}
      onPopupBlocked={(popup) => popupBlocked(tabId, popup)}
      onPasswordPrompt={(prompt) => showPasswordPrompt(tabId, prompt)}
      onAutofillPrompt={(prompt, id) => showAutofillPrompt(tabId, prompt, id)}
      onExternalApp={(externalApp) => showExternalApp(tabId, externalApp)}
      onPageFocus={() => activateFocusedPane(tabId)}
      onFocusRestore={noteWebKitFocusRestore}
      onPagePress={(refused) => {
        if (refused) return notePagePressRefused();
        notePagePress(tabId);
        activateFocusedPane(tabId);
      }}
      onWindowClose={() => pageAskedToClose(tabId)}
      onTransferRefused={(from) => returnRefusedMove(tabId, from)}
      onNotification={(notification) => showWebNotification(tabId, notification)}
      onCommand={({ command, text, modifiers, share, anchor, point }) => {
        if (command === "search") searchSelection(tabId, text, modifiers);
        else if (command === "share" && share) void shareFromPage(tab(), share, anchor);
        else if (command === "copyLinkToHighlight") void copyLinkToSelection(tabId);
        else if (command === "escape") escapePressed(tabId, "page");
        else if (command === "hideElement" && point) void startHidingElement(tabId, point);
      }}
      onSelection={(selection) => setPageSelection(tabId, selection)}
      onScroll={(state) => noteScroll(tabId, state)}
      onProtectedMedia={(request) => {
        if (engine === "chromium") noteProtectedVideoRefusal(request, consentToken());
        offerWebKit(tabId, request);
      }}
      onAutoplayBlocked={(count) => noteSiteControls("autoplayPlaysBlocked", count)}
      onFieldProviderOpened={(opened: FieldProviderOpened) => fieldProviderOpened(tabId, opened)}
      onFieldProviderHint={(hint: FieldProviderHint) => fieldProviderHint(tabId, hint)}
      onVerificationCodeFound={(found: VerificationCodeFound) => verificationCodeFound(tabId, found)}
      onNotificationClose={closeWebNotification}
      onDiscarded={(url, reason) => {
        releaseTranslation(tabId);
        pending.current = url;
        fromNewTab.current = false;
        pageEnded(tabId);
        patchPage(tabId, { backToNewTab: false, status: "" });
        updateLive(tabId, { isLoading: false, canGoBack: false, canGoForward: false, playingAudio: false });
        setPageProgress(tabId, 0);
        noteDiscarded(tabId, reason);
        noteUnreadPageEnded(tabId);
      }}
      onActivateRequest={({ reason, fromOtherApp }) => {
        const t = tab();
        if (!t) return;
        if (reason === "pictureInPicture") notePictureInPictureBackToTab(engine, fromOtherApp === true);
        switchToTab(tabId);
        focus(t.windowId);
      }}
    />
  );
}
