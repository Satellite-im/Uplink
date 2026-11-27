// The cookie-login services the app reaches through a sidecar (messaging/lib/inbox/account_helper.dart's
// HelperService). The extension captures a signed-in browser's cookies for each and syncs them; the app signs in
// with them. Adding a service here (and in account_helper.dart) is all it takes — the rest of the extension iterates
// this list, so "any sidecar service" is covered without further code.
//
// `needed` are the cookies a service cannot sign in without: the extension treats a site as "signed in and ready to
// sync" once all of them are present. The app re-filters what it keeps per service (cookiesOf), so capturing the
// whole site's cookies is fine. LinkedIn was here and is gone, as from the app (Matt, 2026-11-21: "linked in keeps
// automatically signing our sessions out remove the plugin"): LinkedIn ended the session whenever it was used elsewhere.

export interface Service {
  /** The network id in the app ("messenger"), which the synced entry is filed under. */
  id: string;
  name: string;
  /** The cookie domains to read (a leading dot matches subdomains). Messenger spans two. */
  domains: string[];
  /** The cookies that must be present for a sign-in; the capture is "ready" once they all are. */
  needed: string[];
  /** Where the person signs in, opened from the popup. */
  signInUrl: string;
  /**
   * Where a service that signs in with a token beside its cookies (Discord, Slack) sends it: the extension reads it from
   * the site's own requests to these addresses (webRequest, never the page) and keeps it as the pseudo-cookie `token`,
   * which the app's helper takes (messaging/lib/inbox/account_helper.dart). `header`: an Authorization header's value
   * (Discord's is the token itself); `body`: a form field called `token` (Slack's xoxc- token).
   */
  token?: { urls: string[]; from: 'header' | 'body' };
}

export const SERVICES: Service[] = [
  {
    id: 'messenger',
    name: 'Messenger',
    domains: ['.messenger.com', '.facebook.com'],
    needed: ['xs', 'c_user', 'datr'],
    signInUrl: 'https://www.messenger.com/',
  },
  {
    id: 'instagram',
    name: 'Instagram',
    domains: ['.instagram.com'],
    needed: ['sessionid', 'csrftoken', 'ds_user_id'],
    signInUrl: 'https://www.instagram.com/direct/inbox/',
  },
  // Discord, X and Slack (Matt, 2026-11-21: "Implement the discord one Twitter and slack").
  {
    id: 'discord',
    name: 'Discord',
    domains: ['.discord.com'],
    needed: ['token'],
    signInUrl: 'https://discord.com/channels/@me',
    token: { urls: ['https://discord.com/api/*'], from: 'header' },
  },
  {
    id: 'twitter',
    name: 'X',
    domains: ['.x.com'],
    needed: ['auth_token', 'ct0'],
    signInUrl: 'https://x.com/messages',
  },
  {
    id: 'slack',
    name: 'Slack',
    domains: ['.slack.com'],
    needed: ['d', 'token'],
    signInUrl: 'https://app.slack.com/client',
    token: { urls: ['https://*.slack.com/api/*'], from: 'body' },
  },
];

/**
 * Google Messages (RCS), set up by Google account (GMFB-10, @kevin: "Getting rcs is annoying due to the workaround we
 * are using so maybe making a chrome extension to automate is a better solution"). The app's own Google sign-in asks
 * for a private window, signing in to Google, "Copy as cURL" and a paste (messaging/lib/gm/google_signin.dart); this
 * does the window and the copy. Kept out of [SERVICES] on purpose: it is never read from the browser's own profile
 * (Google keeps changing that sign-in, and a pairing made from it stops working), only from the private window the
 * popup opens for it, which is closed once captured so the sign-in stays as it was. The names are the app's
 * googleCookieNames; the address is its googleSignInUrl.
 */
export const GOOGLE: Service = {
  id: 'gmessages',
  name: 'Google Messages (RCS)',
  domains: ['.google.com'],
  needed: ['SID', 'HSID', 'SSID', 'OSID', 'APISID', 'SAPISID'],
  signInUrl: 'https://accounts.google.com/AccountChooser?continue=https://messages.google.com/web/config',
};

/** The cookies of [GOOGLE] the app takes; the rest of google.com's are left out of what is synced. */
export const GOOGLE_KEEP = ['SID', 'HSID', 'SSID', 'OSID', 'APISID', 'SAPISID', '__Secure-1PSIDTS'];

export const serviceById = (id: string): Service | undefined => (id === GOOGLE.id ? GOOGLE : SERVICES.find((s) => s.id === id));
