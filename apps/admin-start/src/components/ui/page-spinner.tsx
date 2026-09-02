import { Spinner } from "@/components/ui/spinner";
import { cn } from "@/lib/utils";

/**
 * The one full-region loading state for a page's primary content.
 *
 * Every page-level `if (isLoading)` branch renders THIS — four byte-identical
 * copies of the same markup had drifted apart by nothing but luck.
 */
export function PageSpinner({ className }: { className?: string }) {
  return (
    <div className={cn("flex items-center justify-center py-32", className)}>
      <Spinner className="size-8" />
    </div>
  );
}
