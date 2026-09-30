/**
 * The Audio tab, 1:1 with AudioSettingsPaneAppKit: three volume pills
 * (AudioVolumeRow) — title + live speaker glyph inside the pill (the glyph
 * flips to its muted variant at 0), percent readout, 5% steps. Voice Over
 * boosts to 150%.
 */
import { PillSlider } from "../kit";
import { Box, PaneStack } from "./layout";
import { pctRounded } from "./shared";
import type { PaneProps } from "./types";

export function AudioPane({ settings: s, onSettingsChange, onCommit }: PaneProps) {
  const commit = () => onCommit?.();
  return (
    <PaneStack
      items={[
        {
          key: "audio",
          render: (first) => (
            <Box
              title="Audio"
              first={first}
              rows={[
                {
                  key: "system",
                  node: (
                    <PillSlider
                      title="System Audio"
                      symbol={s.systemAudioVolume > 0 ? "speaker.wave.2" : "speaker.slash"}
                      value={s.systemAudioVolume}
                      min={0}
                      max={1}
                      step={0.05}
                      format={pctRounded}
                      onChange={(v) => onSettingsChange({ systemAudioVolume: v })}
                      onCommit={commit}
                    />
                  ),
                },
                {
                  key: "mic",
                  node: (
                    <PillSlider
                      title="Microphone"
                      symbol={s.microphoneVolume > 0 ? "mic" : "mic.slash"}
                      value={s.microphoneVolume}
                      min={0}
                      max={1}
                      step={0.05}
                      format={pctRounded}
                      onChange={(v) => onSettingsChange({ microphoneVolume: v })}
                      onCommit={commit}
                    />
                  ),
                },
                {
                  key: "voice",
                  node: (
                    <PillSlider
                      title="Voice Over"
                      symbol={s.voiceOverVolume > 0 ? "waveform.and.mic" : "mic.slash"}
                      value={s.voiceOverVolume}
                      min={0}
                      max={1.5}
                      step={0.05}
                      format={pctRounded}
                      onChange={(v) => onSettingsChange({ voiceOverVolume: v })}
                      onCommit={commit}
                    />
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
