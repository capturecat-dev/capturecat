// `cloudflare:workers` for the local test API: the Worker only needs the
// DurableObject base class to exist (no Durable Object runs here).
export class DurableObject {
  constructor(public ctx?: unknown, public env?: unknown) {}
}
export class WorkerEntrypoint {}
