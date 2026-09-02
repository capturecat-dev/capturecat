/** Server functions bridging session reads into route loaders/beforeLoad. */
import { createServerFn } from "@tanstack/react-start";

import { getSession, type Session } from "./session";

export const fetchSession = createServerFn({ method: "GET" }).handler(
  async (): Promise<Session | null> => getSession()
);
