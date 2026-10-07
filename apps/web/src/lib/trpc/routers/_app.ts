import { createTRPCRouter } from "@/lib/trpc/init";
import { authRouter } from "./auth";
import { videosRouter } from "./videos";
import { billingRouter } from "./billing";
import { profileRouter } from "./profile";
import { ssoRouter } from "./sso";
import { storageRouter } from "./storage";

export const appRouter = createTRPCRouter({
  auth: authRouter,
  videos: videosRouter,
  billing: billingRouter,
  profile: profileRouter,
  sso: ssoRouter,
  storage: storageRouter,
});

export type AppRouter = typeof appRouter;
