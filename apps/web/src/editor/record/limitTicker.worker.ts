/// <reference lib="webworker" />
// limitTicker.ts: tick every N ms (the first message) until terminated.
const scope = self as unknown as DedicatedWorkerGlobalScope;
scope.onmessage = (e: MessageEvent<number>) => {
  setInterval(() => scope.postMessage(0), e.data);
};
