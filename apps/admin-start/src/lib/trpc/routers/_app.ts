import { createTRPCRouter } from "@/lib/trpc/init";
import { authRouter } from "./auth";
import { adminRouter } from "./admin";

export const appRouter = createTRPCRouter({
  auth: authRouter,
  admin: adminRouter,
});

export type AppRouter = typeof appRouter;
