const none = () => ({ installAttempts: 0, installSuccesses: 0, installFailures: 0, refusals: 0, access: 0, createMediaKeys: 0, licence: 0, keystatus: 0 });

let pending = none();

export type WidevineInstallStep = "attempt" | "success" | "failure";

const INSTALL_COUNTS = { attempt: "installAttempts", success: "installSuccesses", failure: "installFailures" } as const;
const REFUSAL_STAGES = ["access", "createMediaKeys", "licence", "keystatus"] as const;
type RefusalStage = (typeof REFUSAL_STAGES)[number];

const isRefusalStage = (stage: unknown): stage is RefusalStage => REFUSAL_STAGES.includes(stage as RefusalStage);

export function noteWidevineInstall(step: WidevineInstallStep) {
  pending[INSTALL_COUNTS[step]]++;
}

export function noteProtectedVideoRefusal({ stage }: { keySystem: string; stage?: string }) {
  pending.refusals++;
  if (isRefusalStage(stage)) pending[stage]++;
}

export function takeProtectedVideoCounts() {
  const taken = pending;
  pending = none();
  return {
    widevine_install_attempts: taken.installAttempts,
    widevine_install_successes: taken.installSuccesses,
    widevine_install_failures: taken.installFailures,
    drm_refusals: taken.refusals,
    drm_refusals_access: taken.access,
    drm_refusals_create_keys: taken.createMediaKeys,
    drm_refusals_licence: taken.licence,
    drm_refusals_keystatus: taken.keystatus,
  };
}
