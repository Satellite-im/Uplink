// The Telegram app id and hash a release is built with (lib/inbox/telegram.dart), as `--dart-define`s, read from
// ~/.config/ghostmessaging/telegram.env (two lines, made once from my.telegram.org › API development tools):
//
//   TELEGRAM_API_ID=1234567
//   TELEGRAM_API_HASH=0123456789abcdef0123456789abcdef
//
// They are Matt's, registered to his number, and never in the repository (the source is published). Without the
// file a release still builds, with Telegram shown as not in this build. Values are never printed.
import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

export const telegramEnv = join(homedir(), '.config/ghostmessaging/telegram.env');

// KLIPY's app key (lib/plugins/embeds.dart: a link to one of KLIPY's GIF pages is asked of KLIPY's API by it), from
// ~/.config/ghostmessaging/klipy.env, one line `KLIPY_APP_KEY=…`, made once at partner.klipy.com › API Keys. Matt's,
// never in the repository; without the file a release builds and those links have no preview. Never printed.
export const klipyEnv = join(homedir(), '.config/ghostmessaging/klipy.env');
function klipyDefine() {
  if (!existsSync(klipyEnv)) return [];
  const m = readFileSync(klipyEnv, 'utf8').match(/^\s*KLIPY_APP_KEY\s*=\s*([A-Za-z0-9_-]{8,200})\s*$/m);
  if (!m) throw new Error(`${klipyEnv} needs one line: KLIPY_APP_KEY=<the key>.`);
  return [`--dart-define=KLIPY_APP_KEY=${m[1]}`];
}

/** The `--dart-define`s, and a line saying which (without the values). */
export function telegramDefines() {
  const klipy = klipyDefine();
  const andKlipy = klipy.length ? '; KLIPY previews on' : '; no KLIPY key';
  if (!existsSync(telegramEnv)) return { args: klipy, said: `  (no ${telegramEnv}: Telegram is off in this build${andKlipy})` };
  const kept = {};
  for (const line of readFileSync(telegramEnv, 'utf8').split('\n')) {
    const m = line.match(/^\s*(TELEGRAM_API_ID|TELEGRAM_API_HASH)\s*=\s*(\S+)\s*$/);
    if (m) kept[m[1]] = m[2];
  }
  if (!/^[0-9]{3,12}$/.test(kept.TELEGRAM_API_ID ?? '') || !/^[0-9a-f]{32}$/.test(kept.TELEGRAM_API_HASH ?? '')) {
    throw new Error(`${telegramEnv} needs TELEGRAM_API_ID (digits) and TELEGRAM_API_HASH (32 hex characters), one a line.`);
  }
  return {
    args: [`--dart-define=TELEGRAM_API_ID=${kept.TELEGRAM_API_ID}`, `--dart-define=TELEGRAM_API_HASH=${kept.TELEGRAM_API_HASH}`, ...klipy],
    said: `  Telegram: built with the app id in ~/.config/ghostmessaging/telegram.env${andKlipy}`,
  };
}
