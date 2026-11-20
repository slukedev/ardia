extension WebKitNotifications {
  static let pageShim = #"""
(() => {
  if (window.__ardiaNotifications) return;
  window.__ardiaNotifications = true;
  const apply = Reflect.apply;
  const dispatch = EventTarget.prototype.dispatchEvent;
  const listen = EventTarget.prototype.addEventListener;
  const detailOf = Object.getOwnPropertyDescriptor(CustomEvent.prototype, "detail").get;
  const Custom = CustomEvent;
  const Plain = Event;
  const { stringify, parse } = JSON;
  const doc = document;
  const live = new Map();
  const requests = new Map();
  let permission = "default";
  let next = 0;
  const token = Math.random().toString(36).slice(2, 10);
  const send = (detail) => {
    try {
      apply(dispatch, doc, [new Custom("ardia:notification", { detail: stringify(detail) })]);
    } catch (e) {}
  };
  const fire = (n, type) => {
    const event = new Plain(type);
    try {
      apply(dispatch, n, [event]);
    } catch (e) {}
    const handler = n["on" + type];
    if (typeof handler === "function") {
      try {
        handler.call(n, event);
      } catch (e) {}
    }
  };
  const ids = new WeakMap();
  class Notification extends EventTarget {
    constructor(title, options) {
      super();
      if (arguments.length === 0) throw new TypeError("Failed to construct 'Notification': 1 argument required, but only 0 present.");
      const o = options || {};
      this.title = String(title);
      this.body = o.body === undefined ? "" : String(o.body);
      this.tag = o.tag === undefined ? "" : String(o.tag);
      this.icon = o.icon ? String(new URL(String(o.icon), location.href)) : "";
      this.silent = !!o.silent;
      this.requireInteraction = !!o.requireInteraction;
      this.data = o.data === undefined ? null : o.data;
      this.dir = o.dir || "auto";
      this.lang = o.lang || "";
      this.badge = "";
      this.image = "";
      this.renotify = !!o.renotify;
      this.timestamp = Date.now();
      this.actions = [];
      this.onclick = this.onclose = this.onerror = this.onshow = null;
      const id = "n" + token + "-" + ++next;
      ids.set(this, id);
      live.set(id, this);
      queueMicrotask(() => {
        if (permission !== "granted") {
          live.delete(id);
          return fire(this, "error");
        }
        send({ type: "show", id, title: this.title, body: this.body, icon: this.icon, tag: this.tag, silent: this.silent, requireInteraction: this.requireInteraction });
        fire(this, "show");
      });
    }
    close() {
      const id = ids.get(this);
      if (!live.delete(id)) return;
      send({ type: "close", id });
      fire(this, "close");
    }
    static get permission() {
      return permission;
    }
    static get maxActions() {
      return 0;
    }
    static requestPermission(callback) {
      return new Promise((resolve) => {
        if (permission !== "default") {
          if (typeof callback === "function") callback(permission);
          return resolve(permission);
        }
        const id = "p" + ++next;
        requests.set(id, (answer) => {
          permission = answer;
          if (typeof callback === "function") {
            try {
              callback(answer);
            } catch (e) {}
          }
          resolve(answer);
        });
        send({ type: "request", id });
      });
    }
  }
  Object.defineProperty(window, "Notification", { configurable: true, writable: true, value: Notification });
  const listings = new Map();
  class ShownNotification {
    constructor(entry) {
      this.title = String(entry.title || "");
      this.body = String(entry.body || "");
      this.tag = String(entry.tag || "");
      this.icon = String(entry.icon || "");
      this.data = entry.data === undefined ? null : entry.data;
      this.silent = !!entry.silent;
      this.requireInteraction = !!entry.requireInteraction;
      this.timestamp = Number(entry.timestamp) || 0;
      this.dir = "auto";
      this.lang = "";
      this.badge = "";
      this.image = "";
      this.renotify = false;
      this.actions = [];
      ids.set(this, String(entry.id));
    }
    close() {
      const id = ids.get(this);
      if (id) send({ type: "close", id });
    }
  }
  const Registration = window.ServiceWorkerRegistration;
  const scopeOf = Registration && Object.getOwnPropertyDescriptor(Registration.prototype, "scope");
  const activeOf = Registration && Object.getOwnPropertyDescriptor(Registration.prototype, "active");
  if (scopeOf && scopeOf.get && activeOf && activeOf.get) {
    const reject = Promise.reject.bind(Promise);
    const resolve = Promise.resolve.bind(Promise);
    const define = (name, value) => Object.defineProperty(Registration.prototype, name, { configurable: true, writable: true, value });
    const nativeShow = Registration.prototype.showNotification;
    const nativeList = Registration.prototype.getNotifications;
    define("showNotification", {
      showNotification(title, options) {
        let scope = "";
        try {
          scope = apply(scopeOf.get, this, []);
        } catch (e) {
          return reject(new TypeError("Illegal invocation"));
        }
        if (arguments.length === 0) return reject(new TypeError("Failed to execute 'showNotification' on 'ServiceWorkerRegistration': 1 argument required, but only 0 present."));
        if (!apply(activeOf.get, this, [])) return reject(new TypeError("No active registration available on the ServiceWorkerRegistration."));
        if (permission !== "granted") return reject(new TypeError("No notification permission has been granted for this origin."));
        const o = options || {};
        const shim = () => {
          let data = null;
          try {
            data = o.data === undefined ? null : parse(stringify(o.data));
          } catch (e) {}
          send({
            type: "show", id: "s" + token + "-" + ++next, persistent: true, scope, title: String(title), body: o.body === undefined ? "" : String(o.body),
            icon: o.icon ? String(new URL(String(o.icon), location.href)) : "", tag: o.tag === undefined ? "" : String(o.tag),
            silent: !!o.silent, requireInteraction: !!o.requireInteraction, data, timestamp: Date.now(),
          });
        };
        if (typeof nativeShow !== "function") return resolve(shim());
        return apply(nativeShow, this, [title, options]).then(undefined, (error) => {
          if (!(error instanceof TypeError)) throw error;
          shim();
        });
      },
    }.showNotification);
    define("getNotifications", {
      getNotifications(filter) {
        let scope = "";
        try {
          scope = apply(scopeOf.get, this, []);
        } catch (e) {
          return reject(new TypeError("Illegal invocation"));
        }
        const tag = filter && filter.tag !== undefined ? String(filter.tag) : "";
        const natives = typeof nativeList === "function" ? apply(nativeList, this, [filter]).then(undefined, () => []) : resolve([]);
        const shimmed = new Promise((done) => {
          const id = "g" + ++next;
          listings.set(id, (items) => done(Array.isArray(items) ? items.map((entry) => new ShownNotification(entry)) : []));
          send({ type: "list", id, scope, tag });
        });
        return Promise.all([natives, shimmed]).then(([a, b]) => [...a, ...b]);
      },
    }.getNotifications);
  }
  apply(listen, doc, [
    "ardia:notification-reply",
    (e) => {
      let reply = null;
      try {
        reply = parse(apply(detailOf, e, []));
      } catch (error) {}
      if (!reply || typeof reply.type !== "string") return;
      if (reply.type === "permission") permission = reply.value;
      else if (reply.type === "answer") {
        const done = requests.get(reply.id);
        requests.delete(reply.id);
        if (done) done(reply.value);
      } else if (reply.type === "list") {
        const done = listings.get(reply.id);
        listings.delete(reply.id);
        if (done) done(reply.items);
      } else if (reply.type === "click" || reply.type === "close") {
        const n = live.get(reply.id);
        if (!n) return;
        if (reply.type === "close") live.delete(reply.id);
        fire(n, reply.type);
      }
    },
    true,
  ]);
})();
"""#

  static let worldBridge = #"""
(() => {
  if (window.__ardiaNotificationBridge) return;
  window.__ardiaNotificationBridge = true;
  document.addEventListener("ardia:notification", (e) => {
    let detail = null;
    try {
      detail = JSON.parse(e.detail);
    } catch (error) {}
    if (!detail || typeof detail.type !== "string") return;
    try {
      window.webkit.messageHandlers.ardia.postMessage({ kind: "notification", data: detail, frame: "notifications" });
    } catch (error) {}
  }, true);
})();
"""#
}
