// The extension's worker: it holds the signed-in account (via the Keeper), captures each service's cookies, and
// keeps the ready ones synced to the account so every device signs in. The popup drives sign-in and manual captures;
// this also re-syncs on its own a few seconds after a service's cookies change, so a fresh sign-in in the browser
// reaches the other devices without another click.
import { GhostAccount, NeedsCode, type CaptureEntry } from './ghost/account.ts';
import { capture, heldTokens } from './ghost/cookies.ts';
import { hex, randomIdentity, unhex } from './ghost/crypto.ts';
import { Keeper } from './ghost/keeper.ts';
import { GOOGLE, GOOGLE_KEEP, SERVICES, serviceById } from './ghost/services.ts';

type Reply = Record<string, unknown>;

/** The identity a password sign-in asks for a texted code under and then signs in with (the relay keeps a code for
 *  whoever asked: GhostAccount.textCode). Kept for the browser session, so a worker restart between the two keeps it. */
async function signInIdentity(): Promise<Uint8Array> {
  const held = (await chrome.storage.session.get('signin-identity'))['signin-identity'] as string | undefined;
  if (held) return unhex(held);
  const fresh = randomIdentity();
  await chrome.storage.session.set({ 'signin-identity': hex(fresh) });
  return fresh;
}

/** The signed-in account, loaded lazily from the keeper. null = signed out. */
let account: GhostAccount | null = null;
let loaded = false;

async function current(): Promise<GhostAccount | null> {
  if (!loaded) {
    const held = await Keeper.load();
    account = held ? GhostAccount.fromSession(held) : null;
    loaded = true;
  }
  return account;
}

/** A short word for where a capture came from, shown on the other devices' side if ever surfaced. */
const FROM = 'Chrome';

/** What the popup sees about each service: its name, whether it is signed in in the browser, and what is synced. */
async function status(): Promise<Reply> {
  const acct = await current();
  const synced = acct ? await acct.entries().catch(() => ({} as Record<string, CaptureEntry>)) : {};
  const services = await Promise.all(
    SERVICES.map(async (s) => {
      const cap = await capture(s);
      return { id: s.id, name: s.name, signInUrl: s.signInUrl, ready: cap.ready, missing: cap.missing, synced: !!synced[s.id], syncedAt: synced[s.id]?.at ?? null };
    }),
  );
  const google = { synced: !!synced[GOOGLE.id], syncedAt: synced[GOOGLE.id]?.at ?? null, open: google_ !== null, incognito: await chrome.extension.isAllowedIncognitoAccess() };
  return { signedIn: !!acct, address: acct?.address ?? null, username: acct?.username ?? null, services, google };
}

/** Captures the ready services (or just `only`) and syncs them. Returns the updated status. */
async function captureAndSync(only?: string): Promise<Reply> {
  const acct = await current();
  if (!acct) return { error: 'Sign in to your Uplink account first.' };
  const entries: Record<string, CaptureEntry> = {};
  for (const s of SERVICES) {
    if (only && s.id !== only) continue;
    const cap = await capture(s);
    if (cap.ready) entries[s.id] = { cookies: cap.cookies, at: Date.now(), from: FROM };
  }
  if (Object.keys(entries).length === 0) {
    return { ...(await status()), note: only ? 'You are not signed in to that service in this browser.' : 'No services are signed in to in this browser yet.' };
  }
  try {
    await acct.sync(entries);
    await rememberSynced(entries);
  } catch (e) {
    return { ...(await status()), error: (e as Error).message };
  }
  return status();
}

// --- auto-sync when a service's cookies change ----------------------------------------------------------------------

const DOMAINS = new Set(SERVICES.flatMap((s) => s.domains.map((d) => d.replace(/^\./, ''))));
let timer: ReturnType<typeof setTimeout> | undefined;

function domainWatched(domain: string): boolean {
  const d = domain.replace(/^\./, '');
  for (const base of DOMAINS) if (d === base || d.endsWith(`.${base}`)) return true;
  return false;
}

/** A per-service fingerprint of the cookies last synced, so we don't re-seal an unchanged login. */
async function rememberSynced(entries: Record<string, CaptureEntry>): Promise<void> {
  const prints: Record<string, string> = {};
  for (const [id, e] of Object.entries(entries)) prints[id] = fingerprint(e.cookies);
  const had = ((await chrome.storage.local.get('synced-prints'))['synced-prints'] as Record<string, string>) ?? {};
  await chrome.storage.local.set({ 'synced-prints': { ...had, ...prints } });
}

function fingerprint(cookies: Record<string, string>): string {
  return Object.keys(cookies).sort().map((k) => `${k}=${cookies[k]}`).join(';');
}

async function autoSync(): Promise<void> {
  const acct = await current();
  if (!acct) return;
  const prints = ((await chrome.storage.local.get('synced-prints'))['synced-prints'] as Record<string, string>) ?? {};
  const entries: Record<string, CaptureEntry> = {};
  for (const s of SERVICES) {
    const cap = await capture(s);
    if (cap.ready && fingerprint(cap.cookies) !== prints[s.id]) entries[s.id] = { cookies: cap.cookies, at: Date.now(), from: FROM };
  }
  if (Object.keys(entries).length === 0) return;
  try {
    await acct.sync(entries);
    await rememberSynced(entries);
  } catch {
    // Offline or signed out: the next cookie change, or a popup open, tries again.
  }
}

chrome.cookies.onChanged.addListener((info) => {
  if (!domainWatched(info.cookie.domain)) return;
  clearTimeout(timer);
  timer = setTimeout(() => void autoSync(), 4000);
});

// --- tokens: Discord's and Slack's, from their own requests ---------------------------------------------------------
// Only the Authorization header of discord.com/api requests and the `token` field of slack.com/api requests are read:
// nothing else of a request, and no page. Kept by service id; a new one (signed in again, another workspace) replaces it.

async function keepToken(id: string, token: string): Promise<void> {
  const held = await heldTokens();
  if (held[id] === token) return;
  await chrome.storage.local.set({ tokens: { ...held, [id]: token } });
  clearTimeout(timer);
  timer = setTimeout(() => void autoSync(), 4000);
}

for (const s of SERVICES) {
  const t = s.token;
  if (!t) continue;
  if (t.from === 'header') {
    chrome.webRequest.onBeforeSendHeaders.addListener(
      (d) => {
        const value = d.requestHeaders?.find((h) => h.name.toLowerCase() === 'authorization')?.value?.trim();
        // A user token is one word; "Bearer …" and "Bot …" are an app's, not the person's.
        if (value && !value.includes(' ') && value.length > 30) void keepToken(s.id, value);
        return undefined;
      },
      { urls: t.urls },
      ['requestHeaders', 'extraHeaders'],
    );
  } else {
    chrome.webRequest.onBeforeRequest.addListener(
      (d) => {
        const field = d.requestBody?.formData?.token?.[0];
        const value = (typeof field === 'string' ? field : undefined) ?? new URL(d.url).searchParams.get('token') ?? undefined;
        if (value && /^xox[cp]-/.test(value)) void keepToken(s.id, value);
        return undefined;
      },
      { urls: t.urls },
      ['requestBody'],
    );
  }
}

// --- Google Messages, in a private window (GMFB-10) ------------------------------------------------------------------

/** The private window opened to sign in to Google, and its cookie store: what the Google capture reads, and only it. */
let google_: { windowId: number; storeId: string } | null = null;
let googleTimer: ReturnType<typeof setTimeout> | undefined;

/** Opens Google's sign-in in a private window; its cookies are captured once it's signed in ([googleCapture]). */
async function googleSetup(): Promise<Reply> {
  const acct = await current();
  if (!acct) return { error: 'Sign in to your Uplink account first.' };
  if (!(await chrome.extension.isAllowedIncognitoAccess())) {
    return { ...(await status()), error: 'Chrome needs to let the extension into private windows first: open chrome://extensions, choose Details on Uplink keys, and turn on Allow in Incognito. Then try again.' };
  }
  const win = await chrome.windows.create({ url: GOOGLE.signInUrl, incognito: true, focused: true });
  if (!win) return { ...(await status()), error: 'The private window could not be opened.' };
  const tabId = win.tabs?.[0]?.id;
  const stores = await chrome.cookies.getAllCookieStores();
  const store = stores.find((st) => tabId !== undefined && st.tabIds.includes(tabId)) ?? stores.find((st) => st.id !== '0');
  if (win.id === undefined || !store) return { ...(await status()), error: 'The private window could not be opened.' };
  google_ = { windowId: win.id, storeId: store.id };
  return { ...(await status()), note: 'Sign in to the Google account your Google Messages uses, in the private window. It closes by itself once Uplink has the sign-in.' };
}

/** Once the private window is signed in to Google: its sign-in sealed and synced, and the window closed, so that
 * sign-in is left alone (a private window's ends when it closes, and nothing changes it after). */
async function googleCapture(): Promise<void> {
  const g = google_;
  const acct = await current();
  if (!g || !acct) return;
  const cap = await capture(GOOGLE, g.storeId);
  if (!cap.ready) return;
  const cookies: Record<string, string> = {};
  for (const name of GOOGLE_KEEP) if (cap.cookies[name]) cookies[name] = cap.cookies[name];
  try {
    await acct.sync({ [GOOGLE.id]: { cookies, at: Date.now(), from: FROM } });
    google_ = null;
    await chrome.windows.remove(g.windowId).catch(() => undefined);
    await chrome.storage.local.set({ 'google-note': 'Google Messages is ready to set up in Uplink: open Settings › Google Messages on a device and choose "Use the Google sign-in from your browser".' });
  } catch {
    // Offline: the next cookie change in the window tries again.
  }
}

chrome.cookies.onChanged.addListener((info) => {
  const g = google_;
  if (!g || info.cookie.storeId !== g.storeId || !info.cookie.domain.replace(/^\./, '').endsWith('google.com')) return;
  clearTimeout(googleTimer);
  googleTimer = setTimeout(() => void googleCapture(), 2500);
});

chrome.windows.onRemoved.addListener((id) => {
  if (google_?.windowId === id) google_ = null;
});

// --- messages from the popup ----------------------------------------------------------------------------------------

chrome.runtime.onMessage.addListener((msg: { type: string; [k: string]: unknown }, _sender, sendResponse) => {
  (async (): Promise<Reply> => {
    switch (msg.type) {
      case 'status':
        return status();
      case 'textCode': {
        try {
          await GhostAccount.textCode(msg.username as string, msg.number as string, await signInIdentity());
          return { ...(await status()), note: 'Code sent. It lasts ten minutes.' };
        } catch (e) {
          return { ...(await status()), error: (e as Error).message, needsCode: true };
        }
      }
      case 'signInPassword': {
        try {
          const acct = await GhostAccount.signInWithPassword(msg.username as string, msg.password as string, {
            number: msg.number as string | undefined,
            code: msg.code as string | undefined,
            identity: msg.code ? await signInIdentity() : undefined,
          });
          await chrome.storage.session.remove('signin-identity');
          await Keeper.save({ ...acct.session, stay: !!msg.stay });
          account = acct;
          loaded = true;
          return captureAndSync();
        } catch (e) {
          return { error: (e as Error).message, needsCode: e instanceof NeedsCode };
        }
      }
      case 'signOut':
        await Keeper.clear();
        account = null;
        loaded = true;
        await chrome.storage.local.remove('synced-prints');
        return { signedIn: false };
      case 'sync':
        return captureAndSync(msg.serviceId as string | undefined);
      case 'googleSetup':
        return googleSetup();
      case 'status-note': {
        const note = (await chrome.storage.local.get('google-note'))['google-note'] as string | undefined;
        if (note) await chrome.storage.local.remove('google-note');
        return { ...(await status()), note };
      }
      case 'forget': {
        const acct = await current();
        if (acct && serviceById(msg.serviceId as string)) {
          await acct.forget(msg.serviceId as string).catch(() => undefined);
          const prints = ((await chrome.storage.local.get('synced-prints'))['synced-prints'] as Record<string, string>) ?? {};
          delete prints[msg.serviceId as string];
          await chrome.storage.local.set({ 'synced-prints': prints });
        }
        return status();
      }
      default:
        return { error: `unknown message ${msg.type}` };
    }
  })().then(sendResponse);
  return true; // reply is async
});
