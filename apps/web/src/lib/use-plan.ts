import { trpc } from "@/lib/trpc/client";

/**
 * The signed-in account's plan as the API resolves it (GET /api/me via
 * billing.status) — the same answer every server-side gate uses.
 *
 * `commercialUse` is false until the answer arrives and when it can't be had:
 * a Free cap that a slow request briefly applies is lifted the moment it lands
 * (the recorder reads it live), while a guess the other way would let a Free
 * take run past its cap.
 */
export function usePlan() {
  const { data, isLoading } = trpc.billing.status.useQuery(undefined, { staleTime: 60_000 });
  return {
    loading: isLoading,
    tier: data?.tier ?? "free",
    planName: data?.plan?.displayName ?? (data?.tier === "free" ? "Free" : null),
    commercialUse: data?.features?.commercialUse === true,
  };
}
