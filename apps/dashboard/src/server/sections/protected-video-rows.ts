import { compareVersions, isNightly } from "../../lib/versions.ts";

export const PROTECTED_VIDEO_COUNTS = [
  "drm_refusals",
  "drm_refusals_access",
  "drm_refusals_create_keys",
  "drm_refusals_licence",
  "drm_refusals_keystatus",
] as const;

export type ProtectedVideoCounts = {
  refusals: number;
  access: number;
  createKeys: number;
  licence: number;
  keystatus: number;
};

export type ProtectedVideoUsage = ProtectedVideoCounts & { version: string; people: number };

const withUnstaged = (c: ProtectedVideoCounts) => ({
  unstaged: Math.max(0, c.refusals - c.access - c.createKeys - c.licence - c.keystatus),
});

export function protectedVideoRows(usage: ProtectedVideoUsage[], cdm: { installed: number; reported: number }) {
  const total = usage.find((u) => u.version === "") ?? null;
  return {
    cdmInstalled: cdm.installed,
    cdmReported: cdm.reported,
    cdmShare: cdm.reported ? cdm.installed / cdm.reported : null,
    total: total ? { ...total, ...withUnstaged(total) } : null,
    versions: usage
      .filter((u) => u.version !== "" && u.refusals)
      .map((u) => ({ ...u, nightly: isNightly(u.version), ...withUnstaged(u) }))
      .sort((a, b) => compareVersions(b.version, a.version)),
  };
}
