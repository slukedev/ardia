import { compareVersions, isNightly } from "../../lib/versions.ts";

export const PROTECTED_VIDEO_COUNTS = [
  "widevine_install_attempts",
  "widevine_install_successes",
  "widevine_install_failures",
  "drm_refusals",
  "drm_refusals_access",
  "drm_refusals_create_keys",
  "drm_refusals_licence",
  "drm_refusals_keystatus",
] as const;

export type ProtectedVideoCounts = {
  attempts: number;
  successes: number;
  failures: number;
  refusals: number;
  access: number;
  createKeys: number;
  licence: number;
  keystatus: number;
};

export type ProtectedVideoUsage = ProtectedVideoCounts & { version: string; people: number };

const rates = (c: ProtectedVideoCounts) => ({
  successRate: c.successes + c.failures ? c.successes / (c.successes + c.failures) : null,
  unstaged: Math.max(0, c.refusals - c.access - c.createKeys - c.licence - c.keystatus),
});

export function protectedVideoRows(usage: ProtectedVideoUsage[], cdm: { installed: number; reported: number }) {
  const total = usage.find((u) => u.version === "") ?? null;
  return {
    cdmInstalled: cdm.installed,
    cdmReported: cdm.reported,
    cdmShare: cdm.reported ? cdm.installed / cdm.reported : null,
    total: total ? { ...total, ...rates(total) } : null,
    versions: usage
      .filter((u) => u.version !== "" && (u.attempts || u.refusals))
      .map((u) => ({ ...u, nightly: isNightly(u.version), ...rates(u) }))
      .sort((a, b) => compareVersions(b.version, a.version)),
  };
}
