import Foundation

enum WebKitPageScript {
  static let fieldProviderKit: String = {
    let start = "  const fieldProviderKit = "
    let end = "  const nativeMutationObserver = "
    guard let path = Bundle(for: WebKitHub.self).path(forResource: "page_script", ofType: "js"),
      let script = try? String(contentsOfFile: path, encoding: .utf8),
      let from = script.range(of: start),
      let to = script.range(of: end, range: from.upperBound..<script.endIndex)
    else {
      NSLog("[webkit] field provider kit not found in page_script.js")
      return "  const fieldProviderKit = () => ({ configure() {}, focusQuery() {} });\n  const fieldProviderIntrinsics = () => ({});\n"
    }
    return String(script[from.lowerBound..<to.lowerBound])
  }()

  static let source = [media, theme, scroll, selection, fieldProviders, commands].joined(separator: "\n\n")

  static let mediaBridge = mediaSessionBridge + appBadgeBridge

  static let media = #"""
(() => {
  if (window.__ardia) return;
  const isTop = window === window.top;
  const frame = Math.random().toString(36).slice(2);
  const post = (kind, data) => {
    try {
      window.webkit.messageHandlers.ardia.postMessage({ kind, data: data === undefined ? null : data, frame });
    } catch (e) {}
  };
  let muted = false;
  const mutedByUs = new WeakSet();
  const mediaEvents = ["play", "playing", "pause", "ended", "volumechange", "emptied", "loadedmetadata", "seeked", "ratechange"];
  const detached = new Set();
  const listened = new WeakSet();
  const heard = new WeakSet();
  let lastMedia = null;
  let lastHeard = null;
  let pageActions = [];
  let pagePosition = null;
  const handlers = Object.create(null);
  const allMedia = () => {
    const list = Array.from(document.querySelectorAll("video, audio"));
    for (const m of detached) if (!list.includes(m)) list.push(m);
    return list;
  };
  const playing = (m) => !m.paused && !m.ended;
  const audible = (m) => playing(m) && !m.muted && m.volume > 0;
  const applyMute = (m) => {
    if (muted && !m.muted) {
      m.muted = true;
      mutedByUs.add(m);
    }
  };
  const active = (list) => {
    const present = (m) => (m && list.includes(m) ? m : null);
    return list.find((m) => heard.has(m) && playing(m)) || present(lastHeard) || list.find(playing) || present(lastMedia);
  };
  const sessionState = () => (navigator.mediaSession ? navigator.mediaSession.playbackState : "none");
  const advancePosition = (state) => {
    const playingNow = state === "playing";
    if (playingNow === pagePosition.playing) return;
    const now = Date.now();
    if (pagePosition.playing) pagePosition.position += ((now - pagePosition.at) / 1000) * pagePosition.playbackRate;
    pagePosition.at = now;
    pagePosition.playing = playingNow;
  };
  const positionOf = (m, state) => {
    if (!pagePosition) return isFinite(m.currentTime) ? m.currentTime : 0;
    advancePosition(state);
    const { position, duration, playbackRate, at, playing } = pagePosition;
    const now = position + (playing ? ((Date.now() - at) / 1000) * playbackRate : 0);
    return Math.max(0, duration > 0 ? Math.min(now, duration) : now);
  };
  const movePagePosition = (m, state, to) => {
    if (!pagePosition) return;
    positionOf(m, state);
    pagePosition.position = Math.max(0, pagePosition.duration > 0 ? Math.min(to, pagePosition.duration) : to);
    pagePosition.at = Date.now();
  };
  let queued = false;
  const report = () => {
    queued = false;
    const list = allMedia();
    post("media", { playing: list.some(audible), muted });
    const m = active(list);
    const session = navigator.mediaSession;
    const fromSession = sessionState();
    if (!m || (m.paused && !m.currentTime && fromSession === "none")) return post("nowPlaying", null);
    const meta = session && session.metadata;
    const art = meta && meta.artwork && meta.artwork.length ? meta.artwork[meta.artwork.length - 1].src : null;
    const state = fromSession !== "none" ? fromSession : playing(m) ? "playing" : "paused";
    const duration = pagePosition && pagePosition.duration > 0 ? pagePosition.duration : m.duration;
    post("nowPlaying", {
      title: (meta && meta.title) || document.title || "",
      artist: (meta && meta.artist) || "",
      album: (meta && meta.album) || "",
      artwork: art,
      playbackState: state,
      position: positionOf(m, state),
      duration: isFinite(duration) ? duration : null,
      playbackRate: pagePosition ? pagePosition.playbackRate : m.playbackRate || 1,
      timestamp: Date.now(),
      hasVideo: m.tagName === "VIDEO" && m.videoWidth > 0,
      actions: pageActions,
      controllable: fromSession !== "none" || !(m.duration > 0 && m.duration <= 5),
      loop: !pagePosition && m.loop,
    });
  };
  const schedule = () => {
    if (queued) return;
    queued = true;
    setTimeout(report, 100);
  };
  const listen = (m) => {
    if (listened.has(m)) return;
    listened.add(m);
    for (const type of mediaEvents) m.addEventListener(type, onMedia);
  };
  const track = (m) => {
    listen(m);
    if (detached.has(m)) return;
    if (detached.size >= 8) for (const old of detached) if (!playing(old)) {
      detached.delete(old);
      break;
    }
    detached.add(m);
  };
  const onMedia = (e) => {
    const m = e.target;
    if (!(m instanceof HTMLMediaElement)) return;
    if (!m.isConnected) track(m);
    lastMedia = m;
    if (e.type === "play" || e.type === "playing") {
      applyMute(m);
      listen(m);
    }
    if (e.type === "volumechange") applyMute(m);
    if (audible(m)) {
      heard.add(m);
      lastHeard = m;
    }
    schedule();
  };
  for (const type of mediaEvents) document.addEventListener(type, onMedia, true);
  document.addEventListener(
    "ardia:media-element",
    (e) => {
      const m = e.relatedTarget;
      if (!(m instanceof HTMLMediaElement)) return;
      track(m);
      schedule();
    },
    true,
  );
  const mediaFaultSites = \#(WebKitMediaFaults.sitesJSON);
  if (location.protocol === "https:" && mediaFaultSites.some((site) => location.hostname === site || location.hostname.endsWith("." + site))) {
    let faultsRelayed = 0;
    document.addEventListener(
      "ardia:media-fault",
      (e) => {
        if (typeof e.detail !== "string" || e.detail.length > 64 || ++faultsRelayed > 200) return;
        post("mediaFault", { reason: e.detail });
      },
      true,
    );
  }
  const knownActions = ["play", "pause", "stop", "seekbackward", "seekforward", "seekto", "previoustrack", "nexttrack", "skipad", "enterpictureinpicture"];
  document.addEventListener(
    "ardia:media-session",
    (e) => {
      let data = null;
      try {
        data = typeof e.detail === "string" ? JSON.parse(e.detail) : null;
      } catch (error) {}
      if (!data || typeof data !== "object") return;
      pageActions = Array.isArray(data.actions) ? knownActions.filter((a) => data.actions.includes(a)) : [];
      const p = data.position;
      const finite = (n) => typeof n === "number" && isFinite(n);
      if (!p || !finite(p.position) || !finite(p.duration)) pagePosition = null;
      else {
        const sample = finite(p.id) ? p.id : null;
        if (!pagePosition || sample === null || pagePosition.sample !== sample)
          pagePosition = {
            position: Math.max(0, p.position),
            duration: p.duration,
            playbackRate: finite(p.playbackRate) && p.playbackRate ? p.playbackRate : 1,
            at: finite(p.at) ? p.at : Date.now(),
            sample,
            playing: p.playing === true,
          };
      }
      schedule();
    },
    true,
  );
  if (isTop)
    document.addEventListener(
      "ardia:app-badge",
      (e) => {
        let data = null;
        try {
          data = typeof e.detail === "string" ? JSON.parse(e.detail) : null;
        } catch (error) {}
        if (data && typeof data === "object") post("appBadge", data);
      },
      true,
    );
  const pip = (on) => post("pip", { active: on });
  document.addEventListener("enterpictureinpicture", () => pip(true), true);
  document.addEventListener("leavepictureinpicture", () => pip(false), true);
  document.addEventListener(
    "webkitpresentationmodechanged",
    (e) => e.target instanceof HTMLVideoElement && pip(e.target.webkitPresentationMode === "picture-in-picture"),
    true,
  );
  addEventListener("pagehide", () => {
    if (isTop) return;
    post("media", { playing: false, muted });
    post("nowPlaying", null);
  });
  addEventListener("pageshow", (e) => e.persisted && schedule());

  let hovered = "";
  document.addEventListener(
    "mouseover",
    (e) => {
      const link = e.target && e.target.closest ? e.target.closest("a[href]") : null;
      const href = link ? link.href : "";
      if (href === hovered) return;
      hovered = href;
      post("status", { text: href.slice(0, 8192), y: e.clientY, height: innerHeight });
    },
    true,
  );
  document.addEventListener("mouseleave", () => hovered && post("status", { text: (hovered = "") }), true);

  let sentIcons = "";
  const sendIcons = () => {
    if (!isTop) return;
    const links = Array.from(document.querySelectorAll('link[rel~="icon"], link[rel="shortcut icon"], link[rel~="apple-touch-icon"]'));
    const urls = links.map((l) => l.href).filter((h) => /^(https?|data):/.test(h)).slice(0, 32);
    if (!urls.length && /^https?:$/.test(location.protocol)) urls.push(location.origin + "/favicon.ico");
    const key = urls.join("\n");
    if (!urls.length || key === sentIcons) return;
    const changed = !!sentIcons;
    sentIcons = key;
    post("icons", { urls, changed });
  };
  let iconsQueued = false;
  const queueIcons = () => {
    if (iconsQueued) return;
    iconsQueued = true;
    setTimeout(() => {
      iconsQueued = false;
      sendIcons();
    }, 0);
  };
  const touchesIcon = (records) => {
    for (const r of records) {
      if (r.type === "attributes") {
        if (r.target.nodeName === "LINK") return true;
        continue;
      }
      for (const n of r.addedNodes) if (n.nodeName === "LINK") return true;
      for (const n of r.removedNodes) if (n.nodeName === "LINK") return true;
    }
    return false;
  };
  const watchIcons = () => {
    sendIcons();
    if (!isTop || !document.head) return;
    new MutationObserver((records) => touchesIcon(records) && queueIcons()).observe(document.head, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ["href", "rel"],
    });
  };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", watchIcons, { once: true });
  else watchIcons();
  addEventListener("load", sendIcons, { once: true });
  addEventListener("pageshow", (e) => {
    if (!e.persisted) return;
    sentIcons = "";
    sendIcons();
  });
"""#

  static let fieldProviders = #"""
  const guard = (fn) =>
    function () {
      try {
        return Reflect.apply(fn, this, arguments);
      } catch (e) {}
    };
  const later = (fn, ms) => {
    let queued = false;
    return () => {
      if (queued) return;
      queued = true;
      setTimeout(() => {
        queued = false;
        guard(fn)();
      }, ms);
    };
  };
  const onReady = (fn) => (document.readyState === "loading" ? document.addEventListener("DOMContentLoaded", fn, { once: true }) : fn());
\#(fieldProviderKit)
  const fieldProviders = fieldProviderKit({
    document,
    send: post,
    guard,
    later,
    onReady,
    revealed: () => null,
    addListener: EventTarget.prototype.addEventListener,
    apply: Reflect.apply,
    FrameMutationObserver: window.MutationObserver,
    setTimeout,
    addEventListener,
    requestAnimationFrame,
    isTop,
    intrinsics: fieldProviderIntrinsics(window),
  });
  post("fieldProviderHello", null);
  addEventListener("pageshow", (e) => e.isTrusted && e.persisted && post("fieldProviderHello", null));
"""#

  static let commands = #"""
  window.__ardia = {
    fieldProvider(state) {
      fieldProviders.configure(state);
    },
    fieldFocusQuery(query) {
      fieldProviders.focusQuery(query);
    },
    fieldProviderHint(state) {
      fieldProviders.hint(state);
    },
    mute(on) {
      muted = !!on;
      for (const m of allMedia()) {
        if (muted) applyMute(m);
        else if (mutedByUs.has(m)) {
          m.muted = false;
          mutedByUs.delete(m);
        }
      }
      report();
    },
    media(action, seconds) {
      const m = active(allMedia());
      const call = (name, details) =>
        pageActions.includes(name) &&
        !document.dispatchEvent(new CustomEvent("ardia:media-action", { cancelable: true, detail: JSON.stringify({ action: name, ...details }) }));
      const isPlaying = sessionState() === "playing" || (!!m && playing(m));
      if (action === "play") call("play") || (m && m.play());
      else if (action === "pause") call("pause") || (m && m.pause());
      else if (action === "stop") call("stop") || (m && m.pause());
      else if (action === "toggle") isPlaying ? call("pause") || (m && m.pause()) : call("play") || (m && m.play());
      else if (action === "next") call("nexttrack");
      else if (action === "previous") call("previoustrack");
      else if (action === "seekBy") {
        const handled = seconds >= 0 ? call("seekforward", { seekOffset: seconds }) : call("seekbackward", { seekOffset: -seconds });
        if (!handled && m) {
          const state = isPlaying ? "playing" : "paused";
          const from = pagePosition ? positionOf(m, state) : m.currentTime;
          m.currentTime = Math.max(0, Math.min(m.duration || Infinity, m.currentTime + seconds));
          movePagePosition(m, state, from + seconds);
        }
      } else if (action === "seekTo" && !call("seekto", { seekTime: seconds }) && m) {
        m.currentTime = Math.max(0, seconds);
        movePagePosition(m, isPlaying ? "playing" : "paused", seconds);
      }
      schedule();
      return !!m || pageActions.length > 0;
    },
    pictureInPicture(on, automatic) {
      if (!on) {
        if (document.pictureInPictureElement) document.exitPictureInPicture();
        for (const v of document.querySelectorAll("video")) if (v.webkitPresentationMode === "picture-in-picture") v.webkitSetPresentationMode("inline");
        return true;
      }
      const videos = Array.from(document.querySelectorAll("video"));
      const largest = () => videos.sort((a, b) => b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight)[0];
      const v = videos.find(playing) || (automatic ? null : largest());
      if (!v) return automatic ? "nothingPlaying" : false;
      if (v.webkitSupportsPresentationMode && v.webkitSupportsPresentationMode("picture-in-picture")) v.webkitSetPresentationMode("picture-in-picture");
      else if (v.requestPictureInPicture) v.requestPictureInPicture();
      else return false;
      return true;
    },
    selectionPopover(on) {
      if (handlers.selectionPopover) handlers.selectionPopover(on);
    },
    count(text) {
      if (!text || !document.body) return 0;
      const haystack = document.body.innerText.toLowerCase();
      const needle = text.toLowerCase();
      let n = 0;
      for (let at = haystack.indexOf(needle); at >= 0 && n < 1000; at = haystack.indexOf(needle, at + needle.length)) n++;
      return n;
    },
  };
})();
"""#
}
