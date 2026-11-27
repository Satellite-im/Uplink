// Where the extension keeps a signed-in Uplink account between one click and the next. Two places, the person's choice
// ("Stay signed in"):
//
// - Off (the default): chrome.storage.session — the browser holds it in memory and empties it when it closes. The
//   account's identity key and the cURL-seal key are there only while the browser is open, and never on disk.
// - On: chrome.storage.local — kept across restarts, on disk in the extension's own area (no page or page-script can
//   read it; only the extension's own pages and worker). The trade is the same one the Ghost.md clipper names: anyone
//   who can already run code as you on this computer could read the profile.
//
// What is kept is the account id (the EIP-55 address), the username, the P-256 identity private key (hex) the hub
// knows the account's devices by, and the seed-derived key the synced cURL entries are sealed with (hex). Never the
// recovery words or the password — those are used the moment they are typed and discarded.

export interface Session {
  v: 1;
  /** The hub this session is with; a session from another build's hub is not reused. */
  hub: string;
  address: string;
  username: string;
  /** The P-256 identity private key, 32 bytes as hex. */
  identity: string;
  /** The cURL-entry seal key, 32 bytes as hex. */
  curlKey: string;
  stay: boolean;
}

const KEY = 'ghost-session';

function area(stay: boolean): chrome.storage.StorageArea {
  return stay ? chrome.storage.local : chrome.storage.session;
}

export const Keeper = {
  async load(): Promise<Session | null> {
    for (const stay of [true, false]) {
      const got = (await area(stay).get(KEY))[KEY] as Session | undefined;
      if (got && got.v === 1) return got;
    }
    return null;
  },
  async save(session: Session): Promise<void> {
    // Keep it in one place only; clear the other so a "stay" toggle doesn't leave a stale copy.
    await area(!session.stay).remove(KEY);
    await area(session.stay).set({ [KEY]: session });
  },
  async clear(): Promise<void> {
    await chrome.storage.session.remove(KEY);
    await chrome.storage.local.remove(KEY);
  },
};
