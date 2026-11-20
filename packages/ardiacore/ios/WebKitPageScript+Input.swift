extension WebKitPageScript {
  static let scroll = #"""
  if (isTop) {
    const scrollDirection = () => {
      const DOWN = 24, UP = 12, MIN_RANGE = 120, SETTLE = 300, GESTURE = 300;
      const paged = (snap, vertical) => {
        const [axis, strictness] = snap.split(" ");
        return strictness === "mandatory" && (axis === "y" || axis === "both" || axis === (vertical ? "inline" : "block"));
      };
      let anchor = 0, last = 0, lastAt = -1e9, settleUntil = -1e9, budget = 0, height = 0, sent = null, gestureSent = false, heading = 0;
      const resized = (viewport, now) => {
        if (now >= settleUntil) budget = 0;
        if (height && viewport !== height) {
          settleUntil = now + SETTLE;
          budget += Math.abs(viewport - height) + 2;
        }
        height = viewport;
      };
      return {
        resized,
        rebase(y) {
          anchor = last = y;
        },
        wheeled(deltaX, deltaY, pinch) {
          if (pinch || !deltaY) {
            if (pinch || deltaX) heading = 0;
            return;
          }
          heading = deltaY > 0 ? 1 : -1;
        },
        undirected() {
          heading = 0;
        },
        scrolled(y, range, viewport, now, user, snap = "", vertical = false) {
          resized(viewport, now);
          if (now - lastAt > GESTURE) {
            gestureSent = false;
            anchor = last;
          }
          lastAt = now;
          const moved = y - last;
          last = y;
          if (budget > 0 && moved) {
            const absorbed = Math.min(budget, Math.abs(moved));
            budget -= absorbed;
            anchor += moved > 0 ? absorbed : -absorbed;
          }
          let state = null;
          if (y <= 2) state = "top";
          else if (!user || moved * heading < 0) anchor = y;
          else if (y - anchor >= DOWN) {
            if (range >= MIN_RANGE && !paged(snap, vertical)) state = "down";
            else anchor = y;
          } else if (anchor - y >= UP) state = "up";
          else if (sent === "down" ? gestureSent && y > anchor : y < anchor) anchor = y;
          if (state) anchor = y;
          if (!state || (state === sent && (state !== "down" || gestureSent))) return null;
          sent = state;
          if (state === "down") gestureSent = true;
          return state;
        },
      };
    };
    const direction = scrollDirection();
    let scroller = null;
    let scrollTarget = null;
    let inputAt = -1e9;
    const noteInput = () => {
      inputAt = performance.now();
      if (!scroller && document.scrollingElement) direction.rebase((scroller = document.scrollingElement).scrollTop);
    };
    const noteUndirectedInput = () => {
      direction.undirected();
      noteInput();
    };
    addEventListener(
      "wheel",
      (e) => {
        direction.wheeled(e.deltaX, e.deltaY, e.ctrlKey);
        noteInput();
      },
      { passive: true, capture: true },
    );
    for (const type of ["keydown", "mousedown", "touchstart"]) addEventListener(type, noteUndirectedInput, { passive: true, capture: true });
    addEventListener("mousemove", (e) => e.buttons && noteUndirectedInput(), { passive: true, capture: true });
    const measureScroll = () => {
      try {
        const target = scrollTarget;
        scrollTarget = null;
        const doc = document.scrollingElement || document.documentElement;
        const el = target === document || target === doc ? doc : target;
        if (!el || !doc || (el !== doc && (el.clientHeight < innerHeight * 0.5 || el.clientWidth < innerWidth * 0.5))) return;
        if (el !== scroller) direction.rebase((scroller = el).scrollTop);
        const now = performance.now();
        const style = getComputedStyle(el === doc ? document.documentElement : el);
        const state = direction.scrolled(el.scrollTop, el.scrollHeight - el.clientHeight, innerHeight, now, now - inputAt < 1000, style.scrollSnapType, /^(vertical|sideways)/.test(style.writingMode));
        if (state) post("scroll", { state });
      } catch (e) {}
    };
    addEventListener(
      "scroll",
      (e) => {
        if (!scrollTarget) requestAnimationFrame(measureScroll);
        scrollTarget = e.target;
      },
      { passive: true, capture: true },
    );
    addEventListener("resize", () => direction.resized(innerHeight, performance.now()));
  }
"""#

  static let selection = #"""
  {
    const send = post;
    const apply = Reflect.apply;
    const guard = (fn) =>
      function () {
        try {
          return apply(fn, this, arguments);
        } catch (e) {}
      };
    let selectionShown = false;
    let selecting = false;
    const hideSelection = () => {
      if (!selectionShown) return;
      selectionShown = false;
      send("selection", null);
    };
    const editableSelection = (sel) => {
      const active = document.activeElement;
      if (active && (active.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(active.tagName))) return true;
      const node = sel.anchorNode;
      const el = node && (node.nodeType === 1 ? node : node.parentElement);
      return !!el && el.isContentEditable;
    };
    const reportSelection = guard(() => {
      const sel = getSelection();
      const text = sel && !sel.isCollapsed && sel.rangeCount ? sel.toString().trim() : "";
      const pinched = window.visualViewport && visualViewport.scale !== 1;
      if (!text || pinched || editableSelection(sel)) return hideSelection();
      const r = sel.getRangeAt(0).getBoundingClientRect();
      if (!r.width && !r.height) return hideSelection();
      selectionShown = true;
      send("selection", { text: text.slice(0, 2000), rect: { x: r.left, y: r.top, width: r.width, height: r.height } });
    });
    const selectionListeners = [
      [
        document,
        "mousedown",
        (e) => {
          selecting = e.button === 0;
          hideSelection();
        },
        true,
      ],
      [
        document,
        "mouseup",
        (e) => {
          if (e.button !== 0 || !selecting) return;
          selecting = false;
          setTimeout(reportSelection, 0);
        },
        true,
      ],
      [document, "selectionchange", () => selectionShown && !selecting && getSelection().isCollapsed && hideSelection(), false],
      [document, "keydown", (e) => e.metaKey || /^(Shift|Meta|Alt|Control)$/.test(e.key) || hideSelection(), true],
      [window, "scroll", hideSelection, { passive: true, capture: true }],
      [window, "resize", hideSelection, false],
      [window, "pagehide", hideSelection, false],
    ];
    let selectionListening = false;
    handlers.selectionPopover = (on) => {
      if (!on === !selectionListening) return;
      selectionListening = !!on;
      if (!on) {
        selecting = false;
        hideSelection();
      }
      for (const [target, type, listener, options] of selectionListeners)
        on ? target.addEventListener(type, listener, options) : target.removeEventListener(type, listener, options);
    };
    handlers.selectionPopover(true);

    if (isTop) try {
      const DRAG_MIN = 40;
      const getter = (proto, name) => {
        const get = Object.getOwnPropertyDescriptor(proto, name).get;
        return (o) => apply(get, o, []);
      };
      const target = getter(Event.prototype, "target");
      const nodeType = getter(Node.prototype, "nodeType");
      const parent = getter(Node.prototype, "parentElement");
      const closest = Element.prototype.closest;
      const href = getter(HTMLAnchorElement.prototype, "href");
      const transfer = getter(DragEvent.prototype, "dataTransfer");
      const dropEffect = getter(DataTransfer.prototype, "dropEffect");
      const [clientX, clientY, screenX, screenY] = ["clientX", "clientY", "screenX", "screenY"].map((n) => getter(MouseEvent.prototype, n));
      const width = getter(window, "innerWidth");
      const height = getter(window, "innerHeight");
      const test = RegExp.prototype.test;
      const { hypot } = Math;
      let linkDrag = null;
      document.addEventListener(
        "dragstart",
        guard((e) => {
          linkDrag = null;
          let el = target(e);
          if (!e.isTrusted || !el) return;
          if (nodeType(el) !== 1) el = parent(el);
          const a = el && apply(closest, el, ["a[href]"]);
          const url = a && href(a);
          if (url && apply(test, /^https?:/, [url])) linkDrag = { url, x: screenX(e), y: screenY(e) };
        }),
        true,
      );
      document.addEventListener(
        "dragend",
        guard((e) => {
          const drag = linkDrag;
          linkDrag = null;
          const data = drag && e.isTrusted && transfer(e);
          if (!data || dropEffect(data) !== "none") return;
          const x = clientX(e), y = clientY(e);
          const over = x > 0 && y > 0 && x < width(window) && y < height(window);
          if (over && hypot(screenX(e) - drag.x, screenY(e) - drag.y) >= DRAG_MIN) send("linkDrop", { url: drag.url });
        }),
        true,
      );
    } catch (e) {}
  }
"""#
}
