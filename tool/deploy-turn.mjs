#!/usr/bin/env node
/**
 * Puts the media relay calls fall back on onto the box: coturn, a TURN server, beside Uplink's relay (Matt,
 * 2026-11-21: "Sometimes calls are not negotiating in voice chats and I can't connect to another person, if p2p fails
 * please connect over voice through the relay"). relay/lib/turn.dart says why and how the two fit.
 *
 *   node tool/deploy-turn.mjs --env <file>                    installs or updates it, (re)starts it, checks it answers
 *   node tool/deploy-turn.mjs --env <file> --keep-connection  the same, and leaves the login open for the next script
 *   node tool/deploy-turn.mjs --print                         the script the box would run, and nothing sent
 *
 * <file> is the relay's own environment file (the one tool/deploy-relay.mjs --env sends), from which this takes
 * GHOST_TURN_SECRET alone: coturn and the hub must hold the same secret, and the hub hands out usernames and
 * passwords made from it. It goes down the ssh session on its input, never in a command; only its length is printed.
 * Send the same file to the relay afterwards (deploy-relay.mjs --env), with GHOST_TURN_URLS naming the addresses
 * below, and the hub starts handing the relay out.
 *
 * What it does on the box, in one ssh session:
 *   - installs coturn from Ubuntu's own packages, where it isn't yet;
 *   - writes /etc/turnserver.conf: UDP and TCP on 3478, TLS on 5349 with gogho.st's certificate, relayed ports
 *     49160-49400 (40000-40100 are another service's), the hub's REST-style passwords only (use-auth-secret), and
 *     never relaying to loopback or any private or Tailscale address, and no TCP relaying, so a TURN password can't
 *     be used to reach the box's own services;
 *   - copies Caddy's certificate for gogho.st where coturn can read it, and does so again each day by a timer,
 *     restarting coturn only when the certificate changed (Caddy renews it about every two months; a restart drops
 *     the calls going through the relay at that moment, which connect again);
 *   - opens those ports in ufw;
 *   - enables and restarts coturn, and checks it is listening.
 */
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const DOMAIN = 'gogho.st';
const MIN_PORT = 49160;
const MAX_PORT = 49400;
// The box's public address (149.248.47.151 on enp1s0f0, 2026-11-21): what coturn listens and relays on.
const PUBLIC_IP = '149.248.47.151';
const args = process.argv.slice(2);
const printOnly = args.includes('--print');
// Says what is wrong and ends the script; and the value after --name on the command line, or null.
const fail = (message) => {
  console.error(`x ${message}`);
  process.exit(1);
};
const flag = (name) => {
  const at = args.indexOf(`--${name}`);
  return at >= 0 ? args[at + 1] : null;
};

/** GHOST_TURN_SECRET from the relay's environment file; no value is ever part of a message. */
function readSecret(file) {
  if (!existsSync(file)) fail(`No file at ${file}.`);
  for (const raw of readFileSync(file, 'utf8').split(/\r?\n/)) {
    const line = raw.trim();
    if (!line.startsWith('GHOST_TURN_SECRET=')) continue;
    const value = line.slice('GHOST_TURN_SECRET='.length).trim().replace(/^["'](.*)["']$/, '$1');
    if (!/^[A-Za-z0-9_-]{32,128}$/.test(value)) fail(`${file}: GHOST_TURN_SECRET is not 32 to 128 letters, digits, - or _. Nothing was sent.`);
    return value;
  }
  fail(`${file} has no GHOST_TURN_SECRET. Make one (for example: openssl rand -hex 32) and add it, with GHOST_TURN_URLS, then run this again.`);
}

const REMOTE = String.raw`set -e
SUDO=; [ "$(id -u)" -eq 0 ] || SUDO=sudo
read -r SECRET
[ -n "$SECRET" ] || { echo "x no secret came"; exit 1; }

if ! command -v turnserver >/dev/null; then
  echo "> installing coturn"
  $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -q coturn >/dev/null
fi
echo "ok $(turnserver --version 2>/dev/null | head -1 || echo coturn) installed"

# The certificate, where coturn (user turnserver) can read it; again each day by the timer below.
$SUDO install -d -m 750 -o root -g turnserver /etc/coturn/certs
$SUDO tee /usr/local/sbin/ghost-turn-cert >/dev/null <<'CERT'
#!/bin/sh
# Copies Caddy's certificate for ${DOMAIN} where coturn reads it (tool/deploy-turn.mjs); restarts coturn when it changed.
set -e
SRC=$(ls -d /var/lib/caddy/.local/share/caddy/certificates/*/${DOMAIN} 2>/dev/null | head -1)
[ -n "$SRC" ] || { echo "no certificate for ${DOMAIN} from Caddy"; exit 1; }
if cmp -s "$SRC/${DOMAIN}.crt" /etc/coturn/certs/${DOMAIN}.crt && cmp -s "$SRC/${DOMAIN}.key" /etc/coturn/certs/${DOMAIN}.key; then exit 0; fi
install -m 640 -o root -g turnserver "$SRC/${DOMAIN}.crt" /etc/coturn/certs/${DOMAIN}.crt
install -m 640 -o root -g turnserver "$SRC/${DOMAIN}.key" /etc/coturn/certs/${DOMAIN}.key
if [ "$1" != "--no-restart" ] && systemctl is-active -q coturn; then systemctl restart coturn; fi
CERT
$SUDO chmod 755 /usr/local/sbin/ghost-turn-cert
$SUDO /usr/local/sbin/ghost-turn-cert --no-restart
$SUDO tee /etc/systemd/system/ghost-turn-cert.service >/dev/null <<'UNIT'
[Unit]
Description=Copy gogho.st's certificate for coturn (Uplink, tool/deploy-turn.mjs)
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ghost-turn-cert
UNIT
$SUDO tee /etc/systemd/system/ghost-turn-cert.timer >/dev/null <<'UNIT'
[Unit]
Description=Copy gogho.st's certificate for coturn each day
[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
UNIT

# The configuration. The secret is written by this shell from its input, never by a command line others could read.
umask 027
$SUDO tee /etc/turnserver.conf.new >/dev/null <<CONF
# Uplink's media relay for calls (tool/deploy-turn.mjs in the glyph repository's messaging/; relay/lib/turn.dart).
listening-port=3478
tls-listening-port=5349
min-port=${MIN_PORT}
max-port=${MAX_PORT}
realm=${DOMAIN}
server-name=${DOMAIN}
use-auth-secret
static-auth-secret=$SECRET
fingerprint
cert=/etc/coturn/certs/${DOMAIN}.crt
pkey=/etc/coturn/certs/${DOMAIN}.key
no-tlsv1
no-tlsv1_1
no-cli
no-multicast-peers
no-rfc5780
# On the box's public address only (not Tailscale's), and relaying to it too: when both people in a call relay through
# here, each one's relayed address is this box's, so it must be a peer this server may send to (blocking it broke every
# relay-to-relay call, found 2026-11-21 by the first test). What that reaches is UDP on the public address, where only
# the relayed ports, Caddy's QUIC and Tailscale listen, all public anyway; TCP relaying is off (WebRTC never asks for it),
# so services the firewall keeps in can't be reached through a TURN password. Keep any new UDP service off 0.0.0.0.
listening-ip=${PUBLIC_IP}
relay-ip=${PUBLIC_IP}
no-tcp-relay
# Never a way to loopback or anything private beside the box.
denied-peer-ip=0.0.0.0-0.255.255.255
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=100.64.0.0-100.127.255.255
denied-peer-ip=127.0.0.0-127.255.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=::1
denied-peer-ip=fc00::-fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff
denied-peer-ip=fe80::-febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff
total-quota=240
user-quota=24
stale-nonce=600
syslog
simple-log
CONF
$SUDO chown root:turnserver /etc/turnserver.conf.new
$SUDO chmod 640 /etc/turnserver.conf.new
$SUDO mv /etc/turnserver.conf.new /etc/turnserver.conf
[ -f /etc/default/coturn ] && $SUDO sed -i 's/^#\?TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn

$SUDO ufw allow 3478/udp comment 'coturn (Uplink calls)' >/dev/null
$SUDO ufw allow 3478/tcp comment 'coturn (Uplink calls)' >/dev/null
$SUDO ufw allow 5349/tcp comment 'coturn TLS (Uplink calls)' >/dev/null
$SUDO ufw allow ${MIN_PORT}:${MAX_PORT}/udp comment 'coturn relayed (Uplink calls)' >/dev/null
echo "ok ufw lets in 3478 (UDP and TCP), 5349 (TCP) and ${MIN_PORT}-${MAX_PORT} (UDP)"

$SUDO systemctl daemon-reload
$SUDO systemctl enable -q --now ghost-turn-cert.timer
$SUDO systemctl enable -q coturn
$SUDO systemctl restart coturn
sleep 2
$SUDO systemctl is-active -q coturn || { echo "x coturn did not stay up:"; $SUDO journalctl -u coturn -n 30 --no-pager; exit 1; }
for want in 'udp.*:3478\b' 'tcp.*:3478\b' 'tcp.*:5349\b'; do
  $SUDO ss -lnptu | grep -E "$want" | grep -q turnserver || { echo "x coturn is not listening on $want"; $SUDO journalctl -u coturn -n 30 --no-pager; exit 1; }
done
echo "ok coturn is running, on 3478 and 5349; $(free -m | awk '/^Mem:/ {print $7}') MB of the box's memory is free"
`;

if (printOnly) {
  process.stdout.write(REMOTE);
  process.exit(0);
}

const envFile = flag('env');
if (!envFile) fail('Name the relay\'s environment file: --env <file> (it holds GHOST_TURN_SECRET).');
const secret = readSecret(resolve(envFile.replace(/^~(?=\/)/, homedir())));
console.log(`> ${envFile}: GHOST_TURN_SECRET (${secret.length} characters) for the box`);

const glyph = [flag('glyph'), process.env.GLYPH_ROOT, join(ROOT, '..'), join(homedir(), 'Development/Apps/glyph')]
  .filter(Boolean)
  .map((p) => resolve(p.replace(/^~(?=\/)/, homedir())))
  .find((p) => existsSync(join(p, 'tauri/scripts/lib/box.mjs')));
if (!glyph) fail('Ghost.md\'s checkout (for the box\'s login) was not found: --glyph <path>.');
const { BOX_ENV_KEYS, boxSshOptions, openBox } = await import(pathToFileURL(join(glyph, 'tauri/scripts/lib/box.mjs')).href);
const { loadEnv } = await import(pathToFileURL(join(glyph, 'scripts/lib/env.mjs')).href);
const env = loadEnv(BOX_ENV_KEYS);
const box = openBox(env, boxSshOptions({ connectTimeout: 20, knownHosts: join(homedir(), '.ssh', 'known_hosts') }));
console.log('> Logging in to the box');
box.logIn();
console.log('> Setting up coturn (one ssh session)');
const result = box.exec(REMOTE, { input: `${secret}\n`, stdio: ['pipe', 'inherit', 'inherit'] });
if (!args.includes('--keep-connection')) box.close();
if (result.status !== 0) fail('The remote step failed (output above).');

// From here, as a phone would reach it: is TLS on 5349 answering with the site's certificate?
const tls = spawnSync('sh', ['-c', `echo | openssl s_client -connect ${DOMAIN}:5349 -servername ${DOMAIN} 2>/dev/null | openssl x509 -noout -subject 2>/dev/null`], { encoding: 'utf8', timeout: 20000 });
console.log(tls.stdout.includes(DOMAIN) ? `ok ${DOMAIN}:5349 answers with ${DOMAIN}'s certificate` : `  ${DOMAIN}:5349 did not answer with its certificate from here (${tls.stdout.trim() || 'no answer'})`);
console.log(`  Next: GHOST_TURN_URLS=turn:${DOMAIN}:3478?transport=udp,turn:${DOMAIN}:3478?transport=tcp,turns:${DOMAIN}:5349?transport=tcp in the same file, then node tool/deploy-relay.mjs --env ${envFile}`);
