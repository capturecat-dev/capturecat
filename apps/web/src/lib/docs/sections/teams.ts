import type { DocSection } from "../types";

/**
 * Checked against apps/web: components/dashboard/{team-cards,
 * share-settings-dialog,custom-domains-card,sign-in-buttons}.tsx,
 * routes/accept-invitation.$invitationId.tsx, server.ts (custom-host
 * routing); apps/api: lib/auth.ts (organization + sso plugins and the SSO
 * plan gate), routes/{org,sso,hub,video}.ts, routes/desktop.ts (SSO in the
 * app's sign-in page), lib/cloudflare-saas.ts, lib/plans.ts and the plan rows
 * in migrations 0008, 0023 and 0025.
 */
const CHECKED = "2026-10-07";

export const TEAMS: DocSection = {
  id: "teams",
  title: "Teams and SSO",
  description: "A shared team library, member invites, custom domains and enterprise SSO.",
  pages: [
    // ── Team library ──────────────────────────────────────────────────────
    {
      slug: "teams",
      title: "Team library: share screen recordings with your team",
      navTitle: "Team library",
      description:
        "Create a CaptureCat team, invite teammates with a link, and collect everyone's shared screen recordings in one shared team library. Included in Pro.",
      summary:
        "A team gives your company one shared library of CaptureCat recordings. Anyone signed in can create a team and invite people; adding videos to the team library needs Pro, and single sign-on needs Business.",
      platforms: ["web"],
      plan: "pro",
      blocks: [
        { type: "h2", text: "Create a team" },
        {
          type: "steps",
          steps: [
            {
              title: "Open the Team page",
              text: "In the web dashboard, click **Team** in the sidebar, or go to [capturecat.so/app/team](https://capturecat.so/app/team).",
            },
            {
              title: "Name the team",
              text: "Type a name, for example \"Acme Inc\", and click **Create team**. You become its owner.",
            },
            {
              title: "Add a logo (optional)",
              text: "Click **Upload logo** and choose a PNG, JPEG or WebP image under 1 MB. It shows on the Team page and on invitations.",
            },
            {
              title: "Invite teammates",
              text: "See [Invite teammates](/docs/teams/members).",
            },
          ],
        },
        { type: "p", text: "Each account can create one team." },
        { type: "h2", text: "Add a video to the team library" },
        {
          type: "steps",
          steps: [
            {
              title: "Open Share settings",
              text: "In your library at [capturecat.so/app](https://capturecat.so/app), choose **Share settings** from the video's **…** menu.",
            },
            {
              title: "Turn on Team library",
              text: "The switch reads \"Everyone in Acme Inc can find and watch this video.\" It only appears once you belong to a team.",
            },
            { title: "Click Save", text: "The video now appears in the team library for every member." },
          ],
        },
        {
          type: "p",
          text: "To take a video out of the team library, turn the switch off and save. The video and its share link are not affected either way.",
        },
        { type: "h2", text: "Browse the team library" },
        {
          type: "p",
          text: "The **Team library** section of the Team page lists every video teammates have added, with its date. Click one to open its share page.",
        },
        { type: "h2", text: "Who can do what" },
        {
          type: "table",
          head: ["Action", "Owner", "Admin", "Member"],
          rows: [
            ["Watch videos in the team library", "Yes", "Yes", "Yes"],
            ["Add or remove their own videos", "Yes", "Yes", "Yes"],
            ["Invite people and cancel invitations", "Yes", "Yes", "No"],
            ["Remove members", "Yes", "Yes", "No"],
            ["Upload the team logo", "Yes", "Yes", "No"],
            ["Set up [single sign-on](/docs/teams/sso)", "Yes", "Yes", "No"],
          ],
        },
        {
          type: "p",
          text: "Only the person who shared a video can change its settings, replace it or delete it, even when it is in the team library.",
        },
        { type: "h2", text: "Plans" },
        {
          type: "list",
          items: [
            "Creating a team, inviting people and joining a team are free.",
            "Adding a video to the team library needs Pro on the account of the person adding it.",
            "Each video plays under its uploader's plan. If that plan ends, the uploader's share links pause for everyone, teammates included.",
            "[Single sign-on](/docs/teams/sso) is part of Business.",
          ],
        },
        {
          type: "callout",
          tone: "pro",
          text: "The team library is included in Pro, along with [custom share domains](/docs/teams/custom-domains). Business adds single sign-on.",
        },
      ],
      faqs: [
        {
          question: "How do I share screen recordings with my whole team?",
          answer:
            "Create a team on CaptureCat's Team page, invite your teammates, then turn on **Team library** in each video's Share settings. Everyone in the team finds those videos on the Team page.",
        },
        {
          question: "Does everyone on the team need a paid plan?",
          answer:
            "No. Joining and watching are free. Each person who adds their own videos to the team library needs Pro.",
        },
      ],
      related: ["teams/members", "teams/sso", "teams/custom-domains", "export-and-sharing/share-controls"],
      lastModified: CHECKED,
    },

    // ── Members ───────────────────────────────────────────────────────────
    {
      slug: "teams/members",
      title: "Invite teammates and manage team members",
      navTitle: "Members and invites",
      description:
        "Invite people to your CaptureCat team with a copyable invite link, track pending invitations, remove members, and understand the owner, admin and member roles.",
      summary:
        "Owners and admins invite teammates by email address, then copy the invite link and send it themselves; CaptureCat does not email invitations. An invitation lasts seven days and must be accepted by the account with that email address.",
      platforms: ["web"],
      blocks: [
        { type: "h2", text: "Invite someone" },
        {
          type: "steps",
          steps: [
            {
              title: "Open the Team page",
              text: "Go to [capturecat.so/app/team](https://capturecat.so/app/team). You need to be the team's owner or an admin.",
            },
            {
              title: "Enter their email and click Invite",
              text: "Type the address they sign in to CaptureCat with, such as `teammate@company.com`, and click **Invite**. They are added to the list with an **invited** badge.",
            },
            {
              title: "Copy the link and send it",
              text: "Click **Copy link** on their row and send it by email or chat. CaptureCat does not send invitation emails.",
            },
          ],
        },
        { type: "h2", text: "Accept an invitation" },
        {
          type: "p",
          text: "The invite link has the form `https://capturecat.so/accept-invitation/<id>`. Open it, sign in with the invited email address, and click the **Join** button with your team's name on it. You land on the team's page.",
        },
        {
          type: "p",
          text: "If the link has expired, was cancelled, or you are signed in with a different email address, the page says \"This invitation is invalid, expired, or was sent to a different email address.\" Ask for a new invitation to the right address.",
        },
        { type: "h2", text: "Manage members and invitations" },
        {
          type: "list",
          items: [
            "**Cancel an invitation:** click the trash icon on a pending row. The link stops working.",
            "**Remove a member:** click the trash icon on their row. The team's owner cannot be removed.",
            "Invitations expire after seven days. Invite the person again for a fresh link.",
          ],
        },
        { type: "h2", text: "Roles" },
        {
          type: "table",
          head: ["Role", "Who has it", "Can"],
          rows: [
            ["**Owner**", "The person who created the team", "Everything: invite and remove people, upload the logo, set up single sign-on."],
            ["**Admin**", "Members given the admin role", "The same as the owner, except that an admin cannot remove the owner."],
            ["**Member**", "Everyone who joins by invitation or single sign-on", "Watch the team library and add their own videos to it."],
          ],
        },
        {
          type: "p",
          text: "Invitations always join as members, and the dashboard has no control for changing a member's role yet.",
        },
        {
          type: "p",
          text: "With [single sign-on](/docs/teams/sso), people on your email domain join as members the first time they sign in, with no invitation needed.",
        },
      ],
      faqs: [
        {
          question: "Why didn't my teammate get an invitation email?",
          answer:
            "CaptureCat does not send invitation emails. After you click **Invite**, click **Copy link** on their row and send the link yourself.",
        },
        {
          question: "How long does a team invitation last?",
          answer: "Seven days. After that, invite the person again to get a new link.",
        },
      ],
      related: ["teams", "teams/sso"],
      lastModified: CHECKED,
    },

    // ── Custom domains ────────────────────────────────────────────────────
    {
      slug: "teams/custom-domains",
      title: "Use a custom domain for share links",
      navTitle: "Custom domains",
      description:
        "Serve CaptureCat share pages from your own domain, such as share.yourcompany.com: add the domain, point a CNAME at customers.capturecat.so, and verify.",
      summary:
        "Add a subdomain you own in **Settings → Custom share domain**, create a CNAME record pointing to `customers.capturecat.so`, and click **Verify**. Once the DNS record and HTTPS certificate are active, your videos play at `https://share.yourcompany.com/<video-id>`.",
      platforms: ["web"],
      plan: "pro",
      blocks: [
        { type: "h2", text: "Set up a custom domain" },
        {
          type: "steps",
          steps: [
            {
              title: "Pick a subdomain",
              text: "Use a subdomain you control, such as `share.yourcompany.com` or `video.yourcompany.com`. Verification looks for a CNAME record, which a bare domain like `yourcompany.com` cannot usually have.",
            },
            {
              title: "Add it in Settings",
              text: "Open [Settings](https://capturecat.so/app/settings), find **Custom share domain**, type the domain and click **Add domain**. It is listed with a **pending DNS** badge.",
            },
            {
              title: "Create the CNAME record",
              text: "At your DNS host, add a CNAME record for the subdomain (for `share.yourcompany.com`, the name is `share`) pointing to `customers.capturecat.so`. The card shows the exact target to use.",
            },
            {
              title: "Click Verify",
              text: "CaptureCat looks up the CNAME and checks the domain's HTTPS certificate. When the record is found the badge changes to **verified**. If not, the message shows what was found and what was expected; DNS changes can take a few minutes, so try again.",
            },
          ],
        },
        {
          type: "p",
          text: "The domain starts serving share pages once the CNAME is in place and its HTTPS certificate has been issued, usually within minutes of the record appearing.",
        },
        { type: "h2", text: "Addresses on your domain" },
        {
          type: "table",
          head: ["Address", "What it serves"],
          rows: [
            ["`https://share.yourcompany.com/<video-id>`", "The share page"],
            ["`https://share.yourcompany.com/share/<video-id>`", "The share page (same as above)"],
            ["`https://share.yourcompany.com/e/<video-id>`", "The embeddable player, for iframes. See [Embed](/docs/export-and-sharing/embed)."],
          ],
        },
        {
          type: "list",
          items: [
            "Your domain serves only your own videos. Any other address on it redirects to capturecat.so.",
            "The `<video-id>` is the last part of the video's capturecat.so link. The dashboard and the Mac app keep showing capturecat.so links, and both addresses keep working.",
            "Every share control (password, expiry, view limit, privacy) applies on your domain too.",
          ],
        },
        { type: "h2", text: "Limits and errors" },
        {
          type: "table",
          head: ["Message", "Meaning"],
          rows: [
            ["Enter a valid domain, e.g. share.yourcompany.com", "Type the host name only, with no `https://` or path."],
            ["That domain is already in use", "Another account has added it. If their claim was never verified, it lapses after a day and you can add the domain then."],
            ["Domain limit reached", "An account can have up to three custom domains. Remove one first."],
            ["That domain is reserved", "capturecat.so addresses cannot be added."],
          ],
        },
        {
          type: "p",
          text: "To stop using a domain, click the trash icon next to it. Its certificate is removed and links on it stop working; the capturecat.so links are unaffected.",
        },
        {
          type: "callout",
          tone: "pro",
          text: "Custom share domains are part of Pro. If your plan stops including them, the domain stops serving within minutes and every link keeps working on capturecat.so.",
        },
      ],
      faqs: [
        {
          question: "Can I share screen recordings from my own domain?",
          answer:
            "Yes. On Pro, add a subdomain such as `share.yourcompany.com` in Settings, point a CNAME at `customers.capturecat.so`, and verify it. Your videos then play at `share.yourcompany.com/<video-id>`.",
        },
        {
          question: "What CNAME target does CaptureCat use?",
          answer:
            "`customers.capturecat.so`. The **Custom share domain** card in Settings shows the exact target for your account.",
        },
        {
          question: "Do I need to set up HTTPS myself?",
          answer:
            "No. CaptureCat registers the domain with its CDN when you add it and the HTTPS certificate is issued automatically once the CNAME is in place.",
        },
      ],
      related: ["export-and-sharing/share-links", "export-and-sharing/embed", "teams"],
      lastModified: CHECKED,
    },

    // ── SSO ───────────────────────────────────────────────────────────────
    {
      slug: "teams/sso",
      title: "Set up SAML or OIDC single sign-on (SSO)",
      navTitle: "Single sign-on (SSO)",
      description:
        "Connect Okta, Microsoft Entra, Google Workspace or any OIDC or SAML identity provider to CaptureCat so teammates sign in with SSO and join your team.",
      summary:
        "On Business, a team owner or admin adds the company's identity provider on the Team page, proves the email domain with a DNS TXT record, and enters CaptureCat's redirect URI or ACS URL in the provider. Teammates then sign in with their work email and join the team automatically.",
      platforms: ["mac", "web"],
      plan: "business",
      blocks: [
        { type: "h2", text: "Before you start" },
        {
          type: "list",
          items: [
            "A CaptureCat Business plan, and a [team](/docs/teams) where you are the owner or an admin.",
            "Admin access to your identity provider (Okta, Microsoft Entra, Google Workspace, or any OIDC or SAML 2.0 provider).",
            "Access to the DNS for your email domain, to add a TXT record.",
          ],
        },
        { type: "h2", text: "Connect your identity provider" },
        {
          type: "steps",
          steps: [
            {
              title: "Add a provider",
              text: "On the [Team page](https://capturecat.so/app/team), find **Single sign-on**, click **Add provider** and choose **OIDC** or **SAML**.",
            },
            {
              title: "Enter the provider details",
              text: "Fill in **Email domain** (for example `acme.com`) and optionally a **Provider ID** (it appears in your redirect URI and defaults to the domain). For OIDC, enter the **Issuer URL** (CaptureCat reads `/.well-known/openid-configuration` from it), **Client ID** and **Client secret**. For SAML, enter the **Issuer / entity ID**, the **Sign-on URL** (the IdP's SAML 2.0 HTTP-Redirect endpoint) and the **Signing certificate (PEM)**. Click **Add provider**.",
            },
            {
              title: "Prove you own the domain",
              text: "The provider's setup panel shows a **TXT name** and **TXT value**. Add that TXT record at your DNS host, then click **Verify domain**. Nobody can sign in through the provider until this passes.",
            },
            {
              title: "Configure your identity provider",
              text: "For OIDC, register the **Redirect URI** from the setup panel on your OIDC application. For SAML, enter the **ACS URL** and **SP metadata** URL from the setup panel in your IdP. Each has a copy button.",
            },
            {
              title: "Assign people in your identity provider",
              text: "Give the people who should use CaptureCat access to the application in your IdP.",
            },
          ],
        },
        {
          type: "table",
          head: ["Value", "Form"],
          rows: [
            ["TXT name", "`_better-auth-token-<provider-id>.<your-domain>`"],
            ["OIDC redirect URI", "`https://api.capturecat.so/api/auth/sso/callback/<provider-id>`"],
            ["SAML ACS URL", "`https://api.capturecat.so/api/auth/sso/saml2/sp/acs/<provider-id>`"],
            ["SAML SP metadata", "`https://api.capturecat.so/api/auth/sso/saml2/sp/metadata?providerId=<provider-id>`"],
          ],
        },
        {
          type: "p",
          text: "Always copy the values from the setup panel; the table only shows their shape. The client secret is stored encrypted and is never shown again. If the TXT value expires before you publish it (after seven days), a new one is shown.",
        },
        { type: "h2", text: "How teammates sign in" },
        {
          type: "list",
          items: [
            "**On the web:** on the [sign-in page](https://capturecat.so/login), click **Use single sign-on (SSO)**, enter the work email and click **Continue**.",
            "**In the Mac app:** start signing in from **Settings → Account → Sign In…**. On the sign-in page that opens in the browser, choose **Use single sign-on (SSO)**, enter the work email and click **Continue**.",
            "The first sign-in creates their CaptureCat account and adds them to your team as a **member**, with no invitation needed.",
          ],
        },
        { type: "h2", text: "Remove a provider" },
        {
          type: "p",
          text: "Click the trash icon next to the provider and confirm **Remove**. Teammates can no longer sign in through it.",
        },
        {
          type: "callout",
          tone: "pro",
          text: "Single sign-on is part of Business. On other plans the Team page shows \"Single sign-on is part of Business.\" and providers cannot be added.",
        },
      ],
      faqs: [
        {
          question: "Does CaptureCat support SAML and OIDC single sign-on?",
          answer:
            "Yes. On Business, connect any OIDC or SAML 2.0 identity provider, such as Okta, Microsoft Entra or Google Workspace, from the Team page.",
        },
        {
          question: "Why does SSO sign-in fail right after I added the provider?",
          answer:
            "Sign-in stays off until the email domain is verified. Publish the TXT record from the setup panel and click **Verify domain**; DNS can take a few minutes.",
        },
        {
          question: "Do SSO users need an invitation?",
          answer:
            "No. Anyone who signs in through your provider joins your team as a member automatically.",
        },
      ],
      related: ["teams", "teams/members", "account/plans"],
      lastModified: CHECKED,
    },
  ],
};
