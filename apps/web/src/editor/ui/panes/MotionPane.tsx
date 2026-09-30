/**
 * The Motion tab, 1:1 with MotionFeelPaneAppKit — HOW animations feel,
 * project-wide: transition speed chips with the live spring pad, the default
 * auto-zoom level and the cursor-follow speed. (Effects themselves live in
 * the Effects tab.)
 */
import { AnimationSpeed, animationSpeedDuration, enumValues } from "../../core/model/enums";
import { Chips, PillSlider } from "../kit";
import { Box, PaneStack } from "./layout";
import { MotionSpeedPad } from "./livePads";
import { Cap, fixed, pctRounded } from "./shared";
import type { PaneProps } from "./types";

const SPEEDS = enumValues(AnimationSpeed);

export function MotionPane({ settings: s, onSettingsChange, onCommit }: PaneProps) {
  const commit = () => onCommit?.();
  const index = SPEEDS.indexOf(s.animationSpeed);
  return (
    <PaneStack
      items={[
        {
          key: "motion",
          render: (first) => (
            <Box
              title="Motion"
              first={first}
              rows={[
                {
                  key: "speed",
                  node: (
                    <Chips
                      items={SPEEDS}
                      selectedIndex={index >= 0 ? index : 1}
                      onSelect={(i) => {
                        onSettingsChange({ animationSpeed: SPEEDS[i] });
                        commit();
                      }}
                      ariaLabel="Transition speed"
                    />
                  ),
                },
                { key: "pad", attached: true, node: <MotionSpeedPad duration={animationSpeedDuration(s.animationSpeed)} /> },
                {
                  key: "speedCap",
                  attached: true,
                  node: (
                    <Cap line full="How quickly zoom and tilt transitions animate. Slower feels more cinematic.">
                      How quickly zoom and tilt transitions animate.
                    </Cap>
                  ),
                },
                {
                  key: "zoom",
                  node: (
                    <PillSlider title="Zoom Level" value={s.autoZoomLevel} min={1.5} max={4} step={0.1} format={fixed(1, "x")} onChange={(v) => onSettingsChange({ autoZoomLevel: v })} onCommit={commit} />
                  ),
                },
                { key: "zoomCap", attached: true, node: <Cap line>Default zoom level for auto-generated zoom regions.</Cap> },
                {
                  key: "follow",
                  node: (
                    <PillSlider title="Follow Speed" value={s.cameraFollowSpeed} min={0} max={1} step={0.05} format={pctRounded} onChange={(v) => onSettingsChange({ cameraFollowSpeed: v })} onCommit={commit} />
                  ),
                },
                {
                  key: "followCap",
                  attached: true,
                  node: (
                    <Cap line full="How quickly the zoomed camera chases the cursor — slower feels weightier.">
                      How quickly the zoomed camera chases the cursor.
                    </Cap>
                  ),
                },
              ]}
            />
          ),
        },
      ]}
    />
  );
}
