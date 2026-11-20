extension WebKitPageScript {
  static let theme = #"""
  if (isTop) try {
    const apply = Reflect.apply;
    const { addEventListener: listen, removeEventListener: unlisten } = EventTarget.prototype;
    const raf = window.requestAnimationFrame;
    const send = post;
    const guard = (fn) =>
      function () {
        try {
          return apply(fn, this, arguments);
        } catch (e) {}
      };
    const onReady = (fn) =>
      document.readyState === "loading" ? document.addEventListener("DOMContentLoaded", fn, { once: true }) : fn();
    const parse = (css) => {
      if (!css) return null;
      if (/^rgba?\(/.test(css)) {
        const m = css.match(/[\d.]+/g);
        if (!m || m.length < 3) return null;
        return { r: +m[0], g: +m[1], b: +m[2], a: m[3] === undefined ? 1 : +m[3] };
      }
      const m = css.match(/^(?:color\(([\w-]+)|(lab|lch|oklab|oklch)\()\s*([^/)]*?)\s*(?:\/\s*([\d.]+%?)\s*)?\)$/);
      const toLinearSrgb = m && LINEAR_SRGB_FROM[m[1] ?? m[2]];
      if (!toLinearSrgb) return null;
      const channels = m[3].split(/\s+/).map((token) => (token === "none" ? 0 : parseFloat(token)));
      if (channels.length < 3 || channels.some((n) => !Number.isFinite(n))) return null;
      const [r, g, b] = toLinearSrgb(channels).map((v) => Math.min(255, Math.max(0, srgbFromLinear(v) * 255)));
      const alpha = m[4] === undefined ? 1 : parseFloat(m[4]) / (m[4].endsWith("%") ? 100 : 1);
      return { r, g, b, a: Math.min(1, Math.max(0, alpha)) };
    };
    const srgbFromLinear = (v) => (v <= 0.0031308 ? 12.92 * v : 1.055 * v ** (1 / 2.4) - 0.055);
    const linearFromSrgb = (v) => {
      const magnitude = Math.abs(v);
      return Math.sign(v) * (magnitude <= 0.04045 ? magnitude / 12.92 : ((magnitude + 0.055) / 1.055) ** 2.4);
    };
    const multiply = (matrix, [x, y, z]) => matrix.map(([a, b, c]) => a * x + b * y + c * z);
    const XYZ_D65_TO_LINEAR_SRGB = [
      [3.2409699419045226, -1.537383177570094, -0.4986107602930034],
      [-0.9692436362808796, 1.8759675015077202, 0.04155505740717559],
      [0.05563007969699366, -0.20397695888897652, 1.0569715142428786],
    ];
    const XYZ_D50_TO_D65 = [
      [0.955473421488075, -0.02309845494876471, 0.06325924320057072],
      [-0.0283697093338637, 1.0099953980813041, 0.021041441191917323],
      [0.012314014864481998, -0.020507649298898964, 1.330365926242124],
    ];
    const LINEAR_P3_TO_XYZ_D65 = [
      [0.4865709486482162, 0.26566769316909306, 0.1982172852343625],
      [0.2289745640697488, 0.6917385218365064, 0.079286914093745],
      [0, 0.04511338185890264, 1.043944368900976],
    ];
    const D50_WHITE = [0.3457 / 0.3585, 1, (1 - 0.3457 - 0.3585) / 0.3585];
    const LAB_EPSILON = 216 / 24389;
    const LAB_KAPPA = 24389 / 27;
    const labToLinearSrgb = ([l, a, b]) => {
      const fy = (l + 16) / 116;
      const fx = fy + a / 500;
      const fz = fy - b / 200;
      const xyzD50 = [
        fx ** 3 > LAB_EPSILON ? fx ** 3 : (116 * fx - 16) / LAB_KAPPA,
        l > LAB_KAPPA * LAB_EPSILON ? fy ** 3 : l / LAB_KAPPA,
        fz ** 3 > LAB_EPSILON ? fz ** 3 : (116 * fz - 16) / LAB_KAPPA,
      ].map((v, i) => v * D50_WHITE[i]);
      return multiply(XYZ_D65_TO_LINEAR_SRGB, multiply(XYZ_D50_TO_D65, xyzD50));
    };
    const oklabToLinearSrgb = ([l, a, b]) => {
      const lms = [
        l + 0.3963377774 * a + 0.2158037573 * b,
        l - 0.1055613458 * a - 0.0638541728 * b,
        l - 0.0894841775 * a - 1.291485548 * b,
      ].map((v) => v ** 3);
      return multiply(
        [
          [4.0767416621, -3.3077115913, 0.2309699292],
          [-1.2684380046, 2.6097574011, -0.3413193965],
          [-0.0041960863, -0.7034186147, 1.707614701],
        ],
        lms,
      );
    };
    const fromPolar = ([l, chroma, hue]) => [l, chroma * Math.cos((hue * Math.PI) / 180), chroma * Math.sin((hue * Math.PI) / 180)];
    const LINEAR_SRGB_FROM = {
      srgb: (channels) => channels.slice(0, 3).map(linearFromSrgb),
      "srgb-linear": (channels) => channels.slice(0, 3),
      "display-p3": (channels) => multiply(XYZ_D65_TO_LINEAR_SRGB, multiply(LINEAR_P3_TO_XYZ_D65, channels.slice(0, 3).map(linearFromSrgb))),
      lab: labToLinearSrgb,
      lch: (channels) => labToLinearSrgb(fromPolar(channels)),
      oklab: oklabToLinearSrgb,
      oklch: (channels) => oklabToLinearSrgb(fromPolar(channels)),
    };
    const hex = (c) => "#" + [c.r, c.g, c.b].map((n) => Math.round(n).toString(16).padStart(2, "0")).join("").toUpperCase();
    const normalize = (value) => {
      const probe = document.createElement("span");
      probe.style.color = value;
      if (!probe.style.color) return null;
      document.documentElement.appendChild(probe);
      const c = parse(getComputedStyle(probe).color);
      probe.remove();
      return c && c.a > 0 ? hex(c) : null;
    };
    const setTimer = window.setTimeout;
    const clearTimer = window.clearTimeout;
    const NativeMutationObserver = window.MutationObserver;
    const after = (fn, ms) => apply(setTimer, window, [fn, ms]);
    const nextFrame = (fn) => apply(raf, window, [fn]);
    let metaMedia = [];
    let metaMediaKey = "";
    const watchMetaMedia = (queries, onChange) => {
      const key = queries.join("\n");
      if (key === metaMediaKey) return;
      metaMediaKey = key;
      for (const q of metaMedia) apply(unlisten, q, ["change", onChange]);
      metaMedia = queries.map((media) => matchMedia(media));
      for (const q of metaMedia) apply(listen, q, ["change", onChange]);
    };
    const metaColor = (onMediaChange) => {
      const queries = [];
      let color = null;
      for (const m of document.querySelectorAll('meta[name="theme-color"]')) {
        const media = m.getAttribute("media");
        if (media && !queries.includes(media)) queries.push(media);
        if (!color && (!media || matchMedia(media).matches)) color = normalize(m.getAttribute("content") || "");
      }
      watchMetaMedia(queries, onMediaChange);
      return color;
    };
    const backgroundOf = (el) => el && parse(getComputedStyle(el).backgroundColor);
    const pageBackground = () => {
      for (const el of [document.body, document.documentElement]) {
        const c = backgroundOf(el);
        if (c && c.a > 0) return c;
      }
      const dark = /dark/.test(getComputedStyle(document.documentElement).colorScheme) && matchMedia("(prefers-color-scheme: dark)").matches;
      return dark ? { r: 18, g: 18, b: 18, a: 1 } : { r: 255, g: 255, b: 255, a: 1 };
    };
    const blend = (c, under) =>
      c.a >= 1 ? c : { r: c.r * c.a + under.r * (1 - c.a), g: c.g * c.a + under.g * (1 - c.a), b: c.b * c.a + under.b * (1 - c.a), a: 1 };
    const headerColor = (page) => {
      const scrolled = window.scrollY > 4;
      for (const x of [innerWidth / 2, innerWidth * 0.2, innerWidth * 0.8]) {
        let pinned = false;
        let color = null;
        for (let el = document.elementFromPoint(x, 1); el && el !== document.body && el !== document.documentElement; el = el.parentElement) {
          const cs = getComputedStyle(el);
          if (cs.position === "fixed" || cs.position === "sticky") pinned = true;
          if (!color) {
            const c = parse(cs.backgroundColor);
            if (c && c.a >= 0.5) color = c;
          }
          if (color && pinned) break;
        }
        if (color && (pinned || !scrolled)) return blend(color, page);
      }
      return null;
    };
    const fromHex = (value) => {
      const n = parseInt(value.slice(1, 7), 16);
      return { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255, a: 1 };
    };
    const relativeLuminance = (c) => {
      const linear = (v) => ((v /= 255) <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
      return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b);
    };
    const clearlyLight = (c) => relativeLuminance(c) >= 0.5;
    const takesLightInk = (c) => {
      const l = relativeLuminance(c) + 0.05;
      return 1.05 / l >= l / 0.05;
    };
    let lastTheme;
    let metaCache;
    let lightMetaOnDarkPage = false;
    const cachedMetaColor = () => (metaCache === undefined ? (metaCache = metaColor(scheduleTheme)) : metaCache);
    const reportTheme = guard(() => {
      if (!document.documentElement) return;
      const meta = cachedMetaColor();
      let color = meta;
      let source = meta ? "meta" : null;
      lightMetaOnDarkPage = false;
      if (document.body && (!meta || clearlyLight(fromHex(meta)))) {
        const page = pageBackground();
        const header = headerColor(page);
        lightMetaOnDarkPage = !!meta && takesLightInk(page);
        if (!meta || (lightMetaOnDarkPage && (!header || takesLightInk(header)))) {
          color = hex(header || page);
          source = header ? "header" : "background";
        }
      }
      const key = color + source;
      if (key === lastTheme) return;
      lastTheme = key;
      send("theme", { color, source });
    });
    let themeQueued = false;
    let pageThemeQueued = false;
    const PAGE_THEME_GAP_MS = 100;
    const themeTouched = (records) => {
      let page = false;
      for (const r of records) {
        if (r.type === "childList") {
          for (const n of r.addedNodes) if (n.nodeName === "META") return "meta";
          for (const n of r.removedNodes) if (n.nodeName === "META") return "meta";
        } else if (r.target.nodeName === "META") return "meta";
        else if ((r.target === document.documentElement || r.target === document.body) && r.oldValue !== r.target.getAttribute(r.attributeName)) page = true;
      }
      return page ? "page" : null;
    };
    const queueTheme = () => {
      if (themeQueued) return;
      themeQueued = true;
      nextFrame(() => {
        themeQueued = false;
        reportTheme();
      });
    };
    const scheduleTheme = () => {
      metaCache = undefined;
      queueTheme();
    };
    const queuePageTheme = () => {
      if (pageThemeQueued) return;
      pageThemeQueued = true;
      after(() => {
        pageThemeQueued = false;
        queueTheme();
      }, PAGE_THEME_GAP_MS);
    };
    const themeChanged = (records) => {
      const touched = themeTouched(records);
      if (touched === "meta") scheduleTheme();
      else if (touched === "page") queuePageTheme();
    };
    const startTheme = () => {
      reportTheme();
      const observer = new NativeMutationObserver(themeChanged);
      observer.observe(document.head || document.documentElement, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ["content", "media", "name"],
      });
      for (const el of [document.documentElement, document.body])
        if (el) observer.observe(el, { attributes: true, attributeOldValue: true, attributeFilter: ["class", "style", "data-theme"] });
      for (const ms of [300, 1000, 3000]) after(scheduleTheme, ms);
    };
    onReady(startTheme);
    const resendTheme = () => {
      lastTheme = undefined;
      metaCache = undefined;
      reportTheme();
    };
    addEventListener("pageshow", (e) => e.persisted && resendTheme());
    document.addEventListener("prerenderingchange", resendTheme);
    addEventListener("load", scheduleTheme);
    let scrollSampleQueued = false;
    let scrollSampledAt = -Infinity;
    let scrolledPastTop = false;
    let scrollSettle = 0;
    let scrollSettled = false;
    const sampleScroll = guard((settled) => {
      if (!document.documentElement || (cachedMetaColor() && !lightMetaOnDarkPage)) return;
      const past = window.scrollY > 4;
      const now = performance.now();
      if (!settled && past === scrolledPastTop && now - scrollSampledAt < 150) return;
      scrolledPastTop = past;
      scrollSampledAt = now;
      reportTheme();
    });
    const queueScrollSample = () => {
      if (scrollSampleQueued) return;
      scrollSampleQueued = true;
      nextFrame(() =>
        after(() => {
          scrollSampleQueued = false;
          const settled = scrollSettled;
          scrollSettled = false;
          sampleScroll(settled);
        }, 0),
      );
    };
    const scrollTheme = () => {
      if (metaCache && !lightMetaOnDarkPage) return;
      apply(clearTimer, window, [scrollSettle]);
      scrollSettle = after(() => {
        scrollSettled = true;
        queueScrollSample();
      }, 150);
      queueScrollSample();
    };
    addEventListener("scroll", scrollTheme, { passive: true, capture: true });
    addEventListener("resize", scheduleTheme);
    matchMedia("(prefers-color-scheme: dark)").addEventListener("change", scheduleTheme);
  } catch (e) {}
"""#
}
