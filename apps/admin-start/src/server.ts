/**
 * Server entry. Unlike apps/web-start, the admin console serves a single host
 * (admin.capturecat.so) — no host-rewrite or legacy-redirect logic needed.
 */
import {
  createStartHandler,
  defaultStreamHandler,
} from "@tanstack/react-start/server";
import { createServerEntry } from "@tanstack/react-start/server-entry";

const startHandler = createStartHandler({ handler: defaultStreamHandler });

export default createServerEntry({
  fetch(request: Request) {
    return startHandler(request);
  },
});
