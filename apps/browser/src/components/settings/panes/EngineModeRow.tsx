import { View } from "react-native";
import { defaultEngine, type EngineMode, ENGINE_NAMES } from "../../../state/engines/engines";
import { setEngineMode } from "../../../state/engines/actions";
import { useEngineMode } from "../../../state/engines/hooks";
import { engineModeFooter } from "../../../state/engines/engineModeCopy";
import { useSettings } from "../../../state/browser/hooks";
import { SETTINGS_WINDOW_ID } from "../../../state/settings/settingsWindows";
import { Button, Segmented, type SegmentOption } from "../../ui";
import { Row } from "../Form";
import { showWebKitLimits, ABOUT_ENGINES_TITLE } from "./WebKitLimitsSheet";

const MODE_OPTIONS: SegmentOption<EngineMode>[] = [
  { value: "automatic", title: "Automatic" },
  { value: "chromium", title: ENGINE_NAMES.chromium },
  { value: "webkit", title: ENGINE_NAMES.webkit },
];

export function EngineModeRow({ anchor }: { anchor: "general.engineMode" }) {
  const { mode, switching } = useEngineMode();
  const opensIn = useSettings((settings) => defaultEngine({ settings }));
  const streamingInWebKit = useSettings((s) => s.protectedVideoInWebKit);
  const description = engineModeFooter({ mode, switching, defaultEngine: opensIn, streamingInWebKit });
  return (
    <Row anchor={anchor} description={description}>
      <View pointerEvents={switching ? "none" : "auto"}>
        <Segmented options={MODE_OPTIONS} value={mode} onChange={(next) => void setEngineMode(next, { windowId: SETTINGS_WINDOW_ID })} />
      </View>
      <Button variant="icon" icon="info.circle" size="m" onPress={() => showWebKitLimits("engineRow")} tooltip={ABOUT_ENGINES_TITLE} />
    </Row>
  );
}
