import { useEffect, useRef, useState } from "react";
import { Animated } from "react-native";
import { curve, duration, period } from "./motion";
import { Symbol } from "./native";
import { reduceMotion } from "./reduceMotion";
import { useTheme } from "./theme";
import { syncGlyph, type SyncGlyphSize } from "./tokens";

const SYNC_SYMBOL = "arrow.triangle.2.circlepath";
const FULL_TURN = ["0deg", "360deg"];

export function SyncGlyph({ active, size = "body", color, tooltip, label = "Syncing" }: { active: boolean; size?: SyncGlyphSize; color?: string; tooltip?: string; label?: string }) {
  const theme = useTheme();
  const [mounted, setMounted] = useState(active);
  if (active && !mounted) setMounted(true);
  const shown = useRef(new Animated.Value(active ? 1 : 0)).current;
  const turn = useRef(new Animated.Value(0)).current;
  useEffect(() => {
    const fade = Animated.timing(shown, { toValue: active ? 1 : 0, duration: duration.base, easing: active ? curve.enter : curve.fade, useNativeDriver: true });
    fade.start(({ finished }) => finished && !active && setMounted(false));
    return () => fade.stop();
  }, [active]);
  useEffect(() => {
    if (!mounted || reduceMotion()) return;
    turn.setValue(0);
    const loop = Animated.loop(Animated.timing(turn, { toValue: 1, duration: period.sync, easing: curve.linear, useNativeDriver: true }));
    loop.start();
    return () => loop.stop();
  }, [mounted]);
  if (!mounted) return null;
  const { box, glyph } = syncGlyph[size];
  const frame = { width: box, height: box };
  return (
    <Animated.View
      tooltip={tooltip}
      accessible
      accessibilityRole="image"
      accessibilityLabel={label}
      style={[frame, { opacity: shown, transform: [{ rotate: turn.interpolate({ inputRange: [0, 1], outputRange: FULL_TURN }) }] }]}
    >
      <Symbol name={SYNC_SYMBOL} size={glyph} color={color ?? theme.textSecondary} style={frame} />
    </Animated.View>
  );
}
