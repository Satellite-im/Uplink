// The Uplink account as the extension holds it: a device of the account that signs in with the recovery
// words or a username + password (the same two ways the app's SignInScreen offers), opens the account's backup to
// learn the shared identity and seed, and then — on its own hub connection as that identity — reads and writes the
// synced cURL entries sealed under the seed-derived key. Mirrors messaging/lib/account/account.dart's signInWithWords
// / signInWithPassword and messaging/lib/me/me.dart's curlKeep / curlKept.
import {
  accountKeyOf,
  addressOf,
  b64,
  checksummed,
  curlKeyOf,
  hex,
  identityScalarOf,
  netOpen,
  netSeal,
  openPasswordBackup,
  openSeedBackup,
  passwordAuth,
  passwordKey,
  randomIdentity,
  seedOf,
  signAccount,
  tidyHandle,
  unb64,
  unhex,
  utf8,
  type Kdf,
} from './crypto.ts';
import { Hub, HUB_URL } from './relay.ts';
import { type Session } from './keeper.ts';

/** The account needs an SMS code to hand its backup over (a verified number is on it). */
export class NeedsCode extends Error {
  constructor() {
    super('This account has a verified phone number. Enter the code it was sent.');
  }
}

export interface CaptureEntry {
  cookies: Record<string, string>;
  at: number;
  from: string;
}

const CURL_VERSION = 1;
const DEVICE = 'Chrome extension';

export class GhostAccount {
  private constructor(
    readonly address: string,
    readonly username: string,
    private readonly identity: string, // P-256 identity private key, hex
    private readonly curlKey: string, // seal key, hex
    private readonly hubUrl: string,
  ) {}

  get session(): Omit<Session, 'stay'> {
    return { v: 1, hub: this.hubUrl, address: this.address, username: this.username, identity: this.identity, curlKey: this.curlKey };
  }

  /** The account a saved session is for (no network). */
  static fromSession(s: Session): GhostAccount {
    return new GhostAccount(s.address, s.username, s.identity, s.curlKey, s.hub);
  }

  /** In with the recovery words (account.dart signInWithWords): connect as the seed identity, fetch and open the
   *  seed-sealed backup. */
  static async signInWithWords(words: string[], hubUrl: string = HUB_URL): Promise<GhostAccount> {
    const seed = await seedOf(words);
    const accountKey = accountKeyOf(seed);
    const address = addressOf(accountKey);
    const hub = await Hub.connect(identityScalarOf(seed), DEVICE, hubUrl);
    try {
      const body = JSON.stringify({ op: 'seed', a: address, by: hub.id, at: Date.now() });
      const sig = hex(signAccount(accountKey, utf8(body)));
      const r = await hub.ask('acct-seed', { body, sig });
      if (r.none === true || typeof r.blob !== 'string') {
        throw new Error('No backup is kept for these words. Sign in on the Uplink app first, then sign in here.');
      }
      const backup = await openSeedBackup(seed, address, r.blob);
      if (!backup) throw new Error('The backup for these words could not be opened.');
      return new GhostAccount(address, backup.username, backup.identity, hex(curlKeyOf(seed)), hubUrl);
    } finally {
      hub.close();
    }
  }

  /** In with a username + password (account.dart signInWithPassword): connect under a throwaway identity, stretch the
   *  password with the relay's settings, fetch and open the password-sealed backup. */
  static async signInWithPassword(username: string, password: string, opts: { number?: string; code?: string; identity?: Uint8Array } = {}, hubUrl: string = HUB_URL): Promise<GhostAccount> {
    const name = tidyHandle(username);
    // A texted code is the relay's for the identity that asked for it (relay/lib/handles.dart checkCode): the same one
    // signs in with it ([textCode]).
    const hub = await Hub.connect(opts.identity ?? randomIdentity(), DEVICE, hubUrl);
    try {
      const found = await hub.ask('acct-find', { name });
      if (found.none === true) throw new Error('No account has that username.');
      if (found.phone === true && !opts.code) throw new NeedsCode();
      const kdf = found.kdf as Kdf | undefined;
      if (!kdf || typeof kdf.m !== 'number' || typeof kdf.t !== 'number' || typeof kdf.p !== 'number' || typeof kdf.s !== 'string') {
        throw new Error('That account could not be read.');
      }
      const pwKey = passwordKey(password, unb64(kdf.s), kdf.m, kdf.t, kdf.p);
      const got = await hub.ask('acct-get', { name, number: opts.number, code: opts.code, auth: hex(passwordAuth(pwKey)) });
      if (got.phone === true) throw new NeedsCode();
      if (typeof got.blob !== 'string' || typeof got.a !== 'string') throw new Error('That account could not be read.');
      const address = checksummed(got.a);
      const backup = await openPasswordBackup(got.blob, pwKey, address);
      if (!backup) throw new Error('That password isn’t right.');
      const seed = await seedOf(backup.words);
      return new GhostAccount(address, backup.username || name, backup.identity, hex(curlKeyOf(seed)), hubUrl);
    } finally {
      hub.close();
    }
  }

  /** Texts a code to the number verified on [username]'s account (account.dart textCode); [number] has to be it. Asked
   *  under [identity], which [signInWithPassword] then signs in with: the relay keeps a code for whoever asked. */
  static async textCode(username: string, number: string, identity: Uint8Array, hubUrl: string = HUB_URL): Promise<void> {
    const hub = await Hub.connect(identity, DEVICE, hubUrl);
    try {
      await hub.ask('acct-text', { name: tidyHandle(username), number });
    } finally {
      hub.close();
    }
  }

  /** Reads the account's synced cURL entries off the relay (opened); {} when none or unreadable. */
  private async read(hub: Hub): Promise<Record<string, CaptureEntry>> {
    const obj = await this.readWhole(hub);
    return obj.v === CURL_VERSION && obj.entries && typeof obj.entries === 'object' ? (obj.entries as Record<string, CaptureEntry>) : {};
  }

  /**
   * The account's whole blob, opened; {} when none or unreadable. The app keeps more in it than the cURL entries (the
   * synced plugin list under `plugins`, messaging/lib/plugins/plugin_sync.dart, GMFB-9), so a write keeps the rest.
   */
  private async readWhole(hub: Hub): Promise<Record<string, unknown>> {
    const kept = await hub.ask('curl-kept');
    if (typeof kept.blob !== 'string' || !kept.blob) return {};
    const clear = await netOpen(unhex(this.curlKey), unb64(kept.blob));
    if (!clear) return {};
    try {
      const obj = JSON.parse(new TextDecoder().decode(clear));
      return obj && typeof obj === 'object' ? (obj as Record<string, unknown>) : {};
    } catch {
      return {};
    }
  }

  /** Keeps `entries` as the blob's cURL entries, whatever else the blob holds left as it was. */
  private async write(hub: Hub, whole: Record<string, unknown>, entries: Record<string, CaptureEntry>): Promise<void> {
    const sealed = await netSeal(unhex(this.curlKey), utf8(JSON.stringify({ ...whole, v: CURL_VERSION, entries })));
    await hub.ask('curl-keep', { blob: b64(sealed) });
  }

  /**
   * Merges `entries` (serviceId -> capture) into the account's synced blob and keeps it, sealed, on the relay. Reads
   * first so another device's entries aren't lost (one blob per account, last writer wins). Returns the full set now
   * kept. Connects on its own hub connection as the account's identity, so the blob lands in the same slot the app
   * reads.
   */
  async sync(entries: Record<string, CaptureEntry>): Promise<Record<string, CaptureEntry>> {
    const hub = await Hub.connect(unhex(this.identity), DEVICE, this.hubUrl);
    try {
      const whole = await this.readWhole(hub);
      const had = whole.v === CURL_VERSION && whole.entries && typeof whole.entries === 'object' ? (whole.entries as Record<string, CaptureEntry>) : {};
      const all = { ...had, ...entries };
      await this.write(hub, whole, all);
      return all;
    } finally {
      hub.close();
    }
  }

  /** The account's synced entries, for showing what is kept (no write). */
  async entries(): Promise<Record<string, CaptureEntry>> {
    const hub = await Hub.connect(unhex(this.identity), DEVICE, this.hubUrl);
    try {
      return await this.read(hub);
    } finally {
      hub.close();
    }
  }

  /** Removes one service's entry from the synced blob (does not sign the service out on other devices on its own). */
  async forget(serviceId: string): Promise<Record<string, CaptureEntry>> {
    const hub = await Hub.connect(unhex(this.identity), DEVICE, this.hubUrl);
    try {
      const whole = await this.readWhole(hub);
      const all = whole.v === CURL_VERSION && whole.entries && typeof whole.entries === 'object' ? { ...(whole.entries as Record<string, CaptureEntry>) } : {};
      delete all[serviceId];
      await this.write(hub, whole, all);
      return all;
    } finally {
      hub.close();
    }
  }
}
