/**
 * Shapes of the API's admin analytics responses (apps/api
 * src/routes/admin-analytics.ts). Kept by hand like the rest of this app's
 * API types; the API is the source of truth.
 */

export type SourceKind = "ai" | "search" | "social" | "campaign" | "referral" | "direct";

export interface TrafficSource {
  id: string;
  label: string;
  kind: SourceKind;
}

export interface UserUsage {
  storageBytes: number;
  videoBytes: number;
  projectBytes: number;
  screenshotBytes: number;
  videos: number;
  videoSeconds: number;
  projects: number;
  screenshots: number;
  views: number;
  lastSeen: string | null;
  lastActive: string | null;
}

export interface SignupSource {
  country: string | null;
  /** null = signed up before tracking existed. */
  via: "web" | "desktop" | null;
  source: TrafficSource | null;
  referrer: string | null;
  utm: string | null;
  landing: string | null;
}

interface Funnel {
  visits: number;
  downloads: number;
  signups: number;
}

export interface Analytics {
  range: { days: number; since: string };
  totals: {
    users: number;
    testers: number;
    paid: number;
    signups: number;
    active1d: number;
    active7d: number;
    active30d: number;
    visits: number;
    downloads: number;
    uploads: number;
    views: number;
    videos: number;
    videoSeconds: number;
    projects: number;
    screenshots: number;
    orgs: number;
  };
  storage: {
    totalBytes: number;
    videoBytes: number;
    projectBytes: number;
    screenshotBytes: number;
    usersStoring: number;
  };
  daily: Array<{ day: string; visits: number; downloads: number; signups: number; uploads: number }>;
  sources: Array<
    TrafficSource &
      Funnel & {
        hosts: Array<{ host: string; visits: number }>;
        /** The pages this source sends people to, busiest first. */
        landings: Array<{ path: string } & Funnel>;
      }
  >;
  countries: Array<{ country: string } & Funnel>;
  landings: Array<
    { path: string } & Funnel & {
      sources: Array<{ id: string; label: string; visits: number; signups: number }>;
    }
  >;
  devices: Array<{ device: string; visits: number; downloads: number }>;
  signupVia: { web: number; desktop: number; unknown: number };
  providers: Array<{ provider: string; users: number }>;
  edits: Array<{ client: string; source: string; sessions: number; projects: number }>;
  features: Array<{ id: string; label: string; users: number; usersInRange: number | null }>;
  topUsers: Array<{ id: string; email: string; name: string | null } & UserUsage>;
}

export interface UserActivity {
  user: { id: string; email: string; name: string | null; createdAt: string };
  signup: SignupSource;
  usage: UserUsage;
  providers: string[];
  sessions: Array<{ client: string; userAgent: string | null; created: string; lastSeen: string }>;
  videos: Array<{
    id: string;
    title: string;
    bytes: number;
    seconds: number;
    private: boolean;
    ownBucket: boolean;
    versions: number;
    views: number;
    comments: number;
    createdAt: string;
  }>;
  projects: Array<{
    id: string;
    name: string;
    team: boolean;
    bytes: number;
    historyBytes: number;
    versions: number;
    createdAt: string;
    updatedAt: string;
  }>;
  screenshots: { stored: number; bytes: number; apiByMonth: Array<{ month: string; count: number }> };
  edits: Array<{ client: string; source: string; sessions: number; last: string }>;
}
