import { WIDEVINE_COMPONENT_ID, type EngineComponent } from "../../platform/app";

const NOT_INSTALLED = "0.0.0.0";
const DOWNLOADING: EngineComponent["state"][] = ["checking", "canUpdate", "downloading", "decompressing", "patching", "updating"];

export const widevineOf = (components: EngineComponent[]) => components.find((c) => c.id === WIDEVINE_COMPONENT_ID) ?? null;

export const widevineVersion = (component: EngineComponent | null | undefined) => (component && component.version !== NOT_INSTALLED ? component.version : null);

export const widevineDownloading = (component: EngineComponent | null | undefined) => !!component && !widevineVersion(component) && DOWNLOADING.includes(component.state);
