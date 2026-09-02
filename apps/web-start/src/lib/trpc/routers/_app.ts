import { createTRPCRouter } from "@/lib/trpc/init";
import { authRouter } from "./auth";
import { videosRouter } from "./videos";
import { billingRouter } from "./billing";
import { profileRouter } from "./profile";

export const appRouter = createTRPCRouter({
  auth: authRouter,
  videos: videosRouter,
  billing: billingRouter,
  profile: profileRouter,
});

export type AppRouter = typeof appRouter;
