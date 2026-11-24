import { ORGANIZATION_JSON_LD } from "./json-ld";

/**
 * The iPhone and iPad app on the App Store. The URL carries no country, so
 * Apple sends each visitor to their own storefront.
 */
export const IOS_APP_ID = "6836948540";
export const IOS_APP_STORE_URL = `https://apps.apple.com/app/screen-recorder-capturecat/id${IOS_APP_ID}`;

/**
 * Safari's Smart App Banner, the strip at the top of the page on iPhone and
 * iPad. Safari draws it from this tag alone; structured data plays no part.
 */
export const SMART_APP_BANNER_META = {
  name: "apple-itunes-app",
  content: `app-id=${IOS_APP_ID}`,
};

/** Structured data for the iOS app. No rating until the app has real ones. */
export const IOS_APP_JSON_LD = {
  "@type": "MobileApplication",
  "@id": "https://capturecat.so/#ios-app",
  name: "Screen Recorder: CaptureCat",
  operatingSystem: "iOS 18.0 or later, iPadOS 18.0 or later",
  applicationCategory: "MultimediaApplication",
  description:
    "CaptureCat for iPhone and iPad: record your screen, edit and share the video, and keep every project in sync with your Mac and the web.",
  url: "https://capturecat.so/download#iphone",
  installUrl: IOS_APP_STORE_URL,
  downloadUrl: IOS_APP_STORE_URL,
  sameAs: [IOS_APP_STORE_URL],
  offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
  publisher: { "@id": ORGANIZATION_JSON_LD["@id"] },
};
