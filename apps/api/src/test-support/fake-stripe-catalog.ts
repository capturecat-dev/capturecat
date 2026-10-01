/**
 * TEST-ONLY: an in-memory Stripe product catalog (products + prices) that
 * answers the REST calls the real `stripe` SDK makes, for tests that stub
 * `fetch`. It keeps the rules the sync depends on:
 *
 *   • a lookup key lives on at most ONE price — setting a taken key is a 400
 *     unless the request says `transfer_lookup_key=true`, which moves it;
 *   • prices are immutable apart from `active`, `lookup_key`, `metadata`;
 *   • `prices.list` filters by `lookup_keys[]` and `active`;
 *   • `products.search` understands `metadata['plan']:'<name>'`.
 *
 * Plug it into a fetch stub:  `const res = catalog.handle(method, url, body); if (res) return res;`
 * Never imported by Worker code.
 */

export interface FakePrice {
  id: string;
  object: "price";
  active: boolean;
  currency: string;
  unit_amount: number | null;
  type: "recurring" | "one_time";
  recurring: { interval: "month" | "year"; interval_count: number; usage_type: "licensed" | "metered" } | null;
  lookup_key: string | null;
  product: string;
  metadata: Record<string, string>;
  livemode: false;
  created: number;
}

export interface FakeProduct {
  id: string;
  object: "product";
  active: boolean;
  name: string;
  description: string | null;
  metadata: Record<string, string>;
  livemode: false;
  created: number;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

function missing(id: string): Response {
  return json({ error: { type: "invalid_request_error", code: "resource_missing", message: `No such object: '${id}'` } }, 404);
}

/** `a=1&b[c]=2&d[0]=x` → `{ a: "1", b: { c: "2" }, d: { "0": "x" } }`. */
export function parseStripeForm(body: string): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [rawKey, value] of new URLSearchParams(body)) {
    const parts = rawKey.split(/\[|\]/).filter((p) => p !== "");
    let node = out;
    for (const [i, part] of parts.entries()) {
      if (i === parts.length - 1) node[part] = value;
      else node = (node[part] ??= {}) as Record<string, unknown>;
    }
  }
  return out;
}

export interface FakeCoupon {
  id: string;
  object: "coupon";
  name: string | null;
  amount_off: number | null;
  currency: string | null;
  duration: "forever" | "once" | "repeating";
  duration_in_months: number | null;
  redeem_by: number | null;
  applies_to: { products: string[] } | null;
  metadata: Record<string, string>;
  valid: boolean;
  livemode: false;
}

export class FakeStripeCatalog {
  products = new Map<string, FakeProduct>();
  prices = new Map<string, FakePrice>();
  coupons = new Map<string, FakeCoupon>();
  /** Ids of coupons deleted (Stripe forgets them; tests want to know). */
  deletedCoupons: string[] = [];
  private seq = 0;

  reset(): void {
    this.products.clear();
    this.prices.clear();
    this.coupons.clear();
    this.deletedCoupons.length = 0;
    this.seq = 0;
  }

  addProduct(fields: Partial<FakeProduct> & { name: string }): FakeProduct {
    const product: FakeProduct = {
      id: fields.id ?? `prod_fake${++this.seq}`,
      object: "product",
      active: true,
      description: null,
      metadata: {},
      livemode: false,
      created: 1_700_000_000 + this.seq,
      ...fields,
    };
    this.products.set(product.id, product);
    return product;
  }

  addPrice(
    fields: Partial<Omit<FakePrice, "recurring">> & {
      product: string;
      unit_amount: number;
      interval?: "month" | "year";
    },
  ): FakePrice {
    const { interval = "month", ...rest } = fields;
    const price: FakePrice = {
      id: rest.id ?? `price_fake${++this.seq}`,
      object: "price",
      active: true,
      currency: "usd",
      type: "recurring",
      recurring: { interval, interval_count: 1, usage_type: "licensed" },
      lookup_key: null,
      metadata: {},
      livemode: false,
      created: 1_700_000_000 + this.seq,
      ...rest,
    };
    this.prices.set(price.id, price);
    return price;
  }

  /** Prices holding `key` (should only ever be one). */
  keyed(key: string): FakePrice[] {
    return [...this.prices.values()].filter((p) => p.lookup_key === key);
  }

  /** Move or refuse a lookup key, as Stripe does. Returns an error response
   *  when the key is taken and the request did not ask to transfer it. */
  private claimKey(priceId: string, key: string, transfer: boolean): Response | null {
    for (const other of this.prices.values()) {
      if (other.id === priceId || other.lookup_key !== key) continue;
      if (!transfer) {
        return json(
          { error: { type: "invalid_request_error", message: `A price (\`${other.id}\`) already uses that lookup key.` } },
          400,
        );
      }
      other.lookup_key = null;
    }
    return null;
  }

  handle(method: string, url: URL, body: string): Response | null {
    const p = url.pathname;
    const form = method === "POST" ? parseStripeForm(body) : {};
    let m: RegExpExecArray | null;

    // ---- products ---------------------------------------------------------
    if (p === "/v1/products/search" && method === "GET") {
      const q = /metadata\['plan'\]:'([^']*)'/.exec(url.searchParams.get("query") ?? "");
      const data = [...this.products.values()].filter((x) => q && x.metadata.plan === q[1]);
      return json({ object: "search_result", data, has_more: false, next_page: null, url: "/v1/products/search" });
    }
    if (p === "/v1/products" && method === "GET") {
      return json({ object: "list", data: [...this.products.values()], has_more: false, url: "/v1/products" });
    }
    if (p === "/v1/products" && method === "POST") {
      const product = this.addProduct({
        name: String(form.name),
        description: typeof form.description === "string" ? form.description : null,
        metadata: (form.metadata as Record<string, string>) ?? {},
      });
      return json(product);
    }
    if ((m = /^\/v1\/products\/([^/]+)$/.exec(p))) {
      const product = this.products.get(m[1]);
      if (!product) return missing(m[1]);
      if (method === "POST") {
        if (typeof form.name === "string") product.name = form.name;
        if (typeof form.description === "string") product.description = form.description || null;
        if (typeof form.active === "string") product.active = form.active === "true";
        if (form.metadata) product.metadata = { ...product.metadata, ...(form.metadata as Record<string, string>) };
      }
      return json(product);
    }

    // ---- prices -----------------------------------------------------------
    if (p === "/v1/prices" && method === "GET") {
      const keys = [...url.searchParams.entries()].filter(([k]) => k.startsWith("lookup_keys")).map(([, v]) => v);
      const active = url.searchParams.get("active");
      const data = [...this.prices.values()].filter(
        (x) =>
          (keys.length === 0 || (x.lookup_key !== null && keys.includes(x.lookup_key))) &&
          (active === null || String(x.active) === active),
      );
      return json({ object: "list", data, has_more: false, url: "/v1/prices" });
    }
    if (p === "/v1/prices" && method === "POST") {
      const recurring = form.recurring as { interval?: "month" | "year" } | undefined;
      const id = `price_fake${++this.seq}`;
      const key = typeof form.lookup_key === "string" ? form.lookup_key : null;
      if (key) {
        const refused = this.claimKey(id, key, form.transfer_lookup_key === "true");
        if (refused) return refused;
      }
      const price = this.addPrice({
        id,
        product: String(form.product),
        unit_amount: Number(form.unit_amount),
        currency: String(form.currency),
        interval: recurring?.interval ?? "month",
        lookup_key: key,
        metadata: (form.metadata as Record<string, string>) ?? {},
      });
      return json(price);
    }
    if ((m = /^\/v1\/prices\/([^/]+)$/.exec(p))) {
      const price = this.prices.get(m[1]);
      if (!price) return missing(m[1]);
      if (method === "POST") {
        if (typeof form.lookup_key === "string") {
          const refused = this.claimKey(price.id, form.lookup_key, form.transfer_lookup_key === "true");
          if (refused) return refused;
          price.lookup_key = form.lookup_key || null;
        }
        if (typeof form.active === "string") price.active = form.active === "true";
        if (form.metadata) price.metadata = { ...price.metadata, ...(form.metadata as Record<string, string>) };
      }
      return json(price);
    }

    // ---- coupons ----------------------------------------------------------
    if (p === "/v1/coupons" && method === "POST") {
      const appliesTo = form.applies_to as { products?: Record<string, string> } | undefined;
      const coupon: FakeCoupon = {
        id: `coupon_fake${++this.seq}`,
        object: "coupon",
        name: typeof form.name === "string" ? form.name : null,
        amount_off: form.amount_off ? Number(form.amount_off) : null,
        currency: typeof form.currency === "string" ? form.currency : null,
        duration: form.duration as FakeCoupon["duration"],
        duration_in_months: form.duration_in_months ? Number(form.duration_in_months) : null,
        redeem_by: form.redeem_by ? Number(form.redeem_by) : null,
        applies_to: appliesTo?.products ? { products: Object.values(appliesTo.products) } : null,
        metadata: (form.metadata as Record<string, string>) ?? {},
        valid: true,
        livemode: false,
      };
      this.coupons.set(coupon.id, coupon);
      return json(coupon);
    }
    if ((m = /^\/v1\/coupons\/([^/]+)$/.exec(p))) {
      const coupon = this.coupons.get(m[1]);
      if (!coupon) return missing(m[1]);
      if (method === "DELETE") {
        this.coupons.delete(coupon.id);
        this.deletedCoupons.push(coupon.id);
        return json({ id: coupon.id, object: "coupon", deleted: true });
      }
      if (method === "POST" && typeof form.name === "string") coupon.name = form.name;
      return json(coupon);
    }
    return null;
  }
}
