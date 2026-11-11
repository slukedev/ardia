import { startChromeVaultWatch } from "./google";
import { startGoogleImports } from "./googleImport";
import { startVaultMenus } from "./menu";
import { startVaultIndex } from "./store";
import { startVaultTouchID } from "./touchID";

export function startVaults() {
  startVaultIndex();
  startVaultMenus();
  startVaultTouchID();
  startGoogleImports();
  startChromeVaultWatch();
}
