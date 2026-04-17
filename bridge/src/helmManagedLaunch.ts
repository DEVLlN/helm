export const HELM_RUNTIME_LAUNCH_SOURCE = "helm-runtime-wrapper";
export const HELM_LEGACY_SHELL_LAUNCH_SOURCE = "helm-shell-wrapper";

export function isHelmManagedLaunchSource(source: string | null | undefined): boolean {
  return source === HELM_RUNTIME_LAUNCH_SOURCE || source === HELM_LEGACY_SHELL_LAUNCH_SOURCE;
}
