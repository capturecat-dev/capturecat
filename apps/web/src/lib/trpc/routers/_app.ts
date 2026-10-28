import { createTRPCRouter } from "@/lib/trpc/init";
import { authRouter } from "./auth";
import { videosRouter } from "./videos";
import { billingRouter } from "./billing";
import { profileRouter } from "./profile";
import { ssoRouter } from "./sso";
import { storageRouter } from "./storage";
import { agentTokensRouter } from "./agent-tokens";
import { agentApprovalsRouter } from "./agent-approvals";
import { oauthRouter } from "./oauth";
import { webhooksRouter } from "./webhooks";

export const appRouter = createTRPCRouter({
  auth: authRouter,
  videos: videosRouter,
  billing: billingRouter,
  profile: profileRouter,
  sso: ssoRouter,
  storage: storageRouter,
  agentTokens: agentTokensRouter,
  agentApprovals: agentApprovalsRouter,
  oauth: oauthRouter,
  webhooks: webhooksRouter,
});

export type AppRouter = typeof appRouter;
