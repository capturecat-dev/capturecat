/**
 * The stage's non-blocking warning callout (CCCallout .warning, dismissible)
 * for features the web engine does not draw yet. Dismissing hides it for the
 * current set of features; a different set (after an edit) shows it again.
 */
import { useState } from "react";

import { Callout } from "../kit";
import { unsupportedNoticeCopy } from "./unsupportedCopy";

export function UnsupportedNotice({ features }: { features: readonly string[] }) {
  const key = features.join("|");
  const [dismissed, setDismissed] = useState<string | null>(null);
  const copy = unsupportedNoticeCopy(features);
  if (!copy || dismissed === key) return null;
  return (
    <Callout
      key={key}
      variant="warning"
      dismissible
      title={copy.title}
      message={copy.message}
      onDismiss={() => setDismissed(key)}
    />
  );
}
