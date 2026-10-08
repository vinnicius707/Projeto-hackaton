import { azureDevOpsConfig, azureDevOpsSnapshot } from "./sources/azure-devops";
import { demoSnapshot } from "./sources/demo";
import type { Snapshot } from "./types";

/** Azure DevOps when AZDO_* env vars are set, demo data otherwise. */
export async function getSnapshot(): Promise<Snapshot> {
  const cfg = azureDevOpsConfig();
  return cfg ? azureDevOpsSnapshot(cfg) : demoSnapshot();
}
