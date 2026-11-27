#!/usr/bin/env node
/**
 * Uplink in a browser, tried end to end as two people would use it (Matt: "the full web client"): a relay
 * on this machine serving the built app, and real browser engines driving the page itself.
 *
 *   node tool/build-web.mjs                 first: build/web
 *   node tool/web/e2e.mjs                   Chromium, then WebKit
 *   node tool/web/e2e.mjs --engine webkit   one of them
 *   node tool/web/e2e.mjs --web <folder> --shots <folder> --headed
 *                                           every build has calls and Files spaces (GMFB-30), and so the steps
 *                                           marked (calls) and (files) are run unless left out as the build was:
 *   node tool/build-web.mjs --no-calls --out build/web-nocalls && node tool/web/e2e.mjs --web build/web-nocalls --no-calls
 *                                           a build without calls, and the "no calls" checks in place of (calls)
 *   node tool/build-web.mjs --no-files --out build/web-nofiles && node tool/web/e2e.mjs --web build/web-nofiles --no-files
 *                                           a build without Files spaces, and no (files) steps
 *                                           (--calls and --files are still taken, and change nothing)
 *
 * WHAT IT DOES, in each engine
 *   1. Starts the relay (relay/bin/relay.dart, with Flutter's own Dart) on a free port of this machine, with a new
 *      empty folder for what it keeps and `--web` at the built app. Never the live relay, never a real account: the
 *      two people are made here, with names nobody has.
 *   2. Two browsers (two contexts: nothing shared) open the page and sign up, each with a username and a password.
 *   3. One adds the other by username; the other accepts; each writes to the other and sees what the other wrote.
 *  3c. (calls) One rings the other with a voice call from their conversation; the other answers; each hears the other:
 *      the sound arrives (WebRTC's own numbers: bytes and energy received on a connection that went through) and plays
 *      in an element of the page's (lib/voice/call_sound.dart); muted, the other hears silence; and the call is left.
 *      The microphone is Chromium's stand-in (its fake devices: a tone). Not in WebKit, which Playwright can't give a
 *      microphone (it knows no such permission, and getUserMedia waits for a prompt nobody can answer).
 *  3b. One shares feedback from the page (words alone: a page can't choose a picture yet), by the page's own fetch, to
 *      the hub's relay, beside the page or (--hub-port) at another address its policy names and whose relay lets the
 *      page read the answer (GHOST_APP_ORIGIN); this relay has no board to file it in, and the page shows it saying so.
 *   4. One page is loaded again: still signed in, the conversation still there.
 *   5. What that browser keeps, read as any script in the page could read it: every record sealed, the store's key
 *      not extractable, no recovery words, no password key, nothing of the conversation or the account in the clear.
 *   6. A second tab in the same browser is told the app is open in another tab; "Use it here" moves it over.
 *   7. One makes a circle and copies its invite link; the other joins by the link; each writes in its General space
 *      and reads what the other wrote there; its chat-and-voice space is its chat alone, with no way into a call.
 *      (calls: both join its call instead, hear each other, one turns the camera on and the other receives the picture,
 *      one mutes the other for themselves alone, and both leave.)
 *  7b. (files) The circle is made with a Files space too. Sam puts two files in it from his browser: one by the
 *      browser's own picker (a few megabytes of random bytes: many chunks, several pieces), one dropped on the page (a
 *      few words). Maya, in hers, sees both listed, opens the words and reads them in the page, and downloads the other
 *      to her browser's downloads: the bytes she gets are the bytes Sam put up. Every request went to the relay
 *      (FilesApi over the page's fetch), every chunk sealed and opened by the browser's own AES-GCM.
 *   8. Settings call it a browser, with an About of its own and none of what a browser has nothing to set for; and
 *      the Marketplace is on no key (Ctrl+5), in no quick switcher and in no list of shortcuts.
 *   9. One signs in on a third, new browser with the username and password: the same person, the friend still there,
 *      and the conversation with him from before, handed over by her other browser (GMFB-53),
 *      both browsers in the account's devices as browsers, after the password. How long signing in took is said.
 *  10. The page's own Argon2id (web/argon2id.js, in a worker) is held to test/vectors/argon2id.json.
 *  11. In a narrow window the page is laid out as a phone; wide again, as a computer.
 *  12. From the third browser the first is removed: left open and looked at again (no reload), it checks the account's
 *      signed removal, deletes everything of the account and opens at the welcome saying why, and what is written to
 *      the account after reaches the third and not it.
 *  13. The third signs out: everything deleted, the welcome saying so; the next person signs up there and finds nothing
 *      of the one before. Signed in once more (from an address naming a page after its #), the account lists that
 *      browser alone: the removed one and the one that signed out (by its own number) are gone.
 *  12b. Another browser of the account, removed while it was closed and the backup brought up to date after (as every
 *      phone and computer does once a day), opened again: it deletes everything of the account and opens at the welcome.
 *  13b. (Chromium) In a profile on disk, after signing out, the profile's IndexedDB files hold none of the account's
 *      records' bytes and not the deleted store's key; first searched with the page's Clear-Site-Data answer withheld,
 *      to show what the search finds without it.
 *  13c. Another site sending the browser to /app/clear-site-data (a picture, a navigation), or the address typed, clears
 *      nothing of what the app keeps; the page's own asking does.
 *  14. Every answer from the app's address carries the headers in tool/web/headers.json, the page's own policy among
 *      them with frame-ancestors 'none'.
 *  15. Nothing was asked of any address but the relay's own, the pages logged no error, and the relay wrote nothing to
 *      stderr.
 *
 * The page is a canvas: what is on it is found through Flutter's accessibility tree (the fields' and buttons' names),
 * which the script switches on as a screen reader would, and everything is done with it on, messages written too.
 *
 * GHOST_E2E_LOOK, for finding the way when adding a step: names joined by > ("Settings>About"), pressed in turn once
 * the run is through, a picture and the page's words after each. "=Label=text" types into a field, "~Name" turns the
 * wheel over it, "@sam" goes to Sam's page and "@new" opens one in a browser of its own.
 *
 * NEEDS Playwright with its browsers. It is not one of the app's packages: the script looks for it in npm's npx cache
 * (`npx playwright install chromium webkit` puts it there), or where GHOST_PLAYWRIGHT names its index.mjs.
 * A tool, not part of `flutter test`. Exit code 0 when everything held.
 */
import { spawn, execFileSync } from 'node:child_process';
import { createDecipheriv } from 'node:crypto';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const args = process.argv.slice(2);
// The value after --name on the command line, or [fallback].
const option = (name, fallback) => {
  const at = args.indexOf(`--${name}`);
  return at >= 0 && at + 1 < args.length ? args[at + 1] : fallback;
};
const webDir = resolve(option('web', join(root, 'build', 'web')));
const shots = option('shots', null);
const headed = args.includes('--headed');
const engines = option('engine', 'both') === 'both' ? ['chromium', 'webkit'] : [option('engine', 'chromium')];
// A build that names its hub (tool/build-web.mjs --hub ws://127.0.0.1:<port>/hub), as app.gogho.st's names gogho.st's:
// the hub is a relay of its own on that port, and the page comes from another, so the two are different addresses.
const hubPort = option('hub-port', null);
// The people's first steps only: signing up, a friend, a message each way.
const quick = args.includes('--quick');
// A build with calls (every one but tool/build-web.mjs --no-calls): the calls' steps, and none of the "no calls" checks.
const calls = !args.includes('--no-calls');
// A build with Files spaces (every one but tool/build-web.mjs --no-files): the files' steps.
const withFiles = !args.includes('--no-files');

if (!existsSync(join(webDir, 'index.html'))) {
  console.error(`e2e: no built app at ${webDir}: run node tool/build-web.mjs first.`);
  process.exit(2);
}

// --- what it needs -------------------------------------------------------------------------------------------------

// Playwright's index.mjs: where GHOST_PLAYWRIGHT says, else the first found in npm's npx cache; the run ends where
// there is none.
function findPlaywright() {
  if (process.env.GHOST_PLAYWRIGHT) return process.env.GHOST_PLAYWRIGHT;
  const cache = join(homedir(), '.npm', '_npx');
  if (existsSync(cache)) {
    for (const dir of readdirSync(cache)) {
      const at = join(cache, dir, 'node_modules', 'playwright', 'index.mjs');
      if (existsSync(at)) return at;
    }
  }
  console.error('e2e: Playwright was not found. `npx playwright install chromium webkit`, or set GHOST_PLAYWRIGHT to its index.mjs.');
  process.exit(2);
}

// The Dart the relay is run with: GHOST_DART, else the one inside the Flutter on the PATH, else whatever `dart` is.
function findDart() {
  if (process.env.GHOST_DART) return process.env.GHOST_DART;
  try {
    // Flutter's own Dart: the one the relay is tested with.
    const flutter = execFileSync('which', ['flutter'], { encoding: 'utf8' }).trim();
    const real = execFileSync('python3', ['-c', 'import os,sys;print(os.path.realpath(sys.argv[1]))', flutter], { encoding: 'utf8' }).trim();
    const dart = join(dirname(real), 'cache', 'dart-sdk', 'bin', 'dart');
    if (existsSync(dart)) return dart;
  } catch {}
  return 'dart';
}

const playwright = await import(pathToFileURL(findPlaywright()).href);
const dart = findDart();

// --- a relay of its own ----------------------------------------------------------------------------------------------

// Starts a relay on this machine with an empty folder of its own, and waits for it to say which port it listens on
// (0 asks for any free one). With [web] it serves the built app too. Gives back the port, what it wrote to stderr,
// and a stop that ends it and deletes its folder.
async function startRelay({ port: asked = '0', web = true, env = {} } = {}) {
  const data = mkdtempSync(join(tmpdir(), 'ghost-web-e2e-'));
  const child = spawn(dart, ['run', 'bin/relay.dart', '--host', '127.0.0.1', '--port', String(asked), '--data', data, ...(web ? ['--web', webDir] : [])], {
    cwd: join(root, 'relay'),
    // Nothing of this computer's settings: the relay as anyone would first run it.
    env: { PATH: process.env.PATH, HOME: process.env.HOME, ...env },
  });
  const errors = [];
  child.stderr.on('data', (d) => errors.push(String(d)));
  const port = await new Promise((done, fail) => {
    child.stdout.on('data', (d) => {
      const m = /listening on ws:\/\/127\.0\.0\.1:(\d+)/.exec(String(d));
      if (m) done(Number(m[1]));
    });
    child.on('exit', (code) => fail(new Error(`the relay ended (${code}): ${errors.join('')}`)));
    setTimeout(() => fail(new Error(`the relay never said it was listening: ${errors.join('')}`)), 90000);
  });
  return {
    port,
    errors,
    async stop() {
      child.kill('SIGTERM');
      await new Promise((r) => child.once('exit', r));
      rmSync(data, { recursive: true, force: true });
    },
  };
}

// --- the page, as a person finds things on it ----------------------------------------------------------------------------

// Something a step looked for and did not find: its message is what the run reports.
class Problem extends Error {}

/// One person's page: what it logged, what it asked the network for, and how to find and press what is on it.
class Seat {
  constructor(name, page, origin) {
    this.name = name;
    this.page = page;
    this.origin = origin;
    this.errors = [];
    this.outside = new Set();
    // The fonts the engine asks for a letter none of the app's own fonts has (tool/web/fallback-fonts.mjs): a build
    // without them answers 404 for each, which the browser logs as an error. Those are counted and said, not taken for
    // the page's own errors; every other 404 still is one.
    this.missingFonts = new Set();
    this.fontMisses = 0;
    this.notFound = [];
    // Feedback the relay has no board to file in (the run's relays have none): it answers 503, which the browser logs.
    // Counted as the fonts are, and weighed at the end the same way.
    this.feedbackRefused = 0;
    this.unavailable = [];
    page.on('response', (r) => {
      if (r.status() === 503 && new URL(r.url()).pathname === '/feedback') this.feedbackRefused++;
    });
    // A Files space's list asked for before this relay has the space (a circle's Files space, or the person's own My
    // files, the first time this page opens it): the relay answers 404, the app opens the space and reads it again
    // (FilesStore), and the browser logs the 404. Counted as the fonts are, and weighed at the end the same way.
    this.filesUnmade = 0;
    page.on('response', (r) => {
      if (r.status() === 404 && r.request().method() === 'GET' && /^\/files\/[0-9a-f]{32}$/.test(new URL(r.url()).pathname)) this.filesUnmade++;
    });
    page.on('response', (r) => {
      if (r.status() !== 404 || !new URL(r.url()).pathname.includes('/fallback-fonts/')) return;
      this.missingFonts.add(new URL(r.url()).pathname.split('/fallback-fonts/')[1]);
      this.fontMisses++;
    });
    // Everything the page said, kept to be written beside the pictures when a run fails (--shots).
    this.said = [];
    page.on('console', (m) => this.said.push(`${m.type()}: ${m.text().slice(0, 2000)}`));
    page.on('pageerror', (e) => this.said.push(`uncaught: ${String(e.message || e)} ${String(e.stack || '')}`));
    page.on('console', (m) => {
      if (m.type() !== 'error' || /GL Driver Message|WebGL|GPU stall/.test(m.text())) return;
      // Weighed at the end against the fonts missed: the two arrive in either order.
      if (/the server responded with a status of 404/.test(m.text())) return this.notFound.push(m.text().slice(0, 600));
      if (/the server responded with a status of 503/.test(m.text())) return this.unavailable.push(m.text().slice(0, 600));
      this.errors.push(m.text().slice(0, 600));
    });
    page.on('pageerror', (e) => this.errors.push(`uncaught: ${String(e.message || e)} ${String(e.stack || '').slice(0, 1200)}`));
    page.on('request', (r) => {
      const u = new URL(r.url());
      // Where the build names a hub elsewhere (--hub-port), what the page sends beside it over plain HTTP too: feedback
      // (tool/lib/web_site.mjs sentBeside; a report goes nowhere from a page made for a relay not Uplink's).
      if (hubPort && u.host === `127.0.0.1:${hubPort}` && (u.pathname === '/feedback' || u.pathname.startsWith('/files/'))) return;
      if (u.origin !== origin && !['data:', 'blob:', 'about:'].includes(u.protocol)) this.outside.add(`${u.origin}${u.pathname}`);
    });
    page.on('websocket', (w) => {
      const u = new URL(w.url());
      // The page's own address, or the hub its build names (--hub-port): nothing else.
      if (u.host !== new URL(origin).host && u.host !== `127.0.0.1:${hubPort}`) this.outside.add(`${u.protocol}//${u.host}`);
    });
    // What the relay told the browser with the page and with the worker, as it said it.
    this.headers = {};
    page.on('response', (r) => {
      const u = new URL(r.url());
      if (u.origin === origin && (u.pathname === '/app/' || u.pathname === '/app/argon2id.js')) this.headers[u.pathname] = r.headers();
    });
  }

  static async open(context, name, origin, { at = '' } = {}) {
    const seat = new Seat(name, await context.newPage(), origin);
    await seat.load({ at });
    return seat;
  }

  /// The page, loaded; [at] is what follows /app/ in the address (a # and anything a link might say).
  async load({ at = '' } = {}) {
    await this.page.goto(`${this.origin}/app/${at}`);
    await this.ready();
  }

  /// The bytes of the records that hold the account (`identity`, `state`, `secret:account_mine`), as hex: what the search
  /// of a profile's files looks for after they are deleted ([leftovers]).
  async recordBytes() {
    return this.page.evaluate(async () => {
      const db = await new Promise((done, fail) => {
        const r = indexedDB.open('ghost-messaging');
        r.onsuccess = () => done(r.result);
        r.onerror = () => fail(r.error);
      });
      const get = (name) => new Promise((done) => {
        const q = db.transaction('kept').objectStore('kept').get(name);
        q.onsuccess = () => done(q.result);
      });
      const hex = (b) => [...b].map((x) => x.toString(16).padStart(2, '0')).join('');
      const out = {};
      for (const name of ['identity', 'state', 'secret:account_mine']) {
        const v = await get(name);
        if (v instanceof Uint8Array) out[name] = hex(v);
      }
      db.close();
      return out;
    });
  }

  /// Everything the page keeps, read as any script running in the page could read it: each record's kind, and for one
  /// that is text, the text. (What a script could open with the store's key is lib/web/store.dart's to say; this is
  /// what anyone reading the browser's store gets without it.)
  async kept() {
    return this.page.evaluate(async () => {
      const db = await new Promise((done, fail) => {
        const r = indexedDB.open('ghost-messaging');
        r.onsuccess = () => done(r.result);
        r.onerror = () => fail(r.error);
      });
      try {
        if (!db.objectStoreNames.contains('kept')) return {};
        const store = db.transaction('kept').objectStore('kept');
        const all = (q) => new Promise((done) => { q.onsuccess = () => done(q.result); });
        const keys = await all(store.getAllKeys());
        const values = await all(store.getAll());
        const out = {};
        keys.forEach((k, i) => {
          const v = values[i];
          out[k] = typeof v === 'string' ? { kind: 'text', text: v }
            : v instanceof Uint8Array ? { kind: 'sealed', latin1: new TextDecoder('latin1').decode(v) }
            : v instanceof CryptoKey ? { kind: 'key', extractable: v.extractable }
            : { kind: typeof v };
        });
        return out;
      } finally {
        db.close();
      }
    });
  }

  /// Flutter's view on the page and its accessibility tree switched on, as a screen reader switches it on.
  async ready() {
    await this.page.waitForSelector('flutter-view, flt-glass-pane', { state: 'attached', timeout: 60000 });
    await this.page.waitForSelector('flt-semantics-placeholder', { state: 'attached', timeout: 60000 });
    await this.page.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click());
    await this.page.waitForSelector('flt-semantics', { state: 'attached', timeout: 30000 });
  }

  /// Everything the page says, as text: what is on the screen, to look for words in. A piece of text is a node of the
  /// tree with its words in a span; a button's words are its own; a field or a picture has a label.
  async words() {
    return this.page.evaluate(() => {
      const own = (e) => [...e.childNodes].filter((n) => n.nodeType === 3 || (n.nodeType === 1 && n.tagName === 'SPAN')).map((n) => n.textContent).join('').trim();
      return [...document.querySelectorAll('flt-semantics, flt-semantics input, flt-semantics textarea')].map((e) => e.getAttribute('aria-label') || own(e)).filter(Boolean).join('\n');
    });
  }

  /// [like]: [text] is a pattern one of the page's lines must match, not words it holds.
  async sees(text, { within = 30000, like = false } = {}) {
    const until = Date.now() + within;
    const holds = (words) => (like ? words.split('\n').some((line) => new RegExp(text).test(line)) : words.includes(text));
    for (;;) {
      if (holds(await this.words())) return;
      if (Date.now() > until) throw new Problem(`${this.name} never saw "${text}". On the page: ${(await this.words()).replace(/\n/g, ' | ').slice(0, 900)}`);
      await this.page.waitForTimeout(150);
    }
  }

  /// Waits for [text] to be nowhere on the page.
  async gone(text, { within = 30000 } = {}) {
    const until = Date.now() + within;
    while ((await this.words()).includes(text)) {
      if (Date.now() > until) throw new Problem(`${this.name} still sees "${text}".`);
      await this.page.waitForTimeout(150);
    }
  }

  /// The middle of the thing called [name] (a button's words, or its label), to press there.
  /// [like]: [name] is a pattern the whole of its words must match ("^Lighthouse, .* options$"), not the words.
  async where(name, { role = null, last = false, like = false } = {}) {
    return this.page.evaluate(({ name, role, last, like }) => {
      const own = (e) => [...e.childNodes].filter((n) => n.nodeType === 3 || (n.nodeType === 1 && n.tagName === 'SPAN')).map((n) => n.textContent).join('').trim();
      const is = like ? (words) => new RegExp(name).test(words) : (words) => words === name;
      const all = [...document.querySelectorAll('flt-semantics')].filter((e) => {
        if (role && e.getAttribute('role') !== role) return false;
        if (is(e.getAttribute('aria-label') || '')) return true;
        const words = own(e);
        return is(words) || words.split('\n').some(is);
      });
      const e = last ? all[all.length - 1] : all[0];
      if (!e) return null;
      const r = e.getBoundingClientRect();
      return r.width > 0 && r.height > 0 ? { x: r.left + r.width / 2, y: r.top + r.height / 2, left: r.left, top: r.top } : null;
    }, { name, role, last, like });
  }

  /// Presses the thing called [name] with the mouse, waiting for it to be there; [role], [last] and [like] as in
  /// [where].
  async press(name, { within = 30000, role = null, last = false, like = false } = {}) {
    const until = Date.now() + within;
    for (;;) {
      const at = await this.where(name, { role, last, like });
      // Pressed only where it has come to rest: a menu or a page still sliding into place moves it from under the
      // pointer, and the press lands on whatever was there.
      await this.page.waitForTimeout(120);
      const still = at && (await this.where(name, { role, last, like }));
      if (at && still && Math.abs(at.x - still.x) < 1 && Math.abs(at.y - still.y) < 1) {
        await this.page.mouse.click(still.x, still.y);
        return;
      }
      if (Date.now() > until) throw new Problem(`${this.name} found nothing called "${name}" to press. On the page: ${(await this.words()).replace(/\n/g, ' | ').slice(0, 900)}`);
      await this.page.waitForTimeout(150);
    }
  }

  /// Types into the field called [label], and makes sure it arrived (a field still sliding into place can miss the
  /// press that gives it the keyboard).
  async type(label, text, { within = 30000 } = {}) {
    // By its name (the words of the section it is in come before it there, a line each), or by the words it shows
    // while empty.
    const field = this.page.locator(['input', 'textarea'].flatMap((tag) => [`${tag}[aria-label="${label}"]`, `${tag}[aria-label$="\\a ${label}"]`, `${tag}[aria-description="${label}"]`]).join(', ')).first();
    await field.waitFor({ state: 'attached', timeout: within });
    for (let attempt = 0; ; attempt++) {
      await this.page.waitForTimeout(250);
      // Where it has come to rest: a page still sliding in moves it from under the pointer.
      let box = await field.boundingBox();
      for (let i = 0; i < 20; i++) {
        await this.page.waitForTimeout(100);
        const again = await field.boundingBox();
        const still = box && again && Math.abs(box.x - again.x) < 1 && Math.abs(box.y - again.y) < 1;
        box = again;
        if (still) break;
      }
      if (!box) throw new Problem(`${this.name}: the field "${label}" is not on the screen.`);
      // Toward its end: a toast stands in the middle of the window's foot, over a composer's start.
      await this.page.mouse.click(box.x + box.width * 0.85, box.y + box.height / 2);
      await this.page.waitForTimeout(200);
      await this.page.keyboard.type(text, { delay: 8 });
      // The field's element holds what was typed once the app has taken it and drawn the field again: looked at for a
      // while, not once.
      for (let i = 0; i < 12; i++) {
        await this.page.waitForTimeout(150);
        if ((await field.inputValue().catch(() => '')) === text) return;
      }
      if (attempt >= 3) {
        // Every field on the page, to say where the keys went instead.
        const fields = await this.page.evaluate(() => [...document.querySelectorAll('input, textarea')].map((e) => `${e.tagName.toLowerCase()} ${JSON.stringify(e.getAttribute('aria-label') ?? e.getAttribute('aria-description'))} = ${JSON.stringify(e.value)}${document.activeElement === e ? ' (has the keyboard)' : ''}`));
        throw new Problem(`${this.name}: what was typed into "${label}" did not arrive (it holds ${JSON.stringify(await field.inputValue().catch(() => null))}). The page's fields: ${fields.join('; ')}`);
      }
      // Whatever part of it did arrive is taken out before trying again.
      await this.page.keyboard.press('ControlOrMeta+a');
      await this.page.keyboard.press('Backspace');
    }
  }

  /// Turns the wheel over the thing called [over], a little at a time, until the thing called [target] is in view: what
  /// is under the fold of a list. At [over]'s top left corner, over its words rather than a button, so the wheel
  /// reaches the app as it does with no screen reader. (No field should hold the keyboard meanwhile: [clickAside].)
  async wheelTo(over, target) {
    const height = this.page.viewportSize().height;
    for (let turn = 0; turn < 16; turn++) {
      const there = await this.where(target);
      if (there && there.y > 10 && there.y < height - 10) return;
      // A list whose rows are still coming in (Settings' fade in one by one) is waited for.
      let at = await this.where(over);
      for (let wait = 0; !at && wait < 60; wait++) {
        await this.page.waitForTimeout(150);
        at = await this.where(over);
      }
      if (!at) throw new Problem(`${this.name} found nothing called "${over}" to scroll at.`);
      await this.page.mouse.move(at.left + 6, at.top + 6);
      await this.page.mouse.wheel(0, 300);
      await this.page.waitForTimeout(250);
    }
    throw new Problem(`${this.name} turned the wheel and never brought "${target}" into view.`);
  }

  /// Clicks beside the field that has the keyboard, on the words at the top left of [name], as one does to be done
  /// with a field: it lets go (Flutter's own, for a click outside a field). Before a scroll: a field holding the
  /// keyboard while the page scrolls can be made afresh, empty, by Flutter's engine with its tree for screen readers on
  /// (seen in Chromium: a circle's name typed, the page scrolled to its button, the name gone).
  async clickAside(name) {
    const at = await this.where(name);
    if (!at) throw new Problem(`${this.name} found nothing called "${name}" to click beside.`);
    await this.page.mouse.click(at.left + 6, at.top + 6);
    await this.page.waitForTimeout(300);
  }

  /// None of [texts] is on the page: what a browser has none of is not offered there.
  async lacks(...texts) {
    const words = await this.words();
    for (const text of texts) {
      if (words.split('\n').includes(text)) throw new Problem(`${this.name}'s page offers "${text}", which a browser has none of.`);
    }
  }

  /// The page's own Argon2id (argon2id.js beside it, started as the app starts it: a worker) asked for each of
  /// [vectors]: what it made of each, and how long each took.
  async argon2(vectors) {
    return this.page.evaluate(async (vectors) => {
      const unhex = (t) => Uint8Array.from((t.match(/../g) || []).map((h) => parseInt(h, 16)));
      const hex = (b) => [...b].map((x) => x.toString(16).padStart(2, '0')).join('');
      const out = [];
      for (const v of vectors) {
        const began = performance.now();
        const key = await new Promise((done, fail) => {
          const worker = new Worker('argon2id.js');
          worker.onmessage = (e) => {
            worker.terminate();
            e.data.key ? done(e.data.key) : fail(new Error(String(e.data.error)));
          };
          worker.onerror = (e) => {
            worker.terminate();
            fail(new Error(e.message || 'the worker could not be started'));
          };
          worker.postMessage({ password: new TextEncoder().encode(v.password), salt: unhex(v.salt), memoryKiB: v.m, passes: v.t, lanes: v.p, length: v.key.length / 2 });
        });
        out.push({ got: hex(key), ms: Math.round(performance.now() - began) });
      }
      return out;
    }, vectors);
  }

  /// Writes [text] in the open conversation's field (called [label], the words it shows while empty) and sends it
  /// with Enter, as someone with a screen reader would: the field pressed, the words typed, Enter. Its words gone from
  /// the field is the app taking them.
  async write(label, text) {
    await this.type(label, text);
    await this.page.keyboard.press('Enter');
    const field = this.page.locator(`textarea[aria-label="${label}"]`).first();
    const until = Date.now() + 15000;
    while ((await field.inputValue().catch(() => '')) !== '') {
      if (Date.now() > until) throw new Problem(`${this.name}: Enter did not send what was written in "${label}".`);
      await this.page.waitForTimeout(150);
    }
  }

  /// What this page receives in its calls now (calls), read as WebRTC itself says it: across every connection to another
  /// person that went through (each made with ICE servers; the one-device meter is made with none), the sound's bytes
  /// and energy received; and how many people's sounds are playing in an element of the page's, live and not muted.
  async hearing() {
    return this.page.evaluate(async () => {
      let bytes = 0, energy = 0, connected = 0;
      for (const pc of window.__ghostPcs ?? []) {
        if (!pc.__ghostToPeople || pc.connectionState !== 'connected') continue;
        connected++;
        for (const r of (await pc.getStats()).values()) {
          if (r.type === 'inbound-rtp' && r.kind === 'audio') {
            bytes += r.bytesReceived ?? 0;
            energy += r.totalAudioEnergy ?? 0;
          }
        }
      }
      const elements = [...document.querySelectorAll('#ghost-call-sound audio')];
      const playing = elements.filter((e) => !e.paused && !e.muted && e.srcObject?.getAudioTracks().some((t) => t.readyState === 'live')).length;
      return { bytes, energy, connected, elements: elements.length, playing };
    });
  }

  /// Hears someone (calls): over [over] ms, sound arrived and was not silence, and is playing in the page.
  async hears(who, { over = 2500, within = 45000 } = {}) {
    const until = Date.now() + within;
    let last;
    for (;;) {
      const a = await this.hearing();
      await this.page.waitForTimeout(over);
      const b = await this.hearing();
      last = { bytes: b.bytes - a.bytes, energy: b.energy - a.energy, connected: b.connected, playing: b.playing, elements: b.elements };
      if (last.connected > 0 && last.bytes > 1500 && last.energy > 1e-4 && last.playing > 0) return last;
      if (Date.now() > until) throw new Problem(`${this.name} never heard ${who}: over ${over} ms ${JSON.stringify(last)}`);
    }
  }

  /// Hears nothing from the call but silence (calls): sound still arrives (a muted microphone sends silence), with no
  /// energy in it.
  async hearsSilence(who, { over = 2500, within = 20000 } = {}) {
    const until = Date.now() + within;
    let last;
    for (;;) {
      const a = await this.hearing();
      await this.page.waitForTimeout(over);
      const b = await this.hearing();
      last = { bytes: b.bytes - a.bytes, energy: b.energy - a.energy, connected: b.connected };
      if (last.connected > 0 && last.energy < 1e-6) return last;
      if (Date.now() > until) throw new Problem(`${this.name} still hears ${who}, who is muted: over ${over} ms ${JSON.stringify(last)}`);
    }
  }

  /// A picture of the page into the --shots folder, where one was named.
  async shot(name) {
    if (!shots) return;
    mkdirSync(shots, { recursive: true });
    await this.page.screenshot({ path: join(shots, `${name}.png`) });
  }
}

// --- what a profile's files still hold ---------------------------------------------------------------------------------

/// What of [before] (records' hex, Seat.recordBytes) is still among the files under [dir]: each record's own bytes, and
/// the deleted store's key, found by trying every 32 bytes of every file as the AES-256-GCM key of the identity record.
function leftovers(dir, before) {
  if (!existsSync(dir)) return [];
  const files = [];
  const walk = (d) => {
    for (const e of readdirSync(d, { withFileTypes: true })) (e.isDirectory() ? walk(join(d, e.name)) : files.push(join(d, e.name)));
  };
  walk(dir);
  const found = [];
  for (const [name, hex] of Object.entries(before)) {
    const needle = Buffer.from(hex.slice(0, 64), 'hex');
    const where = files.filter((f) => readFileSync(f).includes(needle));
    if (where.length) found.push(`${name}'s bytes in ${where.map((f) => f.slice(dir.length + 1)).join(', ')}`);
  }
  const identity = before.identity && Buffer.from(before.identity, 'hex');
  if (identity && identity.length > 28) {
    const iv = identity.subarray(0, 12), body = identity.subarray(12, identity.length - 16), tag = identity.subarray(identity.length - 16);
    const aad = Buffer.from('ghost-messaging kept v1|identity');
    search: for (const f of files) {
      const bytes = readFileSync(f);
      for (let i = 0; i + 32 <= bytes.length; i++) {
        try {
          const d = createDecipheriv('aes-256-gcm', bytes.subarray(i, i + 32), iv);
          d.setAAD(aad);
          d.setAuthTag(tag);
          Buffer.concat([d.update(body), d.final()]);
          found.push(`the deleted store's key in ${f.slice(dir.length + 1)}, opening the identity`);
          break search;
        } catch {}
      }
    }
  }
  return found;
}

// --- the run ---------------------------------------------------------------------------------------------------------

// Every line the run has printed, kept as well as printed.
const said = [];
const say = (words) => {
  said.push(words);
  console.log(words);
};

// The whole run in one browser engine, against a relay started for it: true where every step held. The browser and
// the relay are closed whatever happens.
async function run(engine) {
  const relay = await startRelay();
  const origin = `http://127.0.0.1:${relay.port}`;
  // The hub elsewhere, where the build names one: the page's relay then serves the page alone, and the hub's lets the
  // page's address read what it answers the page's feedback (GHOST_APP_ORIGIN, as gogho.st's lets app.gogho.st).
  const hub = hubPort ? await startRelay({ port: hubPort, web: false, env: { GHOST_APP_ORIGIN: origin } }) : null;
  // With calls, the browser's stand-in microphone and camera, asked for no permission and played without a press of
  // their own (the press that joined is the page's; a browser with no window has no one to press).
  // Playwright's WebKit can't be given a microphone: it knows no such permission, and getUserMedia waits for a prompt
  // nobody can answer. There a build with calls is held to what it offers, and the calls themselves are Chromium's.
  const talking = calls && engine === 'chromium';
  const media = talking ? ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream', '--autoplay-policy=no-user-gesture-required'] : [];
  const browser = await playwright[engine].launch({ headless: !headed, args: media });
  const seats = [];
  let skipping = false;
  // One numbered step: done, timed and said; passed over once the run is skipping to its end.
  const step = async (words, what) => {
    if (skipping) return;
    const began = Date.now();
    await what();
    say(`  ok  ${words} (${((Date.now() - began) / 1000).toFixed(1)} s)`);
  };
  // Names nobody has: this run's own.
  const tag = Math.random().toString(36).slice(2, 8);
  const maya = { username: `maya_${tag}`, password: `maya's password ${tag}` };
  const sam = { username: `sam_${tag}`, password: `sam's password ${tag}` };
  try {
    say(`${engine}: the relay at ${origin}, the app from ${webDir}`);
    const size = { viewport: { width: 1180, height: 780 } };
    // What the page copies is kept for the script to read: a browser with no window gives a page no clipboard.
    const copies = () => {
      if (navigator.clipboard) navigator.clipboard.writeText = async (text) => { window.__ghostCopied = text; };
    };
    // Every WebRTC connection the page makes, kept where the script can ask it for its numbers (calls): marked where
    // it was made with ICE servers, as each to another person is (lib/voice/rtc.dart; the meter is made with none).
    const connections = () => {
      const Made = window.RTCPeerConnection;
      if (!Made) return;
      window.__ghostPcs = [];
      window.RTCPeerConnection = class extends Made {
        constructor(config, ...rest) {
          super(config, ...rest);
          this.__ghostToPeople = !!config?.iceServers?.length;
          window.__ghostPcs.push(this);
        }
      };
    };
    // Where an uncaught error was thrown from, said on the console (kept with the rest of what the page said: Seat.said).
    const where = () => {
      window.addEventListener('error', (e) => console.log(`[uncaught] ${e.message} at ${e.filename}:${e.lineno}:${e.colno} ${e.error?.stack ?? ''}`));
      window.addEventListener('unhandledrejection', (e) => console.log(`[unhandled] ${String(e.reason)} ${e.reason?.stack ?? ''}`));
    };
    const person = async () => {
      const context = await browser.newContext(size);
      await context.addInitScript(copies);
      await context.addInitScript(where);
      if (calls) {
        await context.addInitScript(connections);
        if (engine === 'chromium') await context.grantPermissions(['microphone', 'camera'], { origin });
      }
      return context;
    };
    const mayaBrowser = await person(), samBrowser = await person();
    let m, s;
    let signIn = 0, stretch = 0;
    await step('two browsers open the page', async () => {
      m = await Seat.open(mayaBrowser, 'Maya', origin);
      s = await Seat.open(samBrowser, 'Sam', origin);
      seats.push(m, s);
      await m.sees('Pick a username and a password.');
      await s.sees('Pick a username and a password.');
    });
    for (const [seat, who] of [[m, maya], [s, sam]]) {
      await step(`${seat.name} signs up as ${who.username}`, async () => {
        await seat.press('Continue', { role: 'button' }).catch(() => {});
        await seat.type('Username', who.username);
        await seat.type('Password', who.password);
        await seat.shot(`${engine}-${seat.name}-1-welcome`);
        await seat.press('Continue', { role: 'button' });
        await seat.gone('Pick a username and a password.', { within: 90000 });
        await seat.shot(`${engine}-${seat.name}-2-signed-up`);
      });
    }
    for (const seat of [m, s]) {
      await step(`${seat.name} puts the recovery words by for later, and is in the app`, async () => {
        await seat.sees('Your recovery words');
        await seat.press('Later', { role: 'button' });
        await seat.gone('Your recovery words');
        await seat.page.waitForTimeout(1500);
        await seat.shot(`${engine}-${seat.name}-3-app`);
      });
    }
    await step(`Maya adds @${sam.username} by username`, async () => {
      await m.press('Contacts', { role: 'button' });
      await m.press('Add a friend');
      await m.type('Search by @username', sam.username);
      await m.sees('On Uplink');
      await m.press('Add', { role: 'button' });
      await m.sees('Friend request sent');
      await m.shot(`${engine}-Maya-4-asked`);
      await m.page.keyboard.press('Escape');
    });
    await step('Sam finds the request in Contacts and accepts', async () => {
      await s.press('Contacts', { role: 'button' });
      await s.sees('Friend request');
      await s.shot(`${engine}-Sam-4-request`);
      await s.press('Accept', { role: 'button' });
      await s.gone('Friend request');
      await s.page.waitForTimeout(1500);
      await s.shot(`${engine}-Sam-5-friends`);
    });
    const hello = `Hello Sam, from ${engine}`, answer = `And hello Maya, from ${engine}`;
    await step('Maya opens Sam from Contacts and writes to him', async () => {
      await m.press(`${sam.username}, Uplink`);
      await m.sees('Friend · encrypted');
      await m.write('Encrypted message', hello);
      await m.sees(hello);
      await m.shot(`${engine}-Maya-5-wrote`);
    });
    await step('Sam finds it in his list, opens it, and answers; Maya reads the answer', async () => {
      await s.press('Messages', { role: 'button' });
      await s.sees(hello, { within: 20000 });
      await s.shot(`${engine}-Sam-6-list`);
      // The conversation's row in the list: Maya's name, the first place it is written.
      await s.press(maya.username);
      await s.sees('Friend · encrypted');
      // No calls in a browser without them, and no microphone: neither is offered. Nor the Marketplace on the rail.
      await (calls ? s.lacks('Record a voice message', 'Marketplace') : s.lacks('Voice call', 'Video call', 'Record a voice message', 'Marketplace'));
      // With calls, a friend is rung from their conversation.
      if (calls) for (const offered of ['Voice call', 'Video call']) await s.sees(offered);
      await s.write('Encrypted message', answer);
      await s.sees(answer);
      await s.sees(hello);
      await m.sees(answer, { within: 20000 });
      await m.shot(`${engine}-Maya-7-answered`);
    });
    if (calls && !talking) say(`  (calls: not tried in ${engine}, which can't be given a microphone here; what a build with calls offers is checked all the same)`);
    if (talking) {
      await step('(calls) Sam rings Maya with a voice call; she answers; each hears the other, muted is silence, and both leave', async () => {
        await s.press('Voice call', { role: 'button' });
        await m.sees('Answer', { within: 30000 });
        await m.shot(`${engine}-Maya-7b-ringing`);
        await m.press('Answer');
        const heard = await m.hears('Sam');
        const heardBack = await s.hears('Maya');
        await m.shot(`${engine}-Maya-7c-in-call`);
        await s.shot(`${engine}-Sam-7c-in-call`);
        say(`      Maya hears Sam (${heard.bytes} bytes in ${2.5} s), Sam hears Maya (${heardBack.bytes} bytes)`);
        await m.press('Mute', { role: 'button' });
        await s.hearsSilence('Maya');
        await m.press('Unmute', { role: 'button' });
        await s.hears('Maya again');
        await m.press('^Leave( call)?$', { like: true });
        await s.press('^Leave( call)?$', { like: true });
        // Left: no connection, and nothing playing.
        for (const x of [m, s]) {
          const until = Date.now() + 20000;
          for (;;) {
            const h = await x.hearing();
            if (h.connected === 0 && h.elements === 0) break;
            if (Date.now() > until) throw new Problem(`${x.name} left the call and still has ${JSON.stringify(h)}`);
            await x.page.waitForTimeout(300);
          }
        }
      });
    }
    // Feedback goes from the page by its own fetch (lib/web/http.dart), to the hub's relay: beside the page, or at another
    // address (--hub-port), where the page's policy names it and the relay lets the page read the answer. This run's
    // relay has no board to file it in, and says so: the page showing those words is the answer having come back.
    await step('Sam shares feedback from the page, words alone, and reads the relay\'s answer', async () => {
      await s.press('Messages', { role: 'button' });
      await s.press('Share feedback');
      await s.sees('Not from a browser yet');
      await s.type('What happened', `From the browser e2e run, ${engine}`);
      await s.clickAside('Screenshots');
      await s.wheelTo('Screenshots', 'Send');
      await s.press('Send', { last: true });
      await s.sees('Feedback isn\'t set up on this server yet.', { within: 30000 });
      await s.shot(`${engine}-Sam-7-feedback`);
      await s.page.keyboard.press('Escape');
    });
    if (quick) {
      say('  (--quick: the rest is left out)');
      skipping = true;
    }
    await step('Maya loads the page again: still signed in, the conversation and both messages still there', async () => {
      await m.load();
      await m.sees(sam.username);
      await m.sees(answer);
      await m.press(sam.username);
      await m.sees(hello);
      await m.sees(answer);
      await m.shot(`${engine}-Maya-8-reloaded`);
    });
    await step('what Maya\'s browser keeps is all sealed, and holds neither her recovery words nor her password\'s key', async () => {
      const kept = await m.kept();
      const names = Object.keys(kept);
      for (const name of ['seal-key', 'identity', 'state', 'secret:account_mine']) {
        if (!names.includes(name)) throw new Problem(`the browser keeps no ${name}: ${names.join(', ')}`);
      }
      for (const gone of ['secret:account_words', 'secret:account_pwkey', 'secret:was_key']) {
        if (names.includes(gone)) throw new Problem(`the browser keeps ${gone}, which a browser must not keep.`);
      }
      if (kept['seal-key'].kind !== 'key' || kept['seal-key'].extractable !== false) throw new Problem(`the store's key is ${JSON.stringify(kept['seal-key'])}, not one that can't be read out.`);
      for (const [name, v] of Object.entries(kept)) {
        if (name !== 'seal-key' && v.kind !== 'sealed') throw new Problem(`${name} is kept as ${v.kind}, not sealed.`);
        // Nothing of the conversation, the friend or the account is there to be read without the key.
        for (const plain of [hello, answer, sam.username, 'acct_sealed', 'acct_address', 'circles']) {
          if ((v.latin1 ?? v.text ?? '').includes(plain)) throw new Problem(`${name} holds "${plain}" as it was written.`);
        }
      }
    });
    await step('a second tab of Maya\'s browser is told the app is open in another tab; "Use it here" moves it over', async () => {
      const second = await Seat.open(mayaBrowser, 'Maya (second tab)', origin);
      seats.push(second);
      await second.sees('Uplink is open in another tab.');
      await second.shot(`${engine}-Maya-9-second-tab`);
      // The first tab is still the app meanwhile.
      await m.sees(sam.username);
      await second.press('Use it here', { role: 'button' });
      await second.sees(sam.username, { within: 30000 });
      await second.sees(answer);
      // And the first tab, which gave way, now says what the second did.
      await m.ready();
      await m.sees('Uplink is open in another tab.', { within: 30000 });
      await m.shot(`${engine}-Maya-9-first-tab`);
      // From here Maya is in the tab that took over.
      m = second;
    });
    let link;
    await step('Sam makes a circle, Lighthouse, and copies its invite link', async () => {
      await s.press('New', { role: 'button' });
      await s.press('New circle');
      await s.type('Circle name', 'Lighthouse');
      await s.sees('Lighthouse');
      await s.clickAside('Colour');
      // A browser can choose no picture yet, and keeps no files: neither is offered.
      await s.lacks('Choose a picture');
      if (withFiles) {
        // (files) A Files space among its first spaces.
        await s.wheelTo('Icon', 'Add a space');
        await s.press('Add a space');
        await s.press('^Files(,|$)', { like: true });
        await s.sees('^Files(,.*)?$', { like: true });
      }
      await s.wheelTo('Icon', 'Make the circle');
      await s.press('Make the circle');
      await s.sees('Lighthouse made');
      await s.sees('Message General');
      await s.shot(`${engine}-Sam-10-circle`);
      await s.press('^Lighthouse, .* options$', { like: true });
      await s.press('Invite people');
      await s.sees('Whoever has the link is in the circle.');
      await s.lacks('Text an invite', 'Share link…');
      await s.press('Copy invite link');
      await s.sees('Invite link copied. Anyone with it can join Lighthouse.');
      link = await s.page.evaluate(() => window.__ghostCopied);
      if (!/^https:\/\/gogho\.st\/join\/#c\.[0-9a-f]{64}/.test(link || '')) throw new Problem(`what Sam copied is no circle's link: ${link}`);
    });
    const inSpace = `Maya, in the circle's General, from ${engine}`, back = `Sam, back in General, from ${engine}`;
    await step('Maya joins it by the link and writes in its General space; Sam, who has it open, reads it', async () => {
      await m.press('New', { role: 'button' });
      await m.press('Join a circle by link');
      await m.type('Join a circle', link);
      await m.press('Save');
      await m.sees('General, Text', { within: 30000 });
      await m.sees('Lounge, Chat & voice');
      await m.sees('^Lighthouse(, open)?$', { like: true });
      await m.press('General, Text');
      await m.sees('Message General');
      await m.write('Message General', inSpace);
      await m.sees(inSpace);
      await m.shot(`${engine}-Maya-11-space`);
      await s.sees(inSpace, { within: 20000 });
    });
    await step(calls ? 'Sam answers there, and Maya reads it' : 'Sam answers there, and Maya reads it; a voice space is its chat, with no way into a call', async () => {
      await s.write('Message General', back);
      await s.sees(back);
      await s.sees(inSpace);
      await m.sees(back, { within: 20000 });
      // The other space is chat and voice: in a browser without calls, its chat alone. With calls, a press on it in
      // the circle's list joins its call at once in a window this wide (GMFB-72, pressCircleSpace), as on a computer:
      // no Join voice to press, and Leave there from the start.
      await s.press('Lounge, Chat & voice');
      await s.sees('Message Lounge');
      if (calls) {
        await s.sees('^Leave( call)?$', { like: true });
        await s.lacks('Join voice');
      } else {
        await s.lacks('Join', 'Join voice', 'Start the call');
      }
      await s.shot(`${engine}-Sam-12-voice-space`);
      // Where the engine can't be given a microphone the call never comes up: Leave stops the join where it is.
      if (calls && !talking) await s.press('^Leave( call)?$', { like: true });
    });
    if (talking) {
      await step('(calls) both join Lounge\'s call and hear each other; Maya\'s camera reaches Sam; Sam mutes her for himself alone; both leave', async () => {
        // Sam is in it already, from his press on it (above); Maya's press on it joins her as well. Its row says who
        // is talking once his call is up ("Lounge, Chat & voice, 1 talking"), and may not yet.
        await m.press('^Lounge, Chat & voice(, .*)?$', { like: true });
        await m.hears('Sam');
        await s.hears('Maya');
        await s.shot(`${engine}-Sam-12b-in-lounge`);
        // Maya's camera: Sam's connection receives her picture.
        await m.press('^(Turn on camera|Camera|Video|Start video)$', { like: true });
        const until = Date.now() + 30000;
        for (;;) {
          const frames = await s.page.evaluate(async () => {
            let n = 0;
            for (const pc of window.__ghostPcs ?? []) {
              if (!pc.__ghostToPeople || pc.connectionState !== 'connected') continue;
              for (const r of (await pc.getStats()).values()) if (r.type === 'inbound-rtp' && r.kind === 'video') n += r.framesDecoded ?? 0;
            }
            return n;
          });
          if (frames > 10) break;
          if (Date.now() > until) throw new Problem(`Sam's page decoded ${frames} frames of Maya's camera.`);
          await s.page.waitForTimeout(500);
        }
        await s.shot(`${engine}-Sam-12c-camera`);
        await m.shot(`${engine}-Maya-12c-camera`);
        // Sam mutes Maya for himself alone: her sound still arrives, and is not played (call_sound.dart).
        // Her row in the list under the picture: in a window this tall the picture (4:3) leaves it under the call's
        // buttons, so the window is made taller for the press, and put back after.
        await s.page.setViewportSize({ width: 1180, height: 1100 });
        // Her picture, since she has her camera on: a press on a video opens what can be done about its person (GMFB-70).
        await s.press(`${maya.username}, video`);
        await s.press(`Mute ${maya.username} for me`);
        const until2 = Date.now() + 15000;
        for (;;) {
          const h = await s.hearing();
          if (h.elements > 0 && h.playing === 0) break;
          if (Date.now() > until2) throw new Problem(`Sam muted Maya for himself and still plays her: ${JSON.stringify(h)}`);
          await s.page.waitForTimeout(300);
        }
        await m.hears('Sam, who muted her for himself alone');
        await s.press(`Mute ${maya.username} for me`);
        await s.hears('Maya again');
        await s.page.keyboard.press('Escape');
        await s.page.setViewportSize({ width: 1180, height: 780 });
        await m.press('^Leave( call)?$', { like: true });
        await s.press('^Leave( call)?$', { like: true });
      });
    }
    if (withFiles) {
      const picked = new Uint8Array(3 * 1024 * 1024 + 4321);
      for (let i = 0; i < picked.length; i += 65536) crypto.getRandomValues(picked.subarray(i, Math.min(picked.length, i + 65536)));
      const pickedName = `picked from ${engine}.bin`, droppedName = `dropped from ${engine}.txt`;
      const droppedWords = `Words dropped on the page in ${engine}, sealed in the browser.`;
      await step('(files) Sam puts a file in the circle\'s Files space by the picker and another by a drop; both go up', async () => {
        await s.press('^Files, Files', { like: true });
        await s.sees('Upload');
        const [chooser] = await Promise.all([s.page.waitForEvent('filechooser', { timeout: 30000 }), s.press('Upload')]);
        await chooser.setFiles({ name: pickedName, mimeType: 'application/octet-stream', buffer: Buffer.from(picked) });
        // A file dropped on the page: the browser's own drag and drop, with a File of the page's making.
        await s.page.evaluate(({ name, words }) => {
          const dt = new DataTransfer();
          dt.items.add(new File([words], name, { type: 'text/plain' }));
          for (const type of ['dragenter', 'dragover', 'drop']) document.dispatchEvent(new DragEvent(type, { dataTransfer: dt, bubbles: true, cancelable: true }));
        }, { name: droppedName, words: droppedWords });
        await s.sees(`^${pickedName}, `, { like: true, within: 120000 });
        await s.sees(`^${droppedName}, `, { like: true, within: 60000 });
        await s.gone('Going up', { within: 120000 });
        await s.shot(`${engine}-Sam-12f-files`);
      });
      await step('(files) Maya sees both, reads the dropped words in the page, and downloads the picked file: the same bytes', async () => {
        await m.press('^Files, Files', { like: true });
        await m.sees(`^${pickedName}, `, { like: true, within: 60000 });
        await m.sees(`^${droppedName}, `, { like: true });
        await m.press(`^${droppedName}, `, { like: true });
        await m.sees(droppedWords, { within: 60000 });
        await m.shot(`${engine}-Maya-12f-words`);
        // Back from the preview to the list (its own Back, the page's last).
        await m.press('Back', { last: true });
        await m.sees(`^${pickedName}, `, { like: true });
        await m.press(`More for ${pickedName}`);
        const [download] = await Promise.all([m.page.waitForEvent('download', { timeout: 120000 }), m.press('Download')]);
        if (download.suggestedFilename() !== pickedName) throw new Problem(`Maya's download is called ${download.suggestedFilename()}, not ${pickedName}.`);
        const got = readFileSync(await download.path());
        if (!Buffer.from(picked).equals(got)) throw new Problem(`Maya downloaded ${got.length} bytes, not the ${picked.length} Sam put up${got.length === picked.length ? ' (the same length, other bytes)' : ''}.`);
        await m.shot(`${engine}-Maya-12g-downloaded`);
      });
    }
    await step('Sam\'s Settings call this a browser, with an About of its own and none of what it has nothing to set for', async () => {
      await s.press('Settings', { role: 'button' });
      await s.sees('Appearance');
      await s.wheelTo('Emoji', 'About');
      await s.sees('Uplink in a browser');
      await (calls ? s.sees('Voice and video') : Promise.resolve());
      await (calls ? s.lacks('Sounds', 'Notifications', 'Updates', 'Your phone') : s.lacks('Voice and video', 'Sounds', 'Notifications', 'Updates', 'Your phone'));
      await s.press('About');
      await s.sees('Not in the browser yet');
      await s.sees('What this browser keeps');
      await s.shot(`${engine}-Sam-13-about`);
    });
    await step('the Marketplace is nowhere in a browser: not on its keys, in the quick switcher or in the shortcuts', async () => {
      await s.press('Messages', { role: 'button' });
      await s.page.mouse.click(800, 600);
      // Cmd or Ctrl and 5 opens the Marketplace on a phone or a computer (lib/keys.dart); in a page Ctrl is the key.
      await s.page.keyboard.press('Control+5');
      await s.page.waitForTimeout(1500);
      await s.lacks('Marketplace', 'Discover', 'Installed');
      // The quick switcher: the app's places, and no Marketplace among them.
      await s.page.keyboard.press('Control+k');
      await s.sees('Keyboard shortcuts', { within: 10000 });
      await s.sees('Archive');
      await s.lacks('Marketplace');
      await s.shot(`${engine}-Sam-14-switcher`);
      await s.page.keyboard.press('Escape');
      await s.page.waitForTimeout(500);
      await s.press('Settings', { role: 'button' });
      await s.wheelTo('Emoji', 'Keyboard shortcuts');
      await s.press('Keyboard shortcuts');
      await s.sees('Start something new');
      await (calls ? s.lacks('Marketplace') : s.lacks('Marketplace', 'Push to talk', 'Mute or unmute'));
      await s.shot(`${engine}-Sam-15-shortcuts`);
    });
    await step('Maya brings her backup up to date from her browser, with her password: what a browser keeps can\'t do it by itself', async () => {
      await m.press('Settings', { role: 'button' });
      await m.wheelTo('Change password', 'Update your backup');
      await m.press('Update your backup');
      await m.sees('Your password first');
      await m.type('Password', maya.password);
      await m.press('Update my backup', { role: 'button' });
      await m.sees('Backup up to date', { within: 60000 });
      await m.shot(`${engine}-Maya-13-backup`);
      await m.press('Messages', { role: 'button' });
    });
    let elsewhere;
    await step('Maya signs in on another browser with her username and password: the same person, her friend there', async () => {
      elsewhere = await Seat.open(await person(), 'Maya (another browser)', origin);
      seats.push(elsewhere);
      await elsewhere.sees('Already have an account?');
      await elsewhere.press('Sign in', { role: 'button', last: true });
      await elsewhere.sees('How to sign in');
      await elsewhere.type('Username', maya.username);
      await elsewhere.type('Password', maya.password);
      await elsewhere.shot(`${engine}-Maya-14-sign-in`);
      const began = Date.now();
      // The app starts again as her: the page loads itself again.
      const loaded = elsewhere.page.waitForEvent('load', { timeout: 120000 });
      await elsewhere.press('Sign in', { role: 'button', last: true });
      await loaded;
      await elsewhere.ready();
      await elsewhere.sees('Messages', { within: 60000 });
      signIn = Date.now() - began;
      await elsewhere.press('Contacts', { role: 'button' });
      await elsewhere.sees(`${sam.username}, Uplink`, { within: 30000 });
      await elsewhere.shot(`${engine}-Maya-15-signed-in`);
      // Her conversation with Sam, said before this browser existed: her other browser, still open, hands it over
      // (GMFB-53: "none of my messages appear in the sidebar"; Friends.historyAsk). In the list, and opened, both ways.
      await elsewhere.press('Messages', { role: 'button' });
      await elsewhere.press(sam.username, { within: 60000 });
      await elsewhere.sees(hello, { within: 30000 });
      await elsewhere.sees(answer);
      await elsewhere.shot(`${engine}-Maya-15b-history`);
      // Her two browsers, in her list of devices, each called what it is: after her password, which a browser keeps
      // nothing in place of.
      await elsewhere.press('Settings', { role: 'button' });
      await elsewhere.press('Signed in on these devices');
      await elsewhere.sees('Your password first');
      await elsewhere.type('Password', maya.password);
      await elsewhere.press('Show my devices', { role: 'button' });
      await elsewhere.sees('Browser · ', { within: 30000 });
      await elsewhere.sees('^A browser\\. Last seen today, signed in today$', { like: true });
      await elsewhere.lacks('Computer', 'Computer · browser', 'Mac', 'Linux');
      await elsewhere.shot(`${engine}-Maya-16-devices`);
    });
    await step('the page\'s own Argon2id gives every vector the app\'s other half is held to', async () => {
      const { vectors } = JSON.parse(readFileSync(join(root, 'test', 'vectors', 'argon2id.json'), 'utf8'));
      const got = await elsewhere.argon2(vectors);
      vectors.forEach((v, i) => {
        if (got[i].got !== v.key) throw new Problem(`a vector fails in the page (${v.m} KiB, ${v.t} passes, ${v.p} lanes, ${JSON.stringify(v.password)}): ${got[i].got}, not ${v.key}.`);
      });
      // The account's own settings (lib/account/account_crypto.dart): 64 MiB, 3 passes, 1 lane.
      const accounts = vectors.findIndex((v) => v.m === 65536 && v.t === 3 && v.p === 1);
      if (accounts < 0) throw new Problem('no vector has the account\'s own settings.');
      stretch = got[accounts].ms;
    });
    await step('in a narrow window it is laid out as a phone: a page over everything, Back to the list; wide again, side by side', async () => {
      // Wide, the devices page stands beside Settings' list, with the handle between them.
      await elsewhere.sees('Resize the list');
      await elsewhere.page.setViewportSize({ width: 390, height: 800 });
      // Narrow, the page that was open covers the list and the rail, as a phone's does, and nothing can be resized.
      await elsewhere.gone('Resize the list');
      await elsewhere.gone('Navigation');
      await elsewhere.sees('Signed in on these devices');
      await elsewhere.shot(`${engine}-Maya-17-narrow-page`);
      // Back (from the devices, then from Me) to Settings' list, the rail beside it again.
      for (let i = 0; i < 4 && !(await elsewhere.words()).includes('Navigation'); i++) {
        await elsewhere.press('Back');
        await elsewhere.page.waitForTimeout(900);
      }
      await elsewhere.sees('Navigation');
      await elsewhere.sees('Appearance');
      await elsewhere.shot(`${engine}-Maya-18-narrow-list`);
      await elsewhere.page.setViewportSize({ width: 1180, height: 780 });
      await elsewhere.sees('Resize the list');
    });
    const afterRemoval = `Sam, after one of Maya's browsers was removed, from ${engine}`;
    await step('Maya removes her first browser from another: left open, it notices when looked at again, deletes everything of her, and hears nothing more for her', async () => {
      await elsewhere.press('Settings', { role: 'button' });
      await elsewhere.press('Signed in on these devices');
      // The page asks for the password again: it held the opened account only while it was open.
      await elsewhere.sees('Your password first');
      await elsewhere.type('Password', maya.password);
      await elsewhere.press('Show my devices', { role: 'button' });
      await elsewhere.press('A browser. Last seen today, signed in today', { within: 30000 });
      await elsewhere.press('Remove', { role: 'button', last: true });
      await elsewhere.gone('A browser. Last seen today, signed in today', { within: 30000 });
      await elsewhere.sees('This device');
      await elsewhere.shot(`${engine}-Maya-19-removed-one`);
      // The removed browser was left open (a library's computer). Looked at again, it asks the relay, is handed the
      // account's signed removal, checks it, deletes everything and loads itself again, at the welcome saying why.
      let loads = 0;
      const counted = () => loads++;
      m.page.on('load', counted);
      for (const until = Date.now() + 90000; loads < 1;) {
        if (Date.now() > until) throw new Problem('the removed browser, left open and looked at again, never noticed it was removed.');
        await m.page.evaluate(() => document.dispatchEvent(new Event('visibilitychange'))).catch(() => {});
        for (let i = 0; i < 40 && loads < 1; i++) await m.page.waitForTimeout(250);
      }
      m.page.off('load', counted);
      await m.ready();
      await m.sees('This browser was removed from your account from another device', { within: 60000 });
      await m.sees('Pick a username and a password.');
      await m.shot(`${engine}-Maya-20-removed`);
      const kept = Object.keys(await m.kept());
      if (kept.includes('secret:account_mine')) throw new Problem(`the removed browser still keeps the account's key: ${kept.join(', ')}`);
      // Sam writes to Maya: her other browser hears it, the removed one nothing.
      await s.press('Messages', { role: 'button' });
      await s.press(maya.username);
      await s.write('Encrypted message', afterRemoval);
      await elsewhere.press('Messages', { role: 'button' });
      await elsewhere.sees(afterRemoval, { within: 20000 });
      await m.page.waitForTimeout(2000);
      if ((await m.words()).includes(afterRemoval) || (await m.words()).includes(hello)) throw new Problem('the removed browser still reads what is written to Maya.');
    });
    // Third review, A1: a browser removed while it was closed, after which another of the account's devices brought the
    // backup up to date (every phone and computer does once a day; a browser when asked), stayed the account when it was
    // opened again, its conversations there and new messages coming in.
    await step('a browser of Maya\'s removed while it was closed, then her backup brought up to date: opened again, it deletes everything of her', async () => {
      const shut = await person();
      const closed = await Seat.open(shut, 'Maya (closed)', origin);
      seats.push(closed);
      await closed.sees('Already have an account?');
      await closed.press('Sign in', { role: 'button', last: true });
      await closed.type('Username', maya.username);
      await closed.type('Password', maya.password);
      const signedIn = closed.page.waitForEvent('load', { timeout: 120000 });
      await closed.press('Sign in', { role: 'button', last: true });
      await signedIn;
      await closed.ready();
      await closed.sees('Messages', { within: 60000 });
      await closed.page.waitForTimeout(1500);
      // Its tab shut; what the browser keeps for it stays.
      await closed.page.close();
      await elsewhere.press('Settings', { role: 'button' });
      await elsewhere.press('Signed in on these devices');
      await elsewhere.sees('Your password first');
      await elsewhere.type('Password', maya.password);
      await elsewhere.press('Show my devices', { role: 'button' });
      await elsewhere.press('A browser. Last seen today, signed in today', { within: 30000 });
      await elsewhere.press('Remove', { role: 'button', last: true });
      await elsewhere.gone('A browser. Last seen today, signed in today', { within: 30000 });
      await elsewhere.press('Messages', { role: 'button' });
      await elsewhere.press('Settings', { role: 'button' });
      await elsewhere.wheelTo('Change password', 'Update your backup');
      await elsewhere.press('Update your backup');
      await elsewhere.type('Password', maya.password);
      await elsewhere.press('Update my backup', { role: 'button' });
      await elsewhere.sees('Backup up to date', { within: 60000 });
      // Opened again: it asks, deletes everything of her, and loads itself again at the welcome saying why. Two loads:
      // the one asked for, and the one after.
      const reopened = new Seat('Maya (closed, opened again)', await shut.newPage(), origin);
      seats.push(reopened);
      let loads = 0;
      reopened.page.on('load', () => loads++);
      await reopened.page.goto(`${origin}/app/`);
      for (const until = Date.now() + 90000; loads < 2;) {
        if (Date.now() > until) throw new Problem('the browser removed while closed, opened again after the backup was brought up to date, never noticed it was removed.');
        await reopened.page.waitForTimeout(200);
      }
      await reopened.ready();
      await reopened.sees('This browser was removed from your account from another device', { within: 60000 });
      await reopened.sees('Pick a username and a password.');
      const kept = Object.keys(await reopened.kept());
      if (kept.includes('secret:account_mine')) throw new Problem(`the browser removed while closed still keeps the account's key: ${kept.join(', ')}`);
      await reopened.shot(`${engine}-Maya-20b-removed-while-closed`);
    });
    await step('Maya signs out of her other browser: everything of her is deleted from it, and it opens at the welcome saying so', async () => {
      await elsewhere.press('Settings', { role: 'button' });
      await elsewhere.wheelTo('Change password', 'Sign out of this browser');
      await elsewhere.press('Sign out of this browser');
      await elsewhere.sees('Everything of your account is deleted from it');
      await elsewhere.shot(`${engine}-Maya-21-sign-out`);
      const loaded = elsewhere.page.waitForEvent('load', { timeout: 90000 });
      await elsewhere.press('Sign out and delete', { role: 'button', last: true });
      await loaded;
      await elsewhere.ready();
      await elsewhere.sees('You\'re signed out, and everything of your account was deleted from this browser.', { within: 60000 });
      await elsewhere.shot(`${engine}-Maya-22-signed-out`);
      const kept = Object.keys(await elsewhere.kept());
      if (kept.includes('secret:account_mine')) throw new Problem(`the browser signed out of still keeps the account's key: ${kept.join(', ')}`);
    });
    await step('the next person at that browser signs up, and finds nothing of Maya\'s', async () => {
      const eve = { username: `eve_${tag}`, password: `eve's password ${tag}` };
      await elsewhere.press('Continue', { role: 'button' }).catch(() => {});
      await elsewhere.type('Username', eve.username);
      await elsewhere.type('Password', eve.password);
      await elsewhere.press('Continue', { role: 'button' });
      await elsewhere.gone('Pick a username and a password.', { within: 90000 });
      await elsewhere.sees('Your recovery words');
      await elsewhere.press('Later', { role: 'button' });
      await elsewhere.gone('Your recovery words');
      await elsewhere.press('Messages', { role: 'button' });
      await elsewhere.page.waitForTimeout(2000);
      const words = await elsewhere.words();
      for (const theirs of [sam.username, hello, answer, afterRemoval, inSpace, 'Lighthouse']) {
        if (words.includes(theirs)) throw new Problem(`the next person at Maya's browser sees "${theirs}".`);
      }
      await elsewhere.shot(`${engine}-Eve-1-nothing-of-maya`);
    });
    await step('Maya signs in once more, from a link with a page after its #: her list has that browser alone', async () => {
      // An address that names a page of the app (once, the Marketplace) opens at the welcome, as any does.
      const again = await Seat.open(await person(), 'Maya (once more)', origin, { at: '#/settings/../marketplace' });
      seats.push(again);
      await again.sees('Already have an account?');
      await again.press('Sign in', { role: 'button', last: true });
      await again.sees('A private window is a new device each time');
      await again.type('Username', maya.username);
      await again.type('Password', maya.password);
      const loaded = again.page.waitForEvent('load', { timeout: 120000 });
      await again.press('Sign in', { role: 'button', last: true });
      await loaded;
      await again.ready();
      await again.sees('Messages', { within: 60000 });
      await again.press('Settings', { role: 'button' });
      await again.press('Signed in on these devices');
      await again.type('Password', maya.password);
      await again.press('Show my devices', { role: 'button' });
      await again.sees('This device', { within: 30000 });
      await again.page.waitForTimeout(1000);
      // The browser she removed, and the one she signed out of (which took itself off by its own number), are gone.
      if (/Last seen/.test(await again.words())) throw new Problem(`Maya's list still has other devices: ${(await again.words()).replace(/\n/g, ' | ').slice(0, 600)}`);
      await again.shot(`${engine}-Maya-23-alone`);
    });
    // Chromium kept a deleted store's bytes, its key among them, in the profile's files after signing out (the second
    // review). The page asks for `Clear-Site-Data: "storage"` as it wipes. Looked for in a profile on disk, twice: first
    // with that answer withheld, to show the search finds what is left, then as the app does it.
    if (engine === 'chromium') {
      await step('Chromium keeps nothing of a signed-out account among its profile\'s files', async () => {
        const found = {};
        for (const [label, withheld] of [['withheld', true], ['given', false]]) {
          const dir = mkdtempSync(join(tmpdir(), 'ghost-e2e-profile-'));
          const context = await playwright.chromium.launchPersistentContext(dir, { headless: !headed, viewport: { width: 1180, height: 780 } });
          try {
            if (withheld) await context.route('**/clear-site-data', (r) => r.fulfill({ status: 204, body: '' }));
            const seat = new Seat(`Wren (${label})`, context.pages()[0] ?? (await context.newPage()), origin);
            if (!withheld) seats.push(seat);
            await seat.load();
            await seat.sees('Pick a username and a password.');
            await seat.press('Continue', { role: 'button' }).catch(() => {});
            await seat.type('Username', `wren_${tag}${withheld ? 'w' : 'g'}`);
            await seat.type('Password', `wren's password ${tag}`);
            await seat.press('Continue', { role: 'button' });
            await seat.gone('Pick a username and a password.', { within: 90000 });
            await seat.sees('Your recovery words');
            await seat.press('Later', { role: 'button' });
            await seat.gone('Your recovery words');
            await seat.page.waitForTimeout(2000);
            const before = await seat.recordBytes();
            await seat.press('Settings', { role: 'button' });
            await seat.wheelTo('Change password', 'Sign out of this browser');
            await seat.press('Sign out of this browser');
            const loaded = seat.page.waitForEvent('load', { timeout: 90000 });
            await seat.press('Sign out and delete', { role: 'button', last: true });
            await loaded;
            await seat.ready();
            await seat.sees('You\'re signed out', { within: 60000 });
            await seat.page.waitForTimeout(2000);
            await context.close();
            found[label] = leftovers(join(dir, 'Default', 'IndexedDB'), before);
          } finally {
            await context.close().catch(() => {});
            rmSync(dir, { recursive: true, force: true });
          }
        }
        if (found.given.length) throw new Problem(`after signing out, the profile's files still hold: ${found.given.join('; ')}`);
        if (!found.withheld.length) say('  (the search found nothing left even with the clearing withheld: Chromium tidied it away first, so this run shows nothing either way)');
        else say(`  with the clearing withheld, the search found: ${found.withheld.join('; ')}; as the app does it, nothing`);
      });
    }
    // Third review, A2: the person sent to /app/clear-site-data from another site (a link in a message, a redirect, a
    // picture) cleared what the app keeps, in Chromium and in WebKit. The relay answers the page's own asking alone.
    await step('another site can\'t make the browser clear what the app keeps: only the page\'s own asking does', async () => {
      const context = await browser.newContext();
      try {
        const page = await context.newPage();
        await page.goto(`${origin}/app/version.json`);
        const make = () => new Promise((done, fail) => {
          const r = indexedDB.open('e2e-probe', 1);
          r.onupgradeneeded = () => r.result.createObjectStore('s');
          r.onsuccess = () => {
            const tx = r.result.transaction('s', 'readwrite');
            tx.objectStore('s').put('kept', 'k');
            tx.oncomplete = () => { r.result.close(); done(true); };
            tx.onerror = () => fail(tx.error);
          };
          r.onerror = () => fail(r.error);
        });
        const count = () => new Promise((done) => {
          const r = indexedDB.open('e2e-probe', 1);
          r.onupgradeneeded = () => r.result.createObjectStore('s');
          r.onsuccess = () => {
            const q = r.result.transaction('s').objectStore('s').count();
            q.onsuccess = () => { r.result.close(); done(q.result); };
          };
        });
        await page.evaluate(make);
        // From another site (localhost is another site than 127.0.0.1): a picture asked for, then the person sent there.
        const other = await context.newPage();
        await other.goto(`http://localhost:${relay.port}/app/version.json`);
        await other.evaluate((u) => new Promise((done) => { const i = new Image(); i.onload = i.onerror = () => done(); i.src = u; }), `${origin}/app/clear-site-data`);
        await other.evaluate((u) => { location.href = u; }, `${origin}/app/clear-site-data`);
        await other.waitForTimeout(2000);
        // The address typed into the browser's own bar: nothing either.
        await page.goto(`${origin}/app/clear-site-data`).catch(() => {});
        await page.goto(`${origin}/app/version.json`);
        if ((await page.evaluate(count)) !== 1) throw new Problem('a request that wasn\'t the page\'s own made the browser clear what the app keeps.');
        // The page's own asking, as it signs out: cleared.
        await page.evaluate(() => fetch('clear-site-data', { cache: 'no-store', credentials: 'same-origin' }));
        await page.waitForTimeout(1500);
        if ((await page.evaluate(count)) !== 0) throw new Problem('the page\'s own asking did not make the browser clear what the app keeps.');
      } finally {
        await context.close();
      }
    });
    await step('every answer from the app\'s address says what the app may do: the page\'s policy as a header, and the rest of the list', async () => {
      const list = JSON.parse(readFileSync(join(root, 'tool', 'web', 'headers.json'), 'utf8'));
      const page = readFileSync(join(webDir, 'index.html'), 'utf8');
      const meta = /<meta http-equiv="Content-Security-Policy" content="([^"]+)">/.exec(page)?.[1];
      for (const path of ['/app/', '/app/argon2id.js', '/app/nothing-here.js']) {
        const got = await fetch(`${origin}${path}`);
        for (const [name, value] of Object.entries(list.every)) {
          if (got.headers.get(name) !== value) throw new Problem(`${path} says ${name}: ${got.headers.get(name)}, not ${value}.`);
        }
        if (got.headers.get('content-security-policy') !== `${meta}; ${list.frameAncestors}`) throw new Problem(`${path}'s policy is ${got.headers.get('content-security-policy')}`);
      }
    });
    if (!quick) say(`  ${engine}: signing in took ${(signIn / 1000).toFixed(1)} s from the press to the app, signed in (the page loads again on the way); the password itself took ${stretch} ms of it, on a thread of its own.`);
    if (process.env.GHOST_E2E_LOOK) {
      let x = seats[seats.length - 1];
      for (const name of process.env.GHOST_E2E_LOOK.split('>')) {
        if (name === '@sam') {
          x = s;
          continue;
        } else if (name === '@new') {
          x = await Seat.open(await person(), 'Someone new', origin);
          seats.push(x);
        } else if (name.startsWith('~')) {
          const at = await x.where(name.slice(1));
          if (at) {
            await x.page.mouse.move(at.left + 6, at.top + 6);
            await x.page.mouse.wheel(0, 900);
          }
        } else if (name.startsWith('=')) {
          const [label, text] = name.slice(1).split('=');
          await x.type(label, text).catch((e) => say(`  look: ${e.message.slice(0, 200)}`));
        } else {
          await x.press(name).catch((e) => say(`  look: ${e.message.slice(0, 200)}`));
        }
        await x.page.waitForTimeout(1500);
        await x.shot(`look-${engine}-${name.replace(/[^a-z0-9]+/gi, '-')}`);
        say(`  look after "${name}": ${(await x.words()).replace(/\n/g, ' | ').slice(0, 3000)}`);
        if (x.errors.length) say(`  look: errors so far: ${x.errors.join(' || ')}`);
      }
    }
    const missing = new Set(seats.flatMap((x) => [...x.missingFonts]));
    if (missing.size) say(`  ${engine}: the engine asked for ${missing.size} fallback font${missing.size === 1 ? '' : 's'} this build hasn't got (${[...missing].map((p) => p.split('/')[0]).join(', ')}): letters outside the app's own fonts were drawn as boxes. node tool/web/fallback-fonts.mjs --fetch, then build again.`);
    const outside = new Set(seats.flatMap((x) => [...x.outside]));
    // A 404 logged that no missing fallback font accounts for is the page's own error.
    for (const x of seats) x.errors.push(...x.notFound.slice(x.fontMisses + x.filesUnmade).map((e) => `${e} (no missing fallback font or unmade Files space to account for it)`));
    for (const x of seats) x.errors.push(...x.unavailable.slice(x.feedbackRefused).map((e) => `${e} (no feedback the relay had no board for, to account for it)`));
    const errors = seats.flatMap((x) => x.errors.map((e) => `${x.name}: ${e}`));
    if (outside.size) throw new Problem(`something was asked of ${[...outside].join(', ')}`);
    if (errors.length) throw new Problem(`the page logged errors:\n    ${errors.join('\n    ')}`);
    if (relay.errors.length) throw new Problem(`the relay wrote to stderr: ${relay.errors.join('')}`);
    if (hub?.errors.length) throw new Problem(`the hub's relay wrote to stderr: ${hub.errors.join('')}`);
    return true;
  } catch (e) {
    say(`  FAILED in ${engine}: ${e instanceof Problem ? e.message : e.stack}`);
    for (const x of seats) {
      await x.shot(`${engine}-${x.name}-failed`).catch(() => {});
      if (shots) writeFileSync(join(shots, `${engine}-${x.name}-failed.txt`), x.said.join('\n'));
      if (x.errors.length) say(`    ${x.name}'s page logged: ${x.errors.slice(0, 6).join(' || ')}`);
    }
    return false;
  } finally {
    await browser.close();
    await relay.stop();
    await hub?.stop();
  }
}

let held = true;
for (const engine of engines) {
  held = (await run(engine)) && held;
}
process.exit(held ? 0 : 1);
