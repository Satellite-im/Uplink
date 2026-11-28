#!/usr/bin/env node
/**
 * Puts Uplink's relay on the box (Matt, 2026-11-14: "Deploy the relay"): relay/, which is the pairings'
 * relay at /relay/<channel> (a phone and the computer it is paired with) and the hub at /hub (where two people's
 * apps find each other: docs/network.md). One program, one service, listening on the box alone; the web server
 * that holds ghost-sms.com's certificate passes those two addresses to it (tool/deploy-site.mjs --caddy writes
 * that into ghost-sms.com's own block).
 *
 *   node tool/deploy-relay.mjs                    builds it for the box, installs it, (re)starts the service
 *   node tool/deploy-relay.mjs --keep-connection  the same, and leaves the login open for the next script
 *   node tool/deploy-relay.mjs --print            the script the box would run, and nothing sent
 *   node tool/deploy-relay.mjs --env <file>       the same, and puts <file> on the box as /etc/ghost-relay/env
 *
 * --env is how the relay's secrets reach the box (Matt, 2026-11-14, of the texting service's: "where can I give you
 * the codes to upload to the server"): never through a chat. They are written in a file on the Mac, one NAME=value
 * a line (docs/me.md says which: GHOST_TWILIO_SID and the rest), and this reads the file, checks each name is one
 * the relay knows and each value has the shape it should, and sends it down the same ssh session as the program,
 * on its input and not in the command, where the box's other users could read it. Only the names are ever printed.
 * The file on the box is the Mac's, whole: a value taken out of the Mac's file is gone from the box's.
 *
 * The first time, both in one login (the box counts them; the second rides the first's connection):
 *
 *   node tool/deploy-relay.mjs --keep-connection && node tool/deploy-site.mjs --caddy
 *
 * After that the first alone, whenever relay/ changes. A restart drops whoever is connected: the apps connect
 * again by themselves, and what the hub was holding for people who are away is lost (it is kept in memory; the
 * apps' other routes are what a sender falls back on).
 *
 * What it does on the box, in one ssh session, stopping before anything is changed if the build does not run
 * there or the port is someone else's: a user of its own with no shell and no home (ghost-relay); the program in
 * /opt/ghost-relay; what it keeps (the pairings' channels: a hash and a day each) in /var/lib/ghost-relay; a
 * systemd service that restarts it, may write nowhere else, and may use 300 MB and one processor at most.
 *
 * It reaches the box through tool/lib/box.mjs (its login in ~/.config/uplink/release.env), as tool/release.mjs does.
 */
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const RELAY = join(ROOT, 'relay');
const OUT = join(ROOT, 'build', 'relay');
const BIN = join(OUT, 'ghost-relay');
const DIR = '/opt/ghost-relay';
const DATA = '/var/lib/ghost-relay';
const UNIT = '/etc/systemd/system/ghost-relay.service';
// 8787, the relay's own default, is another service's on the box (found by the first deploy, which stopped there).
// tool/deploy-site.mjs's block names the same port: the two must agree.
const PORT = 18787;
const DOMAIN = 'gogho.st'; // ghost-sms.com before 2026-11-15; it passes the same two addresses on (tool/deploy-site.mjs).
const ENV = '/etc/ghost-relay/env';
const args = process.argv.slice(2);
const printOnly = args.includes('--print');
const fail = (message) => { console.error(`x ${message}`); process.exit(1); };

// What the relay reads from its environment (relay/lib/handles.dart `HandlesConfig.fromEnvironment`), and the
// shape of the ones that have one. A name that is not here is a slip of the hand, and is refused.
const KNOWN = {
  GHOST_PUBLIC_URL: /^https:\/\/[A-Za-z0-9.-]+$/,
  // The hosts the hub is reached at (relay/lib/hub.dart `names`): a sign-in is bound to the one the app dialled.
  GHOST_HUB_NAMES: /^[a-z0-9.-]+(:[0-9]{1,5})?(,[a-z0-9.-]+(:[0-9]{1,5})?)*$/,
  // What every connection may hold together, and when one is ended for it (relay/lib/ws_door.dart `WireBudget`).
  // What is held for people away, and what rooms keep, kept on the box's disk too (relay/lib/held_store.dart): 1 on,
  // anything else off. It changes what the relay keeps (relay/README.md, "What it keeps"): Matt's to switch on.
  GHOST_HUB_KEEP_HELD: /^[01]$/,
  GHOST_WIRE_MB: /^[0-9]{1,4}$/,
  GHOST_WIRE_EACH_MB: /^[0-9]{1,4}$/,
  GHOST_WIRE_STALL_S: /^[0-9]{1,3}$/,
  GHOST_WIRE_IN_STALL_S: /^[0-9]{1,3}$/,
  GHOST_DISCORD_ID: /^[0-9]{15,22}$/,
  GHOST_DISCORD_SECRET: null,
  GHOST_X_ID: null,
  GHOST_X_SECRET: null,
  GHOST_TELEGRAM_BOT: /^[A-Za-z0-9_]{5,32}$/,
  GHOST_TELEGRAM_TOKEN: /^[0-9]+:[A-Za-z0-9_-]+$/,
  GHOST_GITHUB_TOKEN: null,
  GHOST_TWILIO_SID: /^(AC|SK)[0-9a-fA-F]{32}$/,
  GHOST_TWILIO_TOKEN: /^[A-Za-z0-9]{32}$/,
  GHOST_TWILIO_VERIFY: /^VA[0-9a-fA-F]{32}$/,
  GHOST_TEXT_TO: /^\+[0-9]{1,6}(,\+[0-9]{1,6})*$/,
  GHOST_TEXTS_A_DAY: /^[0-9]{1,6}$/,
  // The admin page's sign-in (tool/admin-password.mjs; relay/lib/handles.dart HandlesConfig.adminUser): a username,
  // the password's salted hash, and the Uplink usernames that may sign in.
  GHOST_ADMIN_USER: /^[a-z0-9-]{3,40}$/,
  GHOST_ADMIN_HASH: /^[0-9a-f]{32}:[0-9a-f]{64}$/,
  GHOST_ADMIN_NAMES: /^[a-z0-9._]{3,20}(,[a-z0-9._]{3,20})*$/,
  // Files spaces' limits (relay/lib/files.dart `FilesConfig.fromEnvironment`, which lists the same names in
  // FilesConfig.names): bytes for the sizes, counts, days and hours for the rest. Each has a default where it is not
  // set; check the box's disk (`df -h /var/lib`) before raising GHOST_FILES_TOTAL. The files live under ${DATA}/files,
  // which ReadWritePaths below already covers, and are streamed to and from the disk, so MemoryMax stays as it is.
  // Every limit has a name since Matt, 2026-11-17: "Finish the missing pieces that went unfinished"; MAX_BODY is held
  // to 10 MiB by the relay, Caddy's request_body in tool/deploy-site.mjs.
  GHOST_FILES_MAX_FILE: /^[0-9]{1,13}$/,
  GHOST_FILES_SPACE_QUOTA: /^[0-9]{1,13}$/,
  GHOST_FILES_ROOMY_QUOTA: /^[0-9]{1,13}$/,
  GHOST_FILES_ROOMY_SPACES: /^[0-9a-f]{32}(,[0-9a-f]{32})*$/,
  GHOST_FILES_TOTAL: /^[0-9]{1,14}$/,
  GHOST_FILES_SPACES_PER_ID: /^[0-9]{1,5}$/,
  GHOST_FILES_IDLE_DAYS: /^[0-9]{1,4}$/,
  GHOST_FILES_WRITES_PER_MINUTE: /^[0-9]{1,6}$/,
  GHOST_FILES_MAX_BODY: /^[0-9]{1,9}$/,
  GHOST_FILES_MAX_OP: /^[0-9]{1,8}$/,
  GHOST_FILES_MAX_OPS: /^[0-9]{1,7}$/,
  GHOST_FILES_MAX_LOG_BYTES: /^[0-9]{1,11}$/,
  GHOST_FILES_MAX_BLOBS: /^[0-9]{1,7}$/,
  GHOST_FILES_MAX_SPACES: /^[0-9]{1,7}$/,
  GHOST_FILES_PART_HOURS: /^[0-9]{1,4}$/,
  GHOST_FILES_SPACES_PER_ADDRESS: /^[0-9]{1,5}$/,
  GHOST_FILES_PROMISED_PER_ADDRESS: /^[0-9]{1,13}$/,
  // Bounties in souls without the admin page (relay/lib/bounty.dart): the bounty key's public half, 33 bytes in hex.
  GHOST_BOUNTY_KEY: /^0[23][0-9a-fA-F]{64}$/,
  // The app in a browser at an address of its own (relay/lib/relay.dart appOriginFrom; gogho.st's is https://app.gogho.st):
  // its page may read the answers to a report and to feedback it sends the relay, and nothing else.
  GHOST_APP_ORIGIN: /^https:\/\/[a-z0-9.-]+(:[0-9]{1,5})?$/,
  // The app's Share feedback, filed in Notion (relay/lib/feedback.dart): the integration's secret and the board's data source.
  GHOST_NOTION_TOKEN: /^(ntn_|secret_)[A-Za-z0-9]{20,80}$/,
  GHOST_NOTION_FEEDBACK: /^[0-9a-fA-F]{8}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{12}$/,
  // The Marketplace's limits (relay/lib/market.dart `MarketConfig.fromEnvironment`, which lists the same names in
  // MarketConfig.names; Matt, 2026-11-20: "I'd like to be able to verify them for the store through a review process"):
  // bytes for the sizes, counts and days for the rest, 0 or 1 for the two switches, each with a default where it is not
  // set. GHOST_MARKET_ON=0 closes it; GHOST_MARKET_NEED_VERIFIED=1 takes plugins only from developers with a verified
  // number; GHOST_MARKET_REVIEW_KEYS empty takes the signed-in admin's own key alone. What it keeps is under
  // ${DATA}/market, which ReadWritePaths below already covers; GHOST_MARKET_MAX_BODY is held to Caddy's 10 MiB.
  GHOST_MARKET_ON: /^[01]$/,
  GHOST_MARKET_MAX_PACKAGE: /^[0-9]{1,8}$/,
  GHOST_MARKET_MAX_SHOT: /^[0-9]{1,8}$/,
  GHOST_MARKET_MAX_SHOTS: /^[0-9]{1,2}$/,
  GHOST_MARKET_MAX_BODY: /^[0-9]{1,9}$/,
  GHOST_MARKET_TOTAL: /^[0-9]{1,13}$/,
  GHOST_MARKET_SUBMISSIONS_A_DAY: /^[0-9]{1,4}$/,
  GHOST_MARKET_SUBMISSIONS_PER_ADDRESS: /^[0-9]{1,4}$/,
  GHOST_MARKET_OPEN_PER_DEVELOPER: /^[0-9]{1,4}$/,
  GHOST_MARKET_OPEN_PER_ADDRESS: /^[0-9]{1,4}$/,
  GHOST_MARKET_OPEN_TOTAL: /^[0-9]{1,6}$/,
  GHOST_MARKET_OPEN_UNVERIFIED: /^[0-9]{1,6}$/,
  GHOST_MARKET_NAME_AGE_DAYS: /^[0-9]{1,3}$/,
  GHOST_MARKET_PLUGINS_PER_DEVELOPER: /^[0-9]{1,4}$/,
  GHOST_MARKET_MAX_PLUGINS: /^[0-9]{1,6}$/,
  GHOST_MARKET_BYTES_PER_DEVELOPER: /^[0-9]{1,10}$/,
  GHOST_MARKET_SIGNED_AN_HOUR: /^[0-9]{1,6}$/,
  GHOST_MARKET_SIGNED_PER_ADDRESS: /^[0-9]{1,6}$/,
  GHOST_MARKET_VERIFY_A_SECOND: /^[0-9]{1,4}$/,
  GHOST_MARKET_BODIES_IN_FLIGHT: /^[0-9]{1,2}$/,
  GHOST_MARKET_READS_PER_MINUTE: /^[0-9]{1,6}$/,
  GHOST_MARKET_REPORTS_A_DAY: /^[0-9]{1,6}$/,
  GHOST_MARKET_NEED_VERIFIED: /^[01]$/,
  GHOST_MARKET_REVIEW_KEYS: /^[A-Za-z0-9+\/]{44}(,[A-Za-z0-9+\/]{44})*$/,
  // The media relay calls fall back on (relay/lib/turn.dart; Matt, 2026-11-21: "if p2p fails please connect over voice
  // through the relay"): coturn's static-auth-secret, where it is (turn: and turns: addresses, commas between), and how
  // long a username and password handed out work for, in seconds.
  GHOST_TURN_SECRET: /^[A-Za-z0-9_-]{32,128}$/,
  GHOST_TURN_URLS: /^turns?:[A-Za-z0-9.-]+(:[0-9]{1,5})?(\?transport=(udp|tcp))?(,turns?:[A-Za-z0-9.-]+(:[0-9]{1,5})?(\?transport=(udp|tcp))?)*$/,
  GHOST_TURN_TTL: /^[0-9]{3,7}$/,
  // Relays that talk to each other (relay/lib/federation.dart `FedConfig.fromEnvironment`; Matt, 2026-11-22: "I'd like
  // the relays to be able to talk to each other"): off unless GHOST_FED is open or list. GHOST_PUBLIC_HUB is this
  // relay's own hub address, which other relays dial to check it is who it says; ALLOW and BLOCK are hosts or relays'
  // names (32 hex), commas between; the three limits are per linked relay; PORTS are ports dialled besides 443, PLAIN=1
  // lets ws:// be dialled; VIA is for a relay with no address of its own; STANDING (off, open, or relays' names) lets
  // relays with no address stay linked to this one. Its key (relay-key.json) and the home records it keeps
  // (homes.json) are under ${DATA}, which ReadWritePaths below already covers.
  GHOST_FED: /^(off|open|list)$/,
  GHOST_PUBLIC_HUB: /^wss:\/\/[a-z0-9.-]+(:[0-9]{1,5})?(\/[A-Za-z0-9._~-]+)*\/hub$/,
  GHOST_FED_ALLOW: /^[a-z0-9.-]+(:[0-9]{1,5})?(,[a-z0-9.-]+(:[0-9]{1,5})?)*$/,
  GHOST_FED_BLOCK: /^[a-z0-9.-]+(:[0-9]{1,5})?(,[a-z0-9.-]+(:[0-9]{1,5})?)*$/,
  GHOST_FED_VIA: /^wss?:\/\/[a-z0-9.-]+(:[0-9]{1,5})?(\/[A-Za-z0-9._~-]+)*\/hub$/,
  GHOST_FED_PACKETS_A_MINUTE: /^[0-9]{1,7}$/,
  GHOST_FED_BYTES_A_DAY: /^[0-9]{1,13}$/,
  GHOST_FED_LOOKUPS_AN_HOUR: /^[0-9]{1,7}$/,
  GHOST_FED_PORTS: /^[0-9]{1,5}(,[0-9]{1,5})*$/,
  GHOST_FED_PLAIN: /^[01]$/,
  GHOST_FED_STANDING: /^(off|open|[0-9a-f]{32}(,[0-9a-f]{32})*)$/,
  // The link helpers the apps' direct links use (relay/lib/hub.dart `helpers`; docs/OPEN_NETWORK.md, section 2): https
  // addresses, commas between, 4 at most, which the hub hands each app as it signs in.
  GHOST_LINK_HELPERS: /^https:\/\/[A-Za-z0-9.-]+(:[0-9]{1,5})?(\/[A-Za-z0-9._\/-]*)?(,https:\/\/[A-Za-z0-9.-]+(:[0-9]{1,5})?(\/[A-Za-z0-9._\/-]*)?){0,3}$/,
};
const SHAPES = {
  GHOST_TWILIO_SID: 'AC or SK and 32 more characters',
  GHOST_TWILIO_TOKEN: '32 letters and digits',
  GHOST_TWILIO_VERIFY: 'VA and 32 more characters',
  GHOST_APP_ORIGIN: 'https:// and the app\'s own host, no slash after (https://app.gogho.st)',
  GHOST_NOTION_TOKEN: 'ntn_ and the rest, from the integration\'s page',
  GHOST_NOTION_FEEDBACK: 'the board\'s data source id, a UUID',
  GHOST_MARKET_REVIEW_KEYS: 'base64 public keys of 44 characters, commas between',
  GHOST_TURN_SECRET: '32 to 128 letters, digits, - or _',
  GHOST_TURN_URLS: 'turn:host:3478?transport=udp and the like, commas between',
  GHOST_HUB_NAMES: 'every host name the hub is reached at, commas between, no ports: gogho.st,www.gogho.st,ghost-sms.com,www.ghost-sms.com',
  GHOST_WIRE_MB: 'megabytes, 8 to 4096 (64 unless set)',
  GHOST_WIRE_EACH_MB: 'megabytes, 1 to 1024 (8 unless set)',
  GHOST_WIRE_STALL_S: 'seconds, 2 to 600 (10 unless set)',
  GHOST_WIRE_IN_STALL_S: 'seconds, 2 to 600 (20 unless set)',
  GHOST_FED: 'off, open or list',
  GHOST_PUBLIC_HUB: 'this relay\'s hub address, like wss://relay.example.com/hub',
  GHOST_FED_ALLOW: 'hosts or relays\' names of 32 hex digits, commas between',
  GHOST_FED_BLOCK: 'hosts or relays\' names of 32 hex digits, commas between',
  GHOST_FED_VIA: 'a relay\'s hub address, like wss://relay.example.com/hub',
  GHOST_FED_STANDING: 'off, open, or relays\' names of 32 hex digits, commas between',
  GHOST_LINK_HELPERS: 'https://host addresses, commas between, 4 at most',
};
// Kept together or not at all: with one of them missing the relay has that way of linking off, and says nothing.
const TOGETHER = [['GHOST_TWILIO_SID', 'GHOST_TWILIO_TOKEN', 'GHOST_TWILIO_VERIFY'], ['GHOST_DISCORD_ID', 'GHOST_DISCORD_SECRET'], ['GHOST_TELEGRAM_BOT', 'GHOST_TELEGRAM_TOKEN'], ['GHOST_NOTION_TOKEN', 'GHOST_NOTION_FEEDBACK'], ['GHOST_TURN_SECRET', 'GHOST_TURN_URLS']];

/** The file's values as the box's file will hold them, and their names. No value is ever part of a message. */
function readEnvFile(file) {
  if (!existsSync(file)) fail(`No file at ${file}.`);
  const values = new Map();
  for (const [i, raw] of readFileSync(file, 'utf8').split(/\r?\n/).entries()) {
    const line = raw.trim();
    if (!line || line.startsWith('#') || line.startsWith(';')) continue;
    const eq = line.indexOf('=');
    const name = eq < 0 ? line : line.slice(0, eq).trim();
    if (eq < 0 || !/^[A-Z0-9_]+$/.test(name)) fail(`${file}, line ${i + 1}: not a NAME=value line.`);
    if (!(name in KNOWN)) fail(`${file}, line ${i + 1}: ${name} is not a name the relay reads. It reads: ${Object.keys(KNOWN).join(', ')}.`);
    let value = line.slice(eq + 1).trim();
    // Copied with quotes round it, or a curly pair an editor made of them.
    value = value.replace(/^["'\u201c\u2018](.*)["'\u201d\u2019]$/, '$1').trim();
    if (!value) continue;
    if (!/^[A-Za-z0-9+_.,:\/@?=-]+$/.test(value)) fail(`${file}: the value of ${name} has a space, a quote or another mark a value does not have.`);
    if (KNOWN[name] && !KNOWN[name].test(value)) fail(`${file}: the value of ${name} does not look right${SHAPES[name] ? ` (it is ${SHAPES[name]})` : ''}. Nothing was sent.`);
    if (values.has(name)) fail(`${file}: ${name} is there twice.`);
    values.set(name, value);
  }
  if (values.size === 0) fail(`${file} has no value filled in yet. Nothing was sent.`);
  for (const group of TOGETHER) {
    const have = group.filter((n) => values.has(n));
    if (have.length > 0 && have.length < group.length) fail(`${file}: ${group.filter((n) => !values.has(n)).join(' and ')} ${group.length - have.length === 1 ? 'is' : 'are'} not filled in, and ${have.join(' and ')} ${have.length === 1 ? 'does' : 'do'} nothing without. Nothing was sent.`);
  }
  return { names: [...values.keys()], bytes: Buffer.from([...values].map(([n, v]) => `${n}=${v}\n`).join(''), 'utf8') };
}

const envAt = args.indexOf('--env');
if (envAt >= 0 && !args[envAt + 1]) fail('--env needs the file: --env ~/.config/mattssoftware/ghost-relay.env');
const envFile = envAt >= 0 ? resolve(args[envAt + 1].replace(/^~(?=\/)/, homedir())) : null;
const secrets = envFile ? readEnvFile(envFile) : null;
const secretsSum = secrets ? createHash('sha256').update(secrets.bytes).digest('hex') : '';
if (secrets) console.log(`> ${envFile}: ${secrets.names.length} ${secrets.names.length === 1 ? 'value' : 'values'} for the box (${secrets.names.join(', ')})`);


// The box is x86-64 Linux (glyph's scripts/deploy-server.mjs builds for the same). Dart builds for it from here.
const dart = [process.env.DART, 'dart'].filter(Boolean).find((d) => spawnSync(d, ['--version'], { stdio: 'ignore' }).status === 0);
if (!dart) fail('No dart on the path (it comes with Flutter: set DART to it).');
mkdirSync(OUT, { recursive: true });
console.log('> Building the relay for the box (Linux, x86-64)');
const built = spawnSync(dart, ['compile', 'exe', '--target-os', 'linux', '--target-arch', 'x64', 'bin/relay.dart', '-o', BIN], { cwd: RELAY, stdio: ['ignore', 'ignore', 'inherit'] });
if (built.status !== 0 || !existsSync(BIN)) fail('dart compile exe failed.');
const program = readFileSync(BIN);
const sum = createHash('sha256').update(program).digest('hex');
console.log(`  ${(program.length / 1e6).toFixed(1)} MB, sha256 ${sum.slice(0, 16)}…`);

const SERVICE = `[Unit]
Description=Uplink relay: pairings at /relay, the hub at /hub (ghost-sms.com)
After=network.target

[Service]
User=ghost-relay
Group=ghost-relay
# The networks' sign-ins for Settings › Me (docs/me.md): GHOST_DISCORD_ID and the rest, one NAME=value a line, in a
# file only root reads. It need not exist: a network with no values is "off" in the app, and nothing else changes.
EnvironmentFile=-${ENV}
ExecStart=${DIR}/ghost-relay --host 127.0.0.1 --port ${PORT} --data ${DATA}
Restart=always
RestartSec=2
MemoryMax=300M
CPUQuota=100%
LimitNOFILE=65536
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=${DATA}

[Install]
WantedBy=multi-user.target
`;

// Run on the box. Reads the program on stdin; with --env, the values' file first, so many bytes of it, and then
// the program. What is staged is in a folder only this account reads, and is gone however the script ends.
const REMOTE = `set -e
SUDO=; [ "$(id -u)" -eq 0 ] || SUDO=sudo
STAGE="$HOME/.ghost-relay-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"; chmod 700 "$STAGE"
trap 'rm -rf "$STAGE"' EXIT
${secrets ? `dd bs=1 count=${secrets.bytes.length} of="$STAGE/env" 2>/dev/null
[ "$(sha256sum "$STAGE/env" | cut -d' ' -f1)" = "${secretsSum}" ] || { echo "x the values arrived changed"; exit 1; }
` : ''}cat > "$STAGE/ghost-relay"
[ "$(sha256sum "$STAGE/ghost-relay" | cut -d' ' -f1)" = "${sum}" ] || { echo "x the relay arrived changed"; exit 1; }
[ "$(uname -m)" = x86_64 ] || { echo "x this box is $(uname -m); the relay was built for x86_64"; exit 1; }
chmod +x "$STAGE/ghost-relay"
# Run here before anything is changed: a build that cannot start on this box stops the deploy.
"$STAGE/ghost-relay" --help >/dev/null || { echo "x the relay does not run on this box"; exit 1; }
# The port is the relay's own, or nobody's. Its own is known by the process that holds it being the service's: the
# name ss gives is cut short ("dart:ghost-rela"), which the first deploy over a running relay took for a stranger.
if $SUDO ss -ltnp 2>/dev/null | grep -q ":${PORT} "; then
  HOLDER=$($SUDO ss -ltnp | grep ":${PORT} " | sed -n 's/.*pid=\\([0-9]*\\).*/\\1/p' | head -1)
  OURS=$($SUDO systemctl show -p MainPID --value ghost-relay 2>/dev/null || true)
  { [ -n "$HOLDER" ] && [ "$HOLDER" = "$OURS" ]; } || { echo "x port ${PORT} is in use by something else:"; $SUDO ss -ltnp | grep ":${PORT} "; exit 1; }
fi
id ghost-relay >/dev/null 2>&1 || $SUDO useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin ghost-relay
$SUDO mkdir -p ${DIR} ${DATA}
$SUDO chown ghost-relay:ghost-relay ${DATA}
$SUDO chmod 750 ${DATA}
$SUDO cp "$STAGE/ghost-relay" ${DIR}/ghost-relay.next
$SUDO chmod 755 ${DIR}/ghost-relay.next
$SUDO mv ${DIR}/ghost-relay.next ${DIR}/ghost-relay
printf '%s' '${SERVICE.replace(/'/g, "'\\''")}' | $SUDO tee ${UNIT} >/dev/null
${secrets ? `# The values: root's alone, in a folder that is root's alone. The service reads them as it starts.
$SUDO mkdir -p ${dirname(ENV)}
$SUDO chmod 700 ${dirname(ENV)}
$SUDO install -m 600 -o root -g root "$STAGE/env" ${ENV}
echo "  ${ENV}: ${secrets.names.length} ${secrets.names.length === 1 ? 'value' : 'values'} written"
` : ''}$SUDO systemctl daemon-reload
$SUDO systemctl enable ghost-relay >/dev/null 2>&1
$SUDO systemctl restart ghost-relay
sleep 2
$SUDO systemctl is-active ghost-relay >/dev/null || { echo "x the relay did not stay up:"; $SUDO journalctl -u ghost-relay -n 20 --no-pager; exit 1; }
ANSWER=$(curl -s --max-time 5 http://127.0.0.1:${PORT}/ || true)
[ "$ANSWER" = "Ghost Messaging relay" ] || { echo "x the relay does not answer on 127.0.0.1:${PORT} (it said: $ANSWER)"; $SUDO journalctl -u ghost-relay -n 20 --no-pager; exit 1; }
echo "ok the relay is running as ghost-relay on 127.0.0.1:${PORT}; $(free -m | awk '/^Mem:/ {print $7}') MB of the box's memory is free"
`;

if (printOnly) {
  process.stdout.write(REMOTE);
  process.exit(0);
}

const { BOX_ENV_KEYS, boxSshOptions, openBox } = await import('./lib/box.mjs');
const { loadEnv } = await import('./lib/box.mjs');
const env = loadEnv(BOX_ENV_KEYS);
const box = openBox(env, boxSshOptions({ connectTimeout: 20, knownHosts: join(homedir(), '.ssh', 'known_hosts') }));
console.log('> Logging in to the box');
box.logIn();
console.log('> Installing the relay (one ssh session)');
const result = box.exec(REMOTE, { input: secrets ? Buffer.concat([secrets.bytes, program]) : program, stdio: ['pipe', 'inherit', 'inherit'] });
if (!args.includes('--keep-connection')) box.close();
if (result.status !== 0) fail(result.status === 5 ? 'ssh refused the password: if .env is right, this is the box\'s lockout; wait it out.' : 'The remote step failed (output above).');

// From here, as an app would reach it: through the web server, at the site's own name.
const curl = (path) => spawnSync('curl', ['-s', '--max-time', '15', `https://${DOMAIN}${path}`], { encoding: 'utf8' }).stdout.trim();
const relay = curl('/relay/'), hub = curl('/hub');
if (relay === 'Ghost Messaging relay' && hub === 'Ghost Messaging relay') {
  console.log(`ok live: wss://${DOMAIN}/relay and wss://${DOMAIN}/hub answer`);
} else {
  console.log(`  https://${DOMAIN}/relay/ and /hub do not reach it yet: the web server has to be told once (node tool/deploy-site.mjs --caddy, while this login is still open).`);
}
