/**
 * Under a picker's button: a spinner + caption while the file is prepared or
 * uploaded, or the error caption (BrandSettingsPaneAppKit's `errorLabel`).
 */
import { Button } from "../kit";
import type { PickerStatus } from "./types";

export function hasPickerStatus(status: PickerStatus | undefined): boolean {
  return Boolean(status?.busy || status?.error);
}

export function PickerStatusLine({ status }: { status: PickerStatus | undefined }) {
  if (status?.error) {
    const action = status.action;
    if (!action) return <div className="cc-pane-error">{status.error}</div>;
    return (
      <div className="cc-pane-hstack" style={{ alignItems: "flex-start", gap: 8 }}>
        <div className="cc-pane-error" style={{ flex: 1 }}>
          {status.error}
        </div>
        <Button size="sm" onClick={action.run}>
          {action.title}
        </Button>
      </div>
    );
  }
  if (status?.busy) {
    return (
      <div className="cc-pane-hstack">
        <span className="cc-spin cc-spin--sm" aria-hidden="true" />
        <span className="cc-caption">{status.busy}</span>
      </div>
    );
  }
  return null;
}
