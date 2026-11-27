// Reading a signed-in browser's cookies for a service, through chrome.cookies (the `cookies` permission plus host
// access to the service's domains). chrome.cookies returns httpOnly cookies — xs, sessionid, li_at and the rest that
// document.cookie cannot see — which is exactly why the capture has to happen in the extension, not a page script.
import type { Service } from './services.ts';

export interface Capture {
  cookies: Record<string, string>;
  /** True when every `needed` cookie is present: the service is signed in and worth syncing. */
  ready: boolean;
  /** Which `needed` cookies are missing (empty when ready). */
  missing: string[];
}

/** Every cookie set for a service's domains, name -> value. Later domains win a name clash (none is expected). */
export async function readCookies(service: Service, storeId?: string): Promise<Record<string, string>> {
  const out: Record<string, string> = {};
  for (const domain of service.domains) {
    let got: chrome.cookies.Cookie[] = [];
    try {
      got = await chrome.cookies.getAll(storeId ? { domain, storeId } : { domain });
    } catch {
      got = [];
    }
    for (const c of got) if (c.value) out[c.name] = c.value;
  }
  return out;
}

/** The tokens seen in the services' own requests (background.ts, webRequest), by service id. */
export async function heldTokens(): Promise<Record<string, string>> {
  try {
    return ((await chrome.storage.local.get('tokens'))['tokens'] as Record<string, string>) ?? {};
  } catch {
    return {};
  }
}

/** What a capture of `service` holds now; from the cookie store [storeId] (a private window's) where given. */
export async function capture(service: Service, storeId?: string): Promise<Capture> {
  const cookies = await readCookies(service, storeId);
  // Discord's and Slack's token, seen in their own requests, rides with the cookies as `token`.
  if (service.token && !storeId) {
    const token = (await heldTokens())[service.id];
    if (token) cookies.token = token;
  }
  const missing = service.needed.filter((n) => !(n in cookies) || cookies[n] === '');
  return { cookies, ready: missing.length === 0, missing };
}
