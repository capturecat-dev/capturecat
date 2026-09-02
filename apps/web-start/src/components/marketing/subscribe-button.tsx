import { useNavigate } from "@tanstack/react-router";
import { useState } from "react";

import { trpc } from "@/lib/trpc/client";

export function SubscribeButton({ annual = false }: { annual?: boolean }) {
  const navigate = useNavigate();
  const [isPending, setIsPending] = useState(false);
  const me = trpc.auth.me.useQuery();
  const createCheckout = trpc.billing.checkout.useMutation();

  const handleClick = async () => {
    // If not signed in, redirect to login with a return URL
    if (!me.data) {
      void navigate({ href: "/login?redirect=/pricing" });
      return;
    }

    setIsPending(true);
    try {
      const { url } = await createCheckout.mutateAsync({ annual });
      if (url) window.location.href = url;
    } catch {
      setIsPending(false);
    }
  };

  // Marketing page — styled like the Hero's primary pill, not shadcn.
  return (
    <button
      type="button"
      onClick={handleClick}
      disabled={isPending}
      className="inline-flex h-12 w-full items-center justify-center rounded-full bg-white text-[15px] font-medium text-black transition-transform duration-300 hover:scale-[1.02] active:scale-[0.99] disabled:opacity-60"
    >
      {isPending ? "Redirecting..." : "Subscribe"}
    </button>
  );
}
