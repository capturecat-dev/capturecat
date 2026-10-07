import type { DocSection } from "../types";

/**
 * Checked against apps/api/src/lib/storage.ts, routes/storage.ts,
 * routes/upload.ts, routes/video.ts, routes/delete.ts and migration 0029,
 * apps/web storage-bucket-card.tsx, and the Mac StorageSettingsPane.
 */
const CHECKED = "2026-10-07";

const CORS_RULES = `[
  {
    "AllowedOrigins": [
      "https://capturecat.so",
      "https://www.capturecat.so",
      "https://app.capturecat.so"
    ],
    "AllowedMethods": ["PUT"],
    "AllowedHeaders": ["content-type"],
    "MaxAgeSeconds": 3600
  }
]`;

const CORS_CLI = `cat > cors.json <<'EOF'
{
  "CORSRules": [
    {
      "AllowedOrigins": ["https://capturecat.so", "https://www.capturecat.so", "https://app.capturecat.so"],
      "AllowedMethods": ["PUT"],
      "AllowedHeaders": ["content-type"],
      "MaxAgeSeconds": 3600
    }
  ]
}
EOF
aws s3api put-bucket-cors --bucket my-videos --cors-configuration file://cors.json \\
  --endpoint-url https://YOUR-ENDPOINT   # omit --endpoint-url for AWS S3`;

const IAM_POLICY = `{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::my-videos/capturecat/*"
    }
  ]
}`;

const CORS_STEP_TEXT =
  "Only needed for sharing from the web editor, which uploads from your browser. Allow `PUT` with the `content-type` header from `https://capturecat.so`, `https://www.capturecat.so` and `https://app.capturecat.so`. The Mac app and playback need no CORS. See [CORS for web uploads](/docs/custom-storage/cors).";

export const CUSTOM_STORAGE: DocSection = {
  id: "custom-storage",
  title: "Custom storage (S3)",
  description: "Keep share videos in your own AWS S3, Cloudflare R2, Backblaze B2, Wasabi or MinIO bucket.",
  pages: [
    {
      slug: "custom-storage",
      title: "Store share videos in your own S3 bucket",
      navTitle: "Overview",
      description:
        "Keep CaptureCat share videos in your own S3-compatible bucket: AWS S3, Cloudflare R2, Backblaze B2, Wasabi or MinIO. How uploads, playback and limits work.",
      summary:
        "Connect an S3-compatible bucket and every new share video uploads straight to it, whether you share from the Mac app or the web editor. Share links, comments and analytics work as before; the video file lives in your bucket and does not count against your CaptureCat storage.",
      platforms: ["mac", "web"],
      plan: "pro",
      blocks: [
        { type: "h2", text: "Supported providers" },
        {
          type: "table",
          head: ["Provider", "Endpoint", "Region"],
          rows: [
            ["[AWS S3](/docs/custom-storage/aws-s3)", "Leave empty", "Your bucket's region, e.g. `us-east-1`"],
            ["[Cloudflare R2](/docs/custom-storage/cloudflare-r2)", "`https://<account-id>.r2.cloudflarestorage.com`", "`auto`"],
            ["[Backblaze B2](/docs/custom-storage/backblaze-b2)", "`https://s3.<region>.backblazeb2.com`", "e.g. `us-west-004`"],
            ["[Wasabi](/docs/custom-storage/wasabi)", "`https://s3.<region>.wasabisys.com`", "e.g. `us-east-1`"],
            ["[MinIO](/docs/custom-storage/minio)", "Your server's public https URL", "Usually `us-east-1`"],
          ],
        },
        {
          type: "p",
          text: "Any other service that speaks the S3 API works too: choose **Other** and enter its endpoint and region.",
        },
        { type: "h2", text: "How it works" },
        {
          type: "list",
          items: [
            "**Uploads go straight to your bucket.** When you share, CaptureCat signs a one-time upload URL for your bucket and the app uploads the file directly. The video never passes through CaptureCat's servers.",
            "**Share links play from your bucket.** The share page checks privacy, passwords, expiry and view limits first, then hands the player a link to the file in your bucket.",
            "**Private buckets work.** Without a public URL, playback uses short-lived signed links: 6 hours for public shares, 1 hour for password-protected, expiring or private ones, and 15 minutes for downloads.",
            "**Only shares go to your bucket.** Web recordings and projects you open in the web editor are kept in CaptureCat storage; a video goes to your bucket when you share it.",
            "**Everything else stays the same.** Titles, transcripts, comments, reactions, analytics and custom thumbnails are stored by CaptureCat as usual; only the video file is in your bucket.",
          ],
        },
        { type: "h2", text: "Where files are stored" },
        {
          type: "p",
          text: "Files are written under the folder you choose (default `capturecat/`). The first upload of a share is `capturecat/videos/<video-id>.mp4`; each replacement version is `capturecat/videos/<video-id>/v<n>.mp4`.",
        },
        { type: "h2", text: "Limits" },
        {
          type: "p",
          text: "Videos in your own bucket do not count toward your plan's total cloud storage. Your plan's per-video size limit, length limit and daily share limit still apply.",
        },
        { type: "h2", text: "Security" },
        {
          type: "list",
          items: [
            "Before saving, CaptureCat writes, reads and deletes a small test file with your keys, so a bucket that would fail an upload is never connected.",
            "The secret access key is encrypted at rest and never shown again, in the app or the dashboard. Only the first and last four characters of the access key ID are displayed.",
            "Use a key that can only read, write and delete objects in this one bucket (or folder). The provider pages show the minimal permissions.",
          ],
        },
        { type: "h2", text: "Disconnecting" },
        {
          type: "p",
          text: "Disconnect from **Settings → Storage** on the Mac or **Settings → Your own storage** on the web. New shares upload to CaptureCat storage again. Videos already in your bucket keep playing from it, so CaptureCat keeps that bucket's keys until the last of those videos is deleted, then forgets them.",
        },
        {
          type: "callout",
          tone: "pro",
          text: "Custom storage is included in Pro and Business. If your plan ends, new shares go to CaptureCat storage (and count toward its limit); videos already in your bucket keep playing.",
        },
      ],
      faqs: [
        {
          question: "Does CaptureCat support S3-compatible storage?",
          answer:
            "Yes. On Pro, connect AWS S3, Cloudflare R2, Backblaze B2, Wasabi, MinIO or any other S3-compatible bucket, and share videos upload to it from the Mac app and the web editor.",
        },
        {
          question: "Do my viewers need access to my bucket?",
          answer:
            "No. Viewers open the normal share link; CaptureCat checks the share's settings and then gives their player a short-lived signed link to the file. Your bucket can stay private.",
        },
        {
          question: "What happens to videos I shared before connecting a bucket?",
          answer:
            "They stay where they are, in CaptureCat storage. Only new shares, and new versions of existing shares, go to your bucket.",
        },
        {
          question: "Can I switch to a different bucket?",
          answer:
            "Yes. Connect the new one and new uploads go there. Videos in the old bucket keep playing from it until you delete them.",
        },
      ],
      related: ["custom-storage/connect", "custom-storage/cors", "custom-storage/troubleshooting"],
      lastModified: CHECKED,
    },
    {
      slug: "custom-storage/connect",
      title: "Connect a storage bucket",
      navTitle: "Connect a bucket",
      description:
        "Connect your S3, R2, B2, Wasabi or MinIO bucket to CaptureCat from the Mac app or the web dashboard, test it, and start uploading share videos to it.",
      summary:
        "Create a bucket and an access key with your provider, then enter them in CaptureCat's storage settings. CaptureCat tests the bucket before it saves anything.",
      platforms: ["mac", "web"],
      plan: "pro",
      blocks: [
        { type: "h2", text: "Before you start" },
        {
          type: "list",
          items: [
            "A bucket, and an access key ID and secret access key that can read, write and delete objects in it. Follow the page for your provider: [AWS S3](/docs/custom-storage/aws-s3), [Cloudflare R2](/docs/custom-storage/cloudflare-r2), [Backblaze B2](/docs/custom-storage/backblaze-b2), [Wasabi](/docs/custom-storage/wasabi) or [MinIO](/docs/custom-storage/minio).",
            "A CaptureCat Pro or Business plan, and to be signed in.",
          ],
        },
        { type: "h2", text: "Connect" },
        {
          type: "steps",
          steps: [
            {
              title: "Open storage settings",
              text: "On the Mac, open **Settings → Storage**. On the web, open [capturecat.so/app/settings](https://capturecat.so/app/settings) and scroll to **Your own storage**. Both edit the same connection.",
            },
            {
              title: "Choose your provider",
              text: "Picking a provider fills in its region and shows where its endpoint goes. For AWS S3 there is no endpoint field.",
            },
            {
              title: "Enter the bucket details",
              text: "Fill in **Endpoint** (the S3 API host only, with no bucket name in it), **Region**, **Bucket**, and optionally a **Folder** (default `capturecat/`).",
            },
            {
              title: "Enter the keys",
              text: "Paste the **Access key ID** and **Secret access key**. Both are needed every time you save.",
            },
            {
              title: "Optionally set a public URL",
              text: "Leave **Public URL** empty to play videos through short-lived signed links, which work with private buckets. Set it only if the bucket, or a CDN in front of it, is publicly readable, for example `https://videos.yourcompany.com`.",
            },
            {
              title: "Test and connect",
              text: "Click **Test & connect** (web) or **Test & Save** (Mac). CaptureCat writes, reads and deletes a small test file. If a step fails it tells you which, and nothing is saved.",
            },
            {
              title: "Allow sharing from the web editor",
              text: CORS_STEP_TEXT,
            },
          ],
        },
        {
          type: "p",
          text: "That's it. The next time you share a video, from the Mac export sheet or the web editor's Share panel, it uploads to your bucket. The connected card shows how many share videos are stored there.",
        },
        { type: "h2", text: "Change keys or settings" },
        {
          type: "p",
          text: "Click **Edit**, change what you need and re-enter both keys. If the endpoint, bucket and folder stay the same, the existing connection is updated in place and existing videos keep playing with the new keys. Changing the bucket or folder connects a new destination.",
        },
        {
          type: "callout",
          tone: "warning",
          title: "Public URL",
          text: "With a public URL, anyone who has a video's file address can play it, even if its share link has a password or has expired. Leave it empty if share controls matter.",
        },
      ],
      related: ["custom-storage", "custom-storage/cors", "custom-storage/troubleshooting"],
      lastModified: CHECKED,
    },
    {
      slug: "custom-storage/aws-s3",
      title: "Use AWS S3 for CaptureCat videos",
      navTitle: "AWS S3",
      description:
        "Set up an Amazon S3 bucket and a least-privilege IAM key for CaptureCat share videos, including the CORS rule for browser uploads.",
      summary:
        "Create an S3 bucket and an IAM user whose only permission is to put, get and delete objects in it, then connect it in CaptureCat with the provider set to AWS S3.",
      platforms: ["mac", "web"],
      plan: "pro",
      blocks: [
        {
          type: "steps",
          steps: [
            {
              title: "Create the bucket",
              text: "In the AWS console, open **S3 → Create bucket**. Pick a name and a region, and keep **Block all public access** on unless you plan to serve videos from a public URL.",
            },
            {
              title: "Create an IAM policy",
              text: "In **IAM → Policies → Create policy**, paste the JSON below, replacing `my-videos` with your bucket and `capturecat/` with your folder.",
            },
            {
              title: "Create an IAM user and key",
              text: "In **IAM → Users → Create user**, attach the policy, then open the user's **Security credentials** and create an access key. Copy the access key ID and secret access key.",
            },
            {
              title: "Connect in CaptureCat",
              text: "Choose **AWS S3**, leave the endpoint empty, enter the bucket's region (for example `eu-west-2`), the bucket name, the folder and both keys, then test and connect. See [Connect a storage bucket](/docs/custom-storage/connect).",
            },
            {
              title: "Add CORS for sharing from the web",
              text: "In the bucket's **Permissions → Cross-origin resource sharing (CORS)**, paste the rules from [CORS for web uploads](/docs/custom-storage/cors).",
            },
          ],
        },
        { type: "code", lang: "json", caption: "Minimal IAM policy", code: IAM_POLICY },
        {
          type: "callout",
          tone: "tip",
          text: "The region must be the bucket's actual region. If it is wrong, the test reports that the bucket is in a different region.",
        },
      ],
      faqs: [
        {
          question: "Which IAM permissions does CaptureCat need on S3?",
          answer:
            "`s3:PutObject`, `s3:GetObject` and `s3:DeleteObject` on the objects under your folder. It does not need to list buckets or change bucket settings.",
        },
      ],
      related: ["custom-storage/connect", "custom-storage/cors", "custom-storage/troubleshooting"],
      lastModified: CHECKED,
    },
    {
      slug: "custom-storage/cloudflare-r2",
      title: "Use Cloudflare R2 for CaptureCat videos",
      navTitle: "Cloudflare R2",
      description:
        "Store CaptureCat share videos in Cloudflare R2: create a bucket, an R2 API token scoped to it, and connect it with region auto. No egress fees.",
      summary:
        "Create an R2 bucket and an R2 API token with Object Read & Write on that bucket, then connect it in CaptureCat with your account's S3 endpoint and the region `auto`.",
      platforms: ["mac", "web"],
      plan: "pro",
      blocks: [
        {
          type: "steps",
          steps: [
            {
              title: "Create the bucket",
              text: "In the Cloudflare dashboard, open **R2 Object Storage → Create bucket** and name it.",
            },
            {
              title: "Create an API token",
              text: "In **R2 Object Storage → Manage API tokens → Create API token**, choose **Object Read & Write** and apply it to this bucket only. Copy the **Access Key ID** and **Secret Access Key**; the secret is shown once.",
            },
            {
              title: "Find the endpoint",
              text: "The token page and the bucket's settings show the S3 API endpoint, `https://<account-id>.r2.cloudflarestorage.com`. Use it without the bucket name on the end.",
            },
            {
              title: "Connect in CaptureCat",
              text: "Choose **Cloudflare R2**, paste the endpoint, keep the region `auto`, enter the bucket, folder and keys, then test and connect.",
            },
            {
              title: "Add CORS for sharing from the web",
              text: "In the bucket's **Settings → CORS policy**, paste the JSON from [CORS for web uploads](/docs/custom-storage/cors).",
            },
          ],
        },
        { type: "h2", text: "Serving from a public R2 URL" },
        {
          type: "p",
          text: "Signed links work with a private bucket, so a public URL is optional. If you connect a custom domain to the bucket (or enable its r2.dev URL), enter that address as the **Public URL** and videos play from it directly. CaptureCat fetches the test file through it before saving, so a URL that does not serve the bucket is rejected.",
        },
      ],
      faqs: [
        {
          question: "What region do I use for Cloudflare R2?",
          answer: "`auto`. R2 picks the location itself, and CaptureCat fills it in when you choose Cloudflare R2.",
        },
      ],
      related: ["custom-storage/connect", "custom-storage/cors", "custom-storage/troubleshooting"],
      lastModified: CHECKED,
    },
    {
      slug: "custom-storage/backblaze-b2",
      title: "Use Backblaze B2 for CaptureCat videos",
      navTitle: "Backblaze B2",
      description:
        "Store CaptureCat share videos in Backblaze B2 through its S3-compatible API: bucket, application key, endpoint and region.",
      summary:
        "Create a B2 bucket and an application key with read and write access to it, then connect it in CaptureCat using the bucket's S3 endpoint and the region in that endpoint.",
      platforms: ["mac", "web"],
      plan: "pro",
      blocks: [
        {
          type: "steps",
          steps: [
            {
              title: "Create the bucket",
              text: "In Backblaze, open **Buckets → Create a Bucket**. A private bucket is fine.",
            },
            {
              title: "Note the endpoint",
              text: "The bucket card shows an **Endpoint** such as `s3.us-west-004.backblazeb2.com`. In CaptureCat the endpoint is `https://s3.us-west-004.backblazeb2.com` and the region is the middle part, `us-west-004`.",
            },
            {
              title: "Create an application key",
              text: "In **Application Keys → Add a New Application Key**, allow access to this bucket only, with **Read and Write**. The **keyID** is the access key ID and the **applicationKey** is the secret access key.",
            },
            {
              title: "Connect in CaptureCat",
              text: "Choose **Backblaze B2**, enter the endpoint, region, bucket, folder and keys, then test and connect.",
            },
            {
              title: "Add CORS for sharing from the web",
              text: CORS_STEP_TEXT,
            },
          ],
        },
      ],
      related: ["custom-storage/connect", "custom-storage/cors", "custom-storage/troubleshooting"],
      lastModified: CHECKED,
    },
    {
      slug: "custom-storage/wasabi",
      title: "Use Wasabi for CaptureCat videos",
      navTitle: "Wasabi",
      description:
        "Store CaptureCat share videos in Wasabi hot cloud storage: bucket, access keys, and the regional endpoint.",
      summary:
        "Create a Wasabi bucket and an access key, then connect it in CaptureCat with the endpoint for the bucket's region, `https://s3.<region>.wasabisys.com`.",
      platforms: ["mac", "web"],
      plan: "pro",
      blocks: [
        {
          type: "steps",
          steps: [
            {
              title: "Create the bucket",
              text: "In the Wasabi console, create a bucket and note its region, for example `us-east-1` or `eu-central-1`.",
            },
            {
              title: "Create access keys",
              text: "Create an access key for a user whose policy allows reading, writing and deleting objects in that bucket. Copy both keys.",
            },
            {
              title: "Connect in CaptureCat",
              text: "Choose **Wasabi**. The endpoint is `https://s3.<region>.wasabisys.com` (for example `https://s3.eu-central-1.wasabisys.com`) and the region is the same region name. Enter the bucket, folder and keys, then test and connect.",
            },
            { title: "Add CORS for sharing from the web", text: CORS_STEP_TEXT },
          ],
        },
      ],
      related: ["custom-storage/connect", "custom-storage/cors", "custom-storage/troubleshooting"],
      lastModified: CHECKED,
    },
    {
      slug: "custom-storage/minio",
      title: "Use MinIO for CaptureCat videos",
      navTitle: "MinIO",
      description:
        "Connect a self-hosted MinIO server to CaptureCat for share videos: public HTTPS endpoint, path-style URLs, and a scoped access key.",
      summary:
        "Expose your MinIO server's S3 API on a public HTTPS hostname, create a bucket and a key scoped to it, and connect it in CaptureCat with path-style URLs on.",
      platforms: ["mac", "web"],
      plan: "pro",
      blocks: [
        {
          type: "callout",
          tone: "note",
          text: "CaptureCat's servers talk to your MinIO server to sign uploads and test the bucket, and viewers' browsers fetch videos from it. The endpoint must be an `https://` URL on a public hostname; IP addresses, `localhost` and `.local` names are refused.",
        },
        {
          type: "steps",
          steps: [
            {
              title: "Create the bucket and key",
              text: "Create a bucket (for example with `mc mb myminio/my-videos`) and an access key whose policy allows `s3:PutObject`, `s3:GetObject` and `s3:DeleteObject` on it.",
            },
            {
              title: "Connect in CaptureCat",
              text: "Choose **MinIO**. **Path-style URLs** is turned on for you, because MinIO addresses buckets as `https://minio.yourcompany.com/my-videos/…`. Enter the endpoint, region (`us-east-1` unless you changed MinIO's), bucket, folder and keys, then test and connect.",
            },
            {
              title: "Allow web uploads",
              text: "MinIO answers CORS for the S3 API from its server settings rather than per bucket. If you restricted allowed origins, add `https://capturecat.so`, `https://www.capturecat.so` and `https://app.capturecat.so`.",
            },
          ],
        },
      ],
      related: ["custom-storage/connect", "custom-storage/troubleshooting"],
      lastModified: CHECKED,
    },
    {
      slug: "custom-storage/cors",
      title: "CORS for web uploads to your bucket",
      navTitle: "CORS for web uploads",
      description:
        "The CORS rule your S3, R2, B2 or Wasabi bucket needs so you can share videos to it from the CaptureCat web editor.",
      summary:
        "When you share from the web editor, your browser uploads the video straight to your bucket, so the bucket must allow `PUT` requests from CaptureCat's web addresses. The Mac app and video playback need no CORS.",
      platforms: ["web"],
      plan: "pro",
      blocks: [
        { type: "h2", text: "The rule" },
        {
          type: "code",
          lang: "json",
          caption: "For a console CORS editor (AWS S3, Cloudflare R2 and others that accept JSON rules):",
          code: CORS_RULES,
        },
        {
          type: "code",
          lang: "bash",
          caption: "Or with the AWS CLI against any provider that supports `PutBucketCors`:",
          code: CORS_CLI,
        },
        { type: "h2", text: "Check it" },
        {
          type: "p",
          text: "After connecting on the web, CaptureCat uploads a tiny test file from your browser and shows **Sharing from the web editor works**, or the reason it was blocked along with these rules to copy. Click **Check again** after changing the bucket's CORS. CORS changes can take a minute to apply.",
        },
        {
          type: "callout",
          tone: "note",
          text: "Playback does not need CORS: the share page's player follows a link to the file, which browsers allow without it.",
        },
      ],
      related: ["custom-storage/connect", "custom-storage/troubleshooting"],
      lastModified: CHECKED,
    },
    {
      slug: "custom-storage/troubleshooting",
      title: "Troubleshoot custom storage",
      navTitle: "Troubleshooting",
      description:
        "Fix CaptureCat custom storage errors: bucket not found, wrong region, access denied, signature mismatch, CORS, and videos that stop playing.",
      summary:
        "When the bucket test fails, CaptureCat names the step (write, read, public URL or delete) and the reason. This page lists each message and what to change.",
      platforms: ["mac", "web"],
      plan: "pro",
      blocks: [
        { type: "h2", text: "Errors when connecting" },
        {
          type: "table",
          head: ["Message", "What to do"],
          rows: [
            ["Bucket \"…\" doesn't exist at this endpoint and region.", "Check the bucket name's spelling, the endpoint, and the region."],
            ["The access key ID wasn't recognised.", "Copy the access key ID again; make sure it belongs to this provider and account."],
            ["The secret access key doesn't match the access key ID.", "Re-paste the secret. Some providers show it only once; create a new key if you lost it."],
            ["The key is valid but isn't allowed to write / read / delete objects in this bucket.", "Give the key read, write and delete on objects in the bucket (or under your folder)."],
            ["The bucket is in a different region — check Region.", "Enter the bucket's real region. R2 uses `auto`."],
            ["Endpoint is the host only — put the bucket name in Bucket", "Remove the bucket name from the end of the endpoint URL."],
            ["Endpoint must be an https:// URL on a public hostname", "Use an `https://` hostname that is reachable from the internet; IP addresses and local names are refused."],
            ["Leave Endpoint empty for AWS S3 — the region decides it", "Clear the endpoint when the provider is AWS S3."],
            ["Timed out … — check Endpoint and Region", "The endpoint did not answer within 10 seconds. Check the URL, and that the server is reachable."],
            ["Couldn't fetch the test file through …", "The public URL does not serve the bucket. Make it publicly readable, or leave Public URL empty to use signed links."],
          ],
        },
        { type: "h2", text: "Sharing from the web editor fails" },
        {
          type: "p",
          text: "If sharing works from the Mac app but fails from the web editor, the bucket's CORS does not allow CaptureCat's web origin. Add the rule from [CORS for web uploads](/docs/custom-storage/cors) and run the check again in **Settings → Your own storage**.",
        },
        { type: "h2", text: "A video stopped playing" },
        {
          type: "list",
          items: [
            "**You rotated or deleted the key.** Edit the connection and enter the new keys with the same endpoint, bucket and folder; existing videos pick up the new keys.",
            "**The file was deleted or moved in the bucket.** CaptureCat links to the exact object key; restore it or re-share the video.",
            "**A public URL stopped serving the bucket.** Fix the CDN or bucket policy, or edit the connection and clear Public URL.",
          ],
        },
        { type: "h2", text: "Deleting a share left the file in my bucket" },
        {
          type: "p",
          text: "Deleting a share removes the file from your bucket when the key still has delete permission. If the bucket refused (for example, the key was revoked), the share is still deleted so its link stops working, and the file is left for you to remove.",
        },
      ],
      related: ["custom-storage", "custom-storage/connect", "custom-storage/cors"],
      lastModified: CHECKED,
    },
  ],
};
