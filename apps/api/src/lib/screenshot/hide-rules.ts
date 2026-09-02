/**
 * CSS hide-lists for block_cookie_banners / block_chats.
 *
 * Cookie-banner coverage is the EasyList Cookie List (cookie-rules.ts, a
 * generated artifact shared with the macOS app) PLUS the curated selectors
 * below — hand-verified rules (Google/Stripe interstitials etc.) kept as a
 * local overrides layer on top of the list. `hide_selectors` still exists for
 * anything both layers miss.
 */
import { GENERIC_COOKIE_CSS, domainCookieSelectors } from "./cookie-rules";

export const COOKIE_BANNER_SELECTORS: string[] = [
  // OneTrust
  "#onetrust-consent-sdk",
  "#onetrust-banner-sdk",
  // Cookiebot
  "#CybotCookiebotDialog",
  "#CybotCookiebotDialogBodyUnderlay",
  // Quantcast / TCF CMPs
  "#qc-cmp2-container",
  ".qc-cmp2-container",
  // TrustArc
  "#truste-consent-track",
  ".truste_box_overlay",
  ".truste_overlay",
  // Didomi
  "#didomi-host",
  "#didomi-popup",
  // Usercentrics
  "#usercentrics-root",
  "#usercentrics-cmp-ui",
  // Sourcepoint
  ".sp-message-container",
  "[id^='sp_message_container']",
  // Osano
  ".osano-cm-window",
  // CookieYes
  ".cky-consent-container",
  ".cky-overlay",
  // Complianz
  "#cmplz-cookiebanner-container",
  // Borlabs
  "#BorlabsCookieBox",
  // iubenda
  "#iubenda-cs-banner",
  // Termly
  "#termly-code-snippet-support",
  // Google consent interstitial ("Before you continue to Google…"):
  // #xe7COe is the dialog wrapper, #KjcHPc its scrim, #CXQnmb the card;
  // the aria-label rule is the fallback for when the obfuscated ids rotate.
  "#xe7COe",
  "#CXQnmb",
  "#KjcHPc",
  "div[aria-modal='true'][aria-label*='Before you continue']",
  // Stripe (self-hosted CookieSettings card, bottom-right)
  "#cookie-settings-notification",
  "[data-testid='cookie-settings-notification']",
  "[class*='CookieSettings_CookieSettings_']",
  // Generic patterns
  "[class*='cookie-banner']",
  "[id*='cookie-banner']",
  "[class*='cookie-consent']",
  "[id*='cookie-consent']",
  "[aria-label='cookieconsent']",
];

export const CHAT_WIDGET_SELECTORS: string[] = [
  // Intercom
  "#intercom-container",
  ".intercom-lightweight-app",
  "iframe[name='intercom-launcher-frame']",
  // Drift
  "#drift-frame-controller",
  "#drift-frame-chat",
  "#drift-widget-container",
  // Zendesk
  "iframe#launcher",
  "iframe[title='Button to launch messaging window']",
  "#webWidget",
  // Crisp
  "#crisp-chatbox",
  // Tawk.to
  "iframe[title='chat widget']",
  "#tawkchat-container",
  // HubSpot
  "#hubspot-messages-iframe-container",
  // LiveChat
  "#chat-widget-container",
  // Tidio
  "#tidio-chat",
  "iframe#tidio-chat-iframe",
  // Freshchat
  "#fc_frame",
  // Olark
  "#olark-wrapper",
  // Gorgias
  "#gorgias-chat-container",
];

/**
 * Scroll-lock releases paired with COOKIE_BANNER_SELECTORS: consent managers
 * that lock body scroll while their modal is up. Hiding the modal alone leaves
 * `overflow:hidden` behind, which truncates full-page height measures.
 * Scoped to verified lock classes — never a bare `body` override.
 */
export const COOKIE_BANNER_SCROLL_RESTORE: string[] = [
  // Google consent: body gets .EM1Mrb { overflow: hidden }
  "body.EM1Mrb",
];

/**
 * One `<style>` payload hiding everything requested. Selectors were validated
 * upstream (no `{ } < >`), so string-joining them here cannot escape the block.
 */
export function buildHideCss(opts: {
  cookieBanners: boolean;
  chats: boolean;
  extraSelectors: string[];
  /** Hostname of the captured URL — enables EasyList domain-scoped rules. */
  host?: string | null;
}): string | null {
  const selectors = [
    ...(opts.cookieBanners ? COOKIE_BANNER_SELECTORS : []),
    ...(opts.cookieBanners ? domainCookieSelectors(opts.host) : []),
    ...(opts.chats ? CHAT_WIDGET_SELECTORS : []),
    ...opts.extraSelectors,
  ];
  if (selectors.length === 0 && !opts.cookieBanners) return null;
  const blocks: string[] = [];
  if (opts.cookieBanners) blocks.push(GENERIC_COOKIE_CSS);
  if (selectors.length > 0) {
    blocks.push(
      `${selectors.join(",\n")} { display: none !important; visibility: hidden !important; }`,
    );
  }
  if (opts.cookieBanners) {
    blocks.push(
      `${COOKIE_BANNER_SCROLL_RESTORE.join(",\n")} { overflow: visible !important; }`,
    );
  }
  return blocks.join("\n");
}
