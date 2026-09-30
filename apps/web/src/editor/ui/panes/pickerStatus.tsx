/**
 * Under a picker's button: a spinner + caption while the file is prepared or
 * uploaded, or the error caption (BrandSettingsPaneAppKit's `errorLabel`).
 */
import type { PickerStatus } from "./types";

export function hasPickerStatus(status: PickerStatus | undefined): boolean {
  return Boolean(status?.busy || status?.error);
}

export function PickerStatusLine({ status }: { status: PickerStatus | undefined }) {
  if (status?.error) return <div className="cc-pane-error">{status.error}</div>;
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
