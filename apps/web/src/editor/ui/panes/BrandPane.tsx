/**
 * The Brand tab, 1:1 with BrandSettingsPaneAppKit: watermark switch, the
 * 44pt logo thumbnail with Choose/Replace + Remove, and (while a logo is
 * shown) the free-drag position pad whose mark tracks Size and the logo's
 * aspect, with edge magnetism on release, plus Size / Opacity.
 */
import { useEffect, useState } from "react";

import type { ProjectSettings } from "../../core/model";
import { InspectorButton, PillSlider, SFIcon, ToggleRow } from "../kit";
import { Box, PaneStack } from "./layout";
import { WatermarkPad } from "./livePads";
import { hasPickerStatus, PickerStatusLine } from "./pickerStatus";
import { pctRounded } from "./shared";
import type { PaneProps } from "./types";

function useImageAspect(url: string | undefined) {
  const [aspect, setAspect] = useState<number | undefined>(undefined);
  useEffect(() => {
    setAspect(undefined);
    if (!url) return;
    const img = new Image();
    img.onload = () => img.naturalHeight > 0 && setAspect(img.naturalWidth / img.naturalHeight);
    img.src = url;
  }, [url]);
  return aspect;
}

export function BrandPane({ settings: s, onSettingsChange, onCommit, actions }: PaneProps) {
  const set = (patch: Partial<ProjectSettings>) => onSettingsChange(patch);
  const pick = (patch: Partial<ProjectSettings>) => {
    onSettingsChange(patch);
    onCommit?.();
  };
  const commit = () => onCommit?.();
  const fileName = s.watermarkFileName;
  const logoUrl = fileName ? actions?.assetUrl?.(fileName) : undefined;
  const aspect = useImageAspect(logoUrl);
  const details = s.showWatermark && fileName != null;

  return (
    <PaneStack
      items={[
        {
          key: "brand",
          render: (first) => (
            <Box
              title="Brand"
              first={first}
              rows={[
                { key: "show", node: <ToggleRow label="Show Watermark" checked={s.showWatermark} onChange={(v) => pick({ showWatermark: v })} /> },
                {
                  key: "logo",
                  node: (
                    <div className="cc-logorow">
                      <span className="cc-logothumb">{logoUrl ? <img src={logoUrl} alt="" /> : <SFIcon name="photo.badge.plus" size={14} weight="regular" />}</span>
                      <div className="cc-logobuttons">
                        <InspectorButton onClick={actions?.onChooseWatermark}>{fileName == null ? "Choose Logo…" : "Replace Logo…"}</InspectorButton>
                        {fileName != null && (
                          <InspectorButton
                            destructive
                            onClick={() => {
                              if (actions?.onRemoveWatermark) actions.onRemoveWatermark();
                              else pick({ watermarkFileName: undefined, showWatermark: false });
                            }}
                          >
                            Remove
                          </InspectorButton>
                        )}
                      </div>
                    </div>
                  ),
                },
                {
                  key: "status",
                  show: hasPickerStatus(actions?.pickerStatus?.watermark),
                  attached: true,
                  node: <PickerStatusLine status={actions?.pickerStatus?.watermark} />,
                },
              ]}
            />
          ),
        },
        {
          key: "position",
          show: details,
          render: (first) => (
            <Box
              title="Position"
              first={first}
              rows={[
                {
                  key: "pad",
                  node: (
                    <WatermarkPad
                      s={s}
                      logoUrl={logoUrl}
                      logoAspect={aspect}
                      onPlace={(x, y) => set({ watermarkX: x, watermarkY: y })}
                      onRelease={() => {
                        // Per-axis edge/corner magnetism.
                        const snap = (v: number) => (Math.abs(v) < 0.06 ? 0 : Math.abs(v - 1) < 0.06 ? 1 : v);
                        const x = snap(s.watermarkX);
                        const y = snap(s.watermarkY);
                        if (x !== s.watermarkX || y !== s.watermarkY) set({ watermarkX: x, watermarkY: y });
                        commit();
                      }}
                    />
                  ),
                },
                { key: "size", node: <PillSlider title="Size" value={s.watermarkSize} min={40} max={400} step={10} onChange={(v) => set({ watermarkSize: v })} onCommit={commit} /> },
                {
                  key: "opacity",
                  node: <PillSlider title="Opacity" value={s.watermarkOpacity} min={0.1} max={1} step={0.05} format={pctRounded} onChange={(v) => set({ watermarkOpacity: v })} onCommit={commit} />,
                },
              ]}
            />
          ),
        },
      ]}
    />
  );
}
