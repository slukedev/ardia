import Foundation

enum WebKitExtensionShim {
  static let fileName = "__ardia_webkit_shim.js"
  static let application = "dev.ardia.webkit"

  static func source(apis: Set<String>) -> String {
    let list = (try? JSONSerialization.data(withJSONObject: apis.sorted())).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    return template.replacingOccurrences(of: "__ARDIA_APP__", with: "\"\(application)\"").replacingOccurrences(of: "__ARDIA_APIS__", with: list)
  }

  static let template = #"""
    (() => {
      const root = globalThis;
      if (root.__ardiaWebKitShim) return;
      Object.defineProperty(root, "__ardiaWebKitShim", { value: true });
      const ns = root.browser || root.chrome;
      const runtime = ns && ns.runtime;
      if (!runtime || typeof runtime.sendNativeMessage !== "function") return;
      const APP = __ARDIA_APP__;
      const APIS = __ARDIA_APIS__;
      const send = runtime.sendNativeMessage.bind(runtime);
      const connect = typeof runtime.connectNative === "function" ? runtime.connectNative.bind(runtime) : null;
      const tabsApi = ns.tabs;
      const windowsApi = ns.windows;
      const bound = (object, name) => (object && typeof object[name] === "function" ? object[name].bind(object) : null);
      const tabsGet = bound(tabsApi, "get");
      const tabsQuery = bound(tabsApi, "query");
      const windowsGetAll = bound(windowsApi, "getAll");
      const windowsGetCurrent = bound(windowsApi, "getCurrent");
      const settle = (value) => Promise.resolve(value);

      const windowIds = async () => {
        if (!windowsGetAll) return [];
        try {
          return (await settle(windowsGetAll({}))).map((w) => w.id);
        } catch (error) {
          return [];
        }
      };
      const currentWindow = async () => {
        if (!windowsGetCurrent) return -1;
        try {
          return (await settle(windowsGetCurrent({}))).id;
        } catch (error) {
          return -1;
        }
      };
      const describeTab = (tab, order) => ({ window: order.indexOf(tab.windowId), index: tab.index, url: tab.url || tab.pendingUrl || "" });

      const prepare = async (args) => {
        const order = await windowIds();
        const refs = [];
        const tabRef = async (id) => {
          if (typeof id !== "number" || !tabsGet) return -1;
          try {
            refs.push(describeTab(await settle(tabsGet(id)), order));
          } catch (error) {
            refs.push(null);
          }
          return refs.length - 1;
        };
        const windowRef = async (id) => {
          if (typeof id !== "number") return -1;
          return order.indexOf(id === -2 ? await currentWindow() : id);
        };
        const prepared = [];
        for (const arg of args) {
          if (!arg || typeof arg !== "object" || Array.isArray(arg)) {
            prepared.push(arg);
            continue;
          }
          const copy = Object.assign({}, arg);
          if ("tabId" in copy) copy.tabId = { __tab: await tabRef(copy.tabId) };
          if ("tabIds" in copy) {
            const ids = Array.isArray(copy.tabIds) ? copy.tabIds : [copy.tabIds];
            const marked = [];
            for (const id of ids) marked.push({ __tab: await tabRef(id) });
            copy.tabIds = marked;
          }
          if ("windowId" in copy) copy.windowId = { __window: await windowRef(copy.windowId) };
          if (copy.createProperties && typeof copy.createProperties === "object" && "windowId" in copy.createProperties) {
            copy.createProperties = Object.assign({}, copy.createProperties, { windowId: { __window: await windowRef(copy.createProperties.windowId) } });
          }
          prepared.push(copy);
        }
        return { args: prepared, tabs: refs };
      };

      const placeWindows = async (value, windows) => {
        if (!value || typeof value !== "object") return value;
        const order = await windowIds();
        const ordinal = (keys) => (windows || []).findIndex((list) => Array.isArray(list) && list.some((key) => keys.includes(key)));
        const visit = (item) => {
          if (Array.isArray(item)) return item.map(visit);
          if (!item || typeof item !== "object") return item;
          if (Array.isArray(item.__windowTabs)) {
            const at = ordinal(item.__windowTabs);
            return at >= 0 && at < order.length ? order[at] : -1;
          }
          const out = {};
          for (const [key, inner] of Object.entries(item)) out[key] = visit(inner);
          return out;
        };
        return visit(value);
      };

      const request = async (api, method, args) => {
        const prepared = await prepare(args);
        const reply = await settle(send(APP, { ardia: 1, api, method, args: prepared.args, tabs: prepared.tabs }));
        if (!reply || typeof reply !== "object") throw new Error(`Ardia didn't answer ${api}.${method}.`);
        if (typeof reply.error === "string") throw new Error(reply.error);
        return placeWindows(reply.result, reply.windows);
      };

      const withCallback = (run) =>
        function (...args) {
          const callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
          const done = run(...args);
          if (!callback) return done;
          done.then(
            (value) => callback(value),
            (error) => {
              console.error(error);
              callback();
            },
          );
          return undefined;
        };

      const listeners = new Map();
      let port = null;
      let retry = null;
      const listened = () => [...new Set([...listeners].filter(([, set]) => set.size).map(([key]) => key.split(".")[0]))];
      const dispatch = async (message) => {
        if (!message || message.ardia !== 1 || typeof message.api !== "string") return;
        const set = listeners.get(`${message.api}.${message.event}`);
        if (!set || !set.size) return;
        const args = await placeWindows(Array.isArray(message.args) ? message.args : [], message.windows);
        for (const listener of [...set]) {
          try {
            listener(...args);
          } catch (error) {
            console.error(error);
          }
        }
      };
      const announce = () => {
        const apis = listened();
        if (!port && apis.length && connect) {
          try {
            port = connect(APP);
            port.onMessage.addListener(dispatch);
            port.onDisconnect.addListener(() => {
              port = null;
              if (listened().length && !retry) retry = setTimeout(() => ((retry = null), announce()), 1000);
            });
          } catch (error) {
            port = null;
          }
        }
        if (port) port.postMessage({ ardia: 1, listen: apis });
      };
      const event = (api, name) => {
        const key = `${api}.${name}`;
        return {
          addListener(listener) {
            if (typeof listener !== "function") return;
            if (!listeners.has(key)) listeners.set(key, new Set());
            listeners.get(key).add(listener);
            announce();
          },
          removeListener(listener) {
            const set = listeners.get(key);
            if (set && set.delete(listener)) announce();
          },
          hasListener(listener) {
            const set = listeners.get(key);
            return !!set && set.has(listener);
          },
          hasListeners() {
            const set = listeners.get(key);
            return !!set && set.size > 0;
          },
        };
      };
      const api = (name, methods, events, extra) => {
        const object = Object.assign({}, extra || {});
        for (const method of methods) object[method] = withCallback((...args) => request(name, method, args));
        for (const e of events) object[e] = event(name, e);
        return object;
      };
      const define = (name, object) => {
        if (!APIS.includes(name)) return;
        for (const target of new Set([root.chrome, root.browser])) {
          if (!target || target[name]) continue;
          try {
            Object.defineProperty(target, name, { value: object, configurable: true, enumerable: true, writable: true });
          } catch (error) {}
        }
      };

      define("downloads", api(
        "downloads",
        ["download", "search", "pause", "resume", "cancel", "erase", "open", "show", "showDefaultFolder", "removeFile", "acceptDanger", "getFileIcon", "setUiOptions", "setShelfEnabled"],
        ["onCreated", "onChanged", "onErased", "onDeterminingFilename"],
        {
          State: { IN_PROGRESS: "in_progress", INTERRUPTED: "interrupted", COMPLETE: "complete" },
          FilenameConflictAction: { UNIQUIFY: "uniquify", OVERWRITE: "overwrite", PROMPT: "prompt" },
        },
      ));
      define("history", api("history", ["search", "getVisits", "addUrl", "deleteUrl", "deleteRange", "deleteAll"], ["onVisited", "onVisitRemoved"]));
      define("bookmarks", api(
        "bookmarks",
        ["get", "getChildren", "getRecent", "getTree", "getSubTree", "search", "create", "move", "update", "remove", "removeTree"],
        ["onCreated", "onRemoved", "onChanged", "onMoved", "onChildrenReordered", "onImportBegan", "onImportEnded"],
        { MAX_WRITE_OPERATIONS_PER_HOUR: 1000000, MAX_SUSTAINED_WRITE_OPERATIONS_PER_MINUTE: 1000000 },
      ));
      define("sidePanel", api("sidePanel", ["setOptions", "getOptions", "setPanelBehavior", "getPanelBehavior", "open", "close", "getLayout"], ["onOpened", "onClosed"]));

      if (APIS.includes("tabGroups")) {
        define("tabGroups", api("tabGroups", ["get", "query", "update", "move"], ["onCreated", "onUpdated", "onRemoved", "onMoved"], {
          TAB_GROUP_ID_NONE: -1,
          Color: { GREY: "grey", BLUE: "blue", RED: "red", YELLOW: "yellow", GREEN: "green", PINK: "pink", PURPLE: "purple", CYAN: "cyan", ORANGE: "orange" },
        }));
        const groupIdsOf = async (tabs) => {
          if (!tabs.length) return [];
          const order = await windowIds();
          const reply = await settle(send(APP, { ardia: 1, api: "tabGroups", method: "groupIdsOf", args: [], tabs: tabs.map((t) => describeTab(t, order)) }));
          return reply && Array.isArray(reply.result) ? reply.result : tabs.map(() => -1);
        };
        const withGroups = async (tabs) => {
          const ids = await groupIdsOf(tabs);
          return tabs.map((tab, i) => Object.assign({}, tab, { groupId: typeof ids[i] === "number" ? ids[i] : -1 }));
        };
        if (tabsApi && !tabsApi.group) {
          const tabCalls = {
            group: withCallback((options) => request("tabGroups", "group", [options || {}])),
            ungroup: withCallback((tabIds) => request("tabGroups", "ungroup", [{ tabIds }])),
          };
          if (tabsQuery) {
            tabCalls.query = withCallback(async (info) => {
              const query = Object.assign({}, info || {});
              const wanted = query.groupId;
              delete query.groupId;
              const tabs = await withGroups(await settle(tabsQuery(query)));
              return typeof wanted === "number" ? tabs.filter((t) => t.groupId === wanted) : tabs;
            });
          }
          if (tabsGet) tabCalls.get = withCallback(async (id) => (await withGroups([await settle(tabsGet(id))]))[0]);
          for (const target of new Set([root.chrome && root.chrome.tabs, root.browser && root.browser.tabs])) {
            if (!target) continue;
            for (const [name, value] of Object.entries(tabCalls)) {
              try {
                Object.defineProperty(target, name, { value, configurable: true, enumerable: true, writable: true });
              } catch (error) {}
            }
          }
        }
      }
    })();
    """#
}
