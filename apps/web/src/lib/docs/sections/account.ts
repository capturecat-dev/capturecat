import type { DocSection } from "../types";

/**
 * Checked against apps/api/migrations 0008, 0016, 0023, 0025, 0027 and 0029
 * (the seeded plan rows), apps/api/src/lib/plans.ts, lib/upload-policy.ts,
 * lib/project-history.ts, lib/auth.ts, routes/video.ts (shareGate, comments,
 * custom domains), routes/screenshot.ts, routes/desktop.ts, apps/web
 * billing-status.tsx, subscribe-button.tsx, lib/trpc/routers/billing.ts,
 * sign-in-buttons.tsx, nav-user.tsx, share-gate.tsx, and the Mac
 * AuthService, SettingsWindowController and StatusMenuBuilder.
 *
 * Prices are deliberately absent: they live in Stripe and on /pricing.
 */
const CHECKED = "2026-10-07";

export const ACCOUNT: DocSection = {
  id: "account",
  title: "Account and billing",
  description: "Plans, billing, and your account.",
  pages: [
    {
      slug: "account/plans",
      title: "CaptureCat plans: Free, Pro and Business compared",
      navTitle: "Plans",
      description:
        "What CaptureCat Free, Pro and Business include: share links, cloud storage, upload limits, teams, SSO, custom storage and the screenshot API.",
      summary:
        "Recording, editing and export on the Mac are free, with no time limit and no watermark. Paid plans add the hosted side: share links, cloud storage, viewer comments, team libraries and more, each with its own limits.",
      blocks: [
        { type: "h2", text: "What Free includes" },
        {
          type: "p",
          text: "Everything that runs on your Mac: recording, the editor, auto zoom, captions and export at full quality. You don't need an account to record. Free has no cloud storage, so share links, cloud project sync and web page capture need a paid plan.",
        },
        { type: "h2", text: "Features by plan" },
        {
          type: "table",
          head: ["Feature", "Free", "Pro", "Business"],
          rows: [
            ["Record, edit and export on the Mac", "Yes", "Yes", "Yes"],
            ["[Share links](/docs/export-and-sharing/share-links)", "No", "Yes", "Yes"],
            ["[Viewer comments](/docs/export-and-sharing/comments-and-reactions)", "No", "Yes", "Yes"],
            ["[Web page capture](/docs/recording/web-page-capture) by URL", "No", "Yes", "Yes"],
            ["Store screenshots in the cloud", "No", "Yes", "Yes"],
            ["Screenshot API", "No", "Yes", "Yes"],
            ["[Team library](/docs/teams)", "No", "Yes", "Yes"],
            ["[Your own S3 bucket](/docs/custom-storage) for share videos", "No", "Yes", "Yes"],
            ["[Custom share domain](/docs/teams/custom-domains)", "No", "Yes", "Yes"],
            ["AI titles, summaries and chapters for shares", "No", "Yes", "Yes"],
            ["[Enterprise SSO](/docs/teams/sso)", "No", "No", "Yes"],
          ],
        },
        { type: "h2", text: "Limits by plan" },
        {
          type: "table",
          head: ["Limit", "Free", "Pro", "Business"],
          rows: [
            ["Total cloud storage", "None", "100 GB", "1 TB"],
            ["Largest single upload", "None", "5 GB", "10 GB"],
            ["Longest shared video", "None", "2 hours", "4 hours"],
            ["New shares per day", "0", "100", "500"],
            ["Web page and API screenshots per month", "0", "1,000", "5,000"],
            ["Project history kept (web editor sync)", "None", "30 days", "365 days"],
            ["Named versions per project", "None", "25", "500"],
          ],
        },
        {
          type: "callout",
          tone: "note",
          title: "Plans can change",
          text: "These are the plans on capturecat.so as of this page's date. Plans are stored as data and can be changed without an app update, so the [pricing page](https://capturecat.so/pricing) is the current word on prices and on what each plan includes. Business appears there when it is on sale.",
        },
        { type: "h2", text: "How limits are counted" },
        {
          type: "list",
          items: [
            "**Storage** is one pool per account: every version of every share you keep, screenshots stored in the cloud, and the media of projects synced for the [web editor](/docs/web-app/editor). Your dashboard's **Billing** page shows how much you've used.",
            "**Videos in your own bucket** don't count toward total storage. The per-upload size, length and daily share limits still apply. See [custom storage](/docs/custom-storage).",
            "**New shares per day** resets at midnight UTC.",
            "**Screenshots per month** is one counter for web page captures from the app and calls to the screenshot API. It resets on the 1st of each month, UTC.",
            "**Project history** keeps unnamed versions for the number of days shown. Named versions are kept regardless of age, up to the named-version limit.",
          ],
        },
        { type: "h2", text: "Which plan to choose" },
        {
          type: "list",
          items: [
            "**Free** if you record and export on your Mac and share the files yourself.",
            "**Pro** for share links with comments and analytics, cloud sync for the web editor, a team library, a custom share domain, AI summaries, or your own S3 bucket.",
            "**Business** if your team also needs single sign-on (OIDC or SAML) and more storage.",
          ],
        },
        {
          type: "p",
          text: "To subscribe, change or cancel, see [Billing](/docs/account/billing). If you run your own server, you set every plan's features and limits yourself: see [Plans on a self-hosted server](/docs/self-hosting/plans-and-features).",
        },
      ],
      faqs: [
        {
          question: "Is CaptureCat free?",
          answer:
            "Yes. Recording, editing and export in the Mac app are free, with no time limit and no resolution cap. You pay only for the hosted features, such as share links and cloud storage.",
        },
        {
          question: "Do free exports have a watermark?",
          answer:
            "No. The only watermark is your own logo, which you add in the editor's brand settings. It is off by default on every plan.",
        },
        {
          question: "How much storage does CaptureCat Pro include?",
          answer:
            "Pro includes 100 GB of cloud storage, uploads up to 5 GB and 2 hours each, and 100 new shares a day. The pricing page shows the current limits.",
        },
        {
          question: "Which plan includes SSO?",
          answer:
            "Business. Single sign-on with OIDC or SAML is the one feature Business adds over Pro, along with higher limits.",
        },
      ],
      related: ["account/billing", "export-and-sharing/share-links", "custom-storage", "teams"],
      lastModified: CHECKED,
    },
    {
      slug: "account/billing",
      title: "Subscribe, manage or cancel your CaptureCat plan",
      navTitle: "Billing",
      description:
        "Subscribe to CaptureCat Pro, update your card or cancel in the Stripe customer portal, and what happens to share links and storage when a plan ends.",
      summary:
        "Billing runs through Stripe. Subscribe from the pricing page, then manage or cancel from **Billing** in your dashboard with **Manage subscription**. Nothing on your Mac depends on the subscription.",
      blocks: [
        { type: "h2", text: "Subscribe" },
        {
          type: "steps",
          steps: [
            {
              title: "Open the pricing page",
              text: "Go to [capturecat.so/pricing](https://capturecat.so/pricing). Pick **Monthly** or **Annual** when both are offered, then click **Subscribe**.",
            },
            {
              title: "Sign in",
              text: "If you aren't signed in, you're asked to first. Use the same account you use in the Mac app. See [Sign in and sign out](/docs/account/sign-in).",
            },
            {
              title: "Pay in Stripe Checkout",
              text: "Enter your payment details on Stripe's checkout page. CaptureCat never sees your card number. If the plan has a free trial, the pricing card shows its length and you're charged when the trial ends.",
            },
            {
              title: "Start sharing",
              text: "Stripe sends you back to your dashboard's **Billing** page, where the plan shows as **Active**. The Mac app and the web app check your plan with the server, so sharing works in both without reinstalling anything.",
            },
          ],
        },
        {
          type: "p",
          text: "You can also start from the dashboard: open **Billing** at [capturecat.so/app/billing](https://capturecat.so/app/billing) and click **Upgrade to Pro**, which starts monthly billing.",
        },
        { type: "h2", text: "Manage your subscription" },
        {
          type: "p",
          text: "Open **Billing** in your dashboard and click **Manage subscription**. Stripe's customer portal opens, where you manage your payment method and subscription and can cancel. Close it or use its back link to return to CaptureCat.",
        },
        {
          type: "p",
          text: "The Billing page also shows your cloud storage: how much you've used out of your plan's total.",
        },
        { type: "h2", text: "Cancel" },
        {
          type: "p",
          text: "Cancel in the customer portal. Your paid features keep working until the end of the period you've paid for, then your account moves to Free. You can subscribe again at any time.",
        },
        { type: "h2", text: "If a payment fails" },
        {
          type: "p",
          text: "While Stripe retries a failed renewal, your plan stays active. If Stripe ends the subscription after its retries, the account moves to Free as if you had cancelled. Update your card in the customer portal to avoid that.",
        },
        { type: "h2", text: "What happens when a plan ends" },
        {
          type: "list",
          items: [
            "**Share links pause.** Viewers see that the share is paused because the owner's plan no longer includes cloud sharing. The video files are kept, so if you subscribe again, the same links play again.",
            "**Comments stop.** Viewer comments are no longer shown or accepted on your shares.",
            "**Custom share domains stop serving** your videos while your plan doesn't include them.",
            "**Team members lose access** to videos you put in a [team library](/docs/teams) until you're back on a plan with teams.",
            "**Older project history is deleted.** At the next hourly cleanup, cloud versions beyond your new plan's history limits are removed. On Free only the current version of each synced project is kept.",
            "**Nothing on your Mac changes.** Local recordings, projects and exports never depended on the subscription.",
          ],
        },
        {
          type: "callout",
          tone: "warning",
          title: "Save what you need first",
          text: "Moving to a plan with less history deletes cloud versions for good. Before you downgrade, restore or export anything you still need from a synced project's history.",
        },
        { type: "h2", text: "Moving to a smaller plan" },
        {
          type: "p",
          text: "Nothing is deleted to fit a smaller storage limit. If you are over it, new uploads are refused until you delete shares or versions to get under it. Videos in [your own bucket](/docs/custom-storage) stay there and don't count toward the limit.",
        },
      ],
      faqs: [
        {
          question: "How do I cancel CaptureCat Pro?",
          answer:
            "Open Billing in your dashboard at capturecat.so/app/billing, click Manage subscription, and cancel in the Stripe customer portal. Pro keeps working until the end of the period you paid for.",
        },
        {
          question: "Do my share links stop working if I cancel?",
          answer:
            "They pause when the paid period ends: viewers see that the share is paused. The files are kept, and the same links play again if you subscribe again.",
        },
        {
          question: "Can I pay yearly?",
          answer:
            "Yes, when an annual price is offered. Switch the pricing page to Annual before you click Subscribe.",
        },
        {
          question: "Does cancelling affect recordings on my Mac?",
          answer:
            "No. Recording, editing and export on your Mac are free and keep working on any plan, signed in or not.",
        },
      ],
      related: ["account/plans", "account/sign-in", "export-and-sharing/share-links"],
      lastModified: CHECKED,
    },
    {
      slug: "account/sign-in",
      title: "Sign in and sign out of CaptureCat on Mac and web",
      navTitle: "Sign in and out",
      description:
        "Sign in to CaptureCat with Google, Apple or your company's SSO, in the browser and in the Mac app, and how to sign out on each.",
      summary:
        "CaptureCat has no passwords: you sign in with Google, Apple or your company's single sign-on. The Mac app signs in through your default browser and keeps its session in the macOS Keychain.",
      platforms: ["mac", "web"],
      blocks: [
        { type: "h2", text: "When you need an account" },
        {
          type: "p",
          text: "Not to record, edit or export on your Mac. You sign in to share videos, use the [web app](/docs/web-app), sync projects, capture web pages, or manage [billing](/docs/account/billing).",
        },
        { type: "h2", text: "Sign in on the web" },
        {
          type: "steps",
          steps: [
            {
              title: "Open the sign-in page",
              text: "Go to [capturecat.so/login](https://capturecat.so/login).",
            },
            {
              title: "Choose how to sign in",
              text: "Click **Continue with Google** or **Continue with Apple**. If your company uses single sign-on, click **Use single sign-on (SSO)** and enter your work email.",
            },
            {
              title: "Approve with your provider",
              text: "The page redirects to Google, Apple or your identity provider, then back to your dashboard.",
            },
          ],
        },
        { type: "h2", text: "Sign in on the Mac" },
        {
          type: "steps",
          steps: [
            {
              title: "Start sign-in",
              text: "Choose **Sign In…** from the menu bar icon, or open **Settings → Account** and click **Sign In…**. During onboarding, the button is **Sign In with Browser**.",
            },
            {
              title: "Finish in your browser",
              text: "Your default browser opens. Choose Google or Apple (or single sign-on, when your company has set it up) and approve.",
            },
            {
              title: "Return to the app",
              text: "The browser hands the sign-in back to CaptureCat and the app shows your email under **Settings → Account**.",
            },
          ],
        },
        {
          type: "p",
          text: "The app opens your default browser rather than an in-app window, so you can reuse a Google or Apple session you are already signed in to. The session token is stored in your macOS Keychain.",
        },
        { type: "h2", text: "How long you stay signed in" },
        {
          type: "p",
          text: "A session lasts 30 days and is extended as you use it, so an account you use regularly stays signed in.",
        },
        { type: "h2", text: "Sign out" },
        {
          type: "list",
          items: [
            "**On the web:** open your account menu in the dashboard and click **Log out**.",
            "**On the Mac:** open **Settings → Account** and click **Sign Out**, or choose **Sign Out** from the menu bar icon. The app removes the session from your Keychain and ends it on the server.",
          ],
        },
        {
          type: "callout",
          tone: "tip",
          text: "Use the same sign-in on the Mac and the web. Your plan, shares and synced projects belong to the account, so a different Google or Apple account shows a different library.",
        },
      ],
      faqs: [
        {
          question: "Can I sign in to CaptureCat with an email and password?",
          answer:
            "No. CaptureCat supports Google, Apple and company single sign-on only, so there is no password to manage or leak.",
        },
        {
          question: "Do I need to sign in to record on the Mac?",
          answer:
            "No. Recording, editing and export work without an account. You sign in only to share, sync or use the hosted features.",
        },
      ],
      related: ["account/billing", "teams/sso", "getting-started/install"],
      lastModified: CHECKED,
    },
  ],
};
