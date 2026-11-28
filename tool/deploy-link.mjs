#!/usr/bin/env node
/**
 * Puts a link helper on the box, beside Uplink's relay and no part of it: iroh's relay server, which the
 * direct network's devices find each other through and fall back on when no straight path can be made
 * (docs/OPEN_NETWORK.md section 2: "Link helpers are ours, handed out by the relay"; iroh's public ones are for
 * "development and hobby use only"). tool/build-link.sh builds it; this sends what that built, and nothing else.
 *
 *   node tool/deploy-link.mjs                    installs or updates it, (re)starts it, checks it answers
 *   node tool/deploy-link.mjs --keep-connection  the same, and leaves the login open for the next script
 *   node tool/deploy-link.mjs --print            the script the box would run, and nothing sent
 *
 * Apps reach it at https://gogho.st:7843, which is what the relay's environment file is then given
 * (GHOST_LINK_HELPERS, sent by tool/deploy-relay.mjs --env) for the hub to hand out. Neither DNS nor the web server
 * is touched: it keeps gogho.st's name, takes a TCP port of its own and does its own TLS there, and answers QUIC
 * address discovery on UDP 7842, where an app that is handed only the https address looks for it. 7843 because
 * nothing in iroh ties the two ports together, it is none of the ports the box's other services are known to hold
 * (and the box is asked before anything is changed), and it sits beside the one it belongs with.
 *
 * Its settings and its service are relay/deploy's samples (link-helper.toml.example, ghost-link.service) without
 * their comments and with our name in them, so what runs on the box is what native/link-check proves on this Mac
 * and what docs/SELF_HOSTING.md tells others to run. Each line's reason is in the samples.
 *
 * What it does on the box, in one ssh session. Nothing that is running, and no file it runs from, is changed until
 * every check has passed; then the swap and the restart come together.
 *   - takes the program on its input and holds it to the SHA-256 tool/build-link.sh wrote beside it;
 *   - checks, changing nothing: it runs on this box and is the version meant; its four ports are its own already or
 *     nobody's; Caddy holds a certificate for gogho.st whose key is its pair;
 *   - a user of its own with no shell and no home (ghost-link), its folders, and the certificate copied where that
 *     user can read it: again each day by a timer, with no restart, since the helper reads the files again itself
 *     once a day (Caddy renews about every two months);
 *   - the new program with the new settings is started as that user for three seconds on ports of its own. A
 *     setting it will not take or a certificate it cannot read stops the deploy here, the old one still running;
 *   - opens TCP 7843 and UDP 7842 in ufw;
 *   - swaps program, settings and service in, restarts, and checks it is listening and answers /healthz with
 *     gogho.st's certificate. Then the same question is asked from this Mac.
 *
 * It reaches the box through tool/lib/box.mjs (its login in ~/.config/uplink/release.env), as tool/deploy-relay.mjs does.
 */
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const DOMAIN = 'gogho.st';
const VERSION = '1.5.0'; // tool/build-link.sh's, and the one this script's checks were read against
const PORT = 7843; // TCP, https: where apps reach it
const QUIC = 7842; // UDP: QUIC address discovery
const PLAIN = 7844; // TCP, the box alone: the plain-HTTP door the server always opens
const METRICS = 7845; // TCP, the box alone: its counters
const BIN = join(ROOT, 'build', 'link', 'iroh-relay');
const DIR = '/opt/ghost-link';
const DATA = '/var/lib/ghost-link';
const ETC = '/etc/ghost-link';
const UNIT = '/etc/systemd/system/ghost-link.service';
const CADDY = '/var/lib/caddy/.local/share/caddy/certificates';
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

// The program: there, the version meant, and the very bytes tool/build-link.sh hashed. Anything else is not sent.
for (const file of [BIN, `${BIN}.sha256`, `${BIN}.version`]) if (!existsSync(file)) fail(`No ${file}: build the link helper first (tool/build-link.sh). Nothing was sent.`);
const program = readFileSync(BIN);
const sum = createHash('sha256').update(program).digest('hex');
const built = readFileSync(`${BIN}.version`, 'utf8').trim();
if (readFileSync(`${BIN}.sha256`, 'utf8').trim().split(/\s+/)[0] !== sum) fail(`${BIN} is not what ${BIN}.sha256 says was built: build it again (tool/build-link.sh). Nothing was sent.`);
if (built !== VERSION) fail(`${BIN} is iroh-relay ${built}; this script is for ${VERSION}. Nothing was sent.`);
// An ELF file by its first four bytes, for x86-64 by its machine number (62).
if (program.readUInt32BE(0) !== 0x7f454c46 || program.readUInt16LE(18) !== 62) fail(`${BIN} is not a Linux x86-64 program (tool/build-link.sh with no "host"). Nothing was sent.`);

/** A sample from relay/deploy as the box gets it: its lines without its comments, our name for the example's. */
function ours(sample, needs) {
  const lines = readFileSync(join(ROOT, 'relay', 'deploy', sample), 'utf8').split('\n').filter((line) => !line.startsWith('#'));
  const text = lines.join('\n').replaceAll('relay.example.com', DOMAIN).replace(/\n{3,}/g, '\n\n').trim();
  // What this script does on the box (the ports it opens, the folders it makes, the certificate it copies) and what
  // the sample says must be the same thing.
  for (const line of needs) if (!text.split('\n').includes(line)) fail(`relay/deploy/${sample} no longer has the line this script goes by: ${line}. Nothing was sent.`);
  if (/example|EOF_/.test(text)) fail(`relay/deploy/${sample} still names an example after ours was put in (or has a line that would end this script's own). Nothing was sent.`);
  return text;
}
const SETTINGS = ours('link-helper.toml.example', [
  'access = "everyone"',
  `http_bind_addr = "127.0.0.1:${PLAIN}"`,
  `metrics_bind_addr = "127.0.0.1:${METRICS}"`,
  `https_bind_addr = "0.0.0.0:${PORT}"`,
  `quic_bind_addr = "0.0.0.0:${QUIC}"`,
  'cert_mode = "Reloading"',
  `manual_cert_path = "${ETC}/certs/${DOMAIN}.crt"`,
  `manual_key_path = "${ETC}/certs/${DOMAIN}.key"`,
]);
const SERVICE = ours('ghost-link.service', [
  'User=ghost-link',
  'Group=ghost-link',
  `WorkingDirectory=${DATA}`,
  `ExecStart=${DIR}/iroh-relay --config-path ${ETC}/config.toml`,
  `ReadWritePaths=${DATA}`,
]);

// Run on the box, the program on its input. What is staged is in a folder only this account reads, and is gone
// however the script ends, with whatever was put beside the running files and not yet swapped in.
const REMOTE = String.raw`set -e
SUDO=; [ "$(id -u)" -eq 0 ] || SUDO=sudo
STAGE="$HOME/.ghost-link-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"; chmod 700 "$STAGE"
trap 'rm -rf "$STAGE"; $SUDO rm -f ${DIR}/iroh-relay.next ${ETC}/config.toml.next ${ETC}/try.toml' EXIT
journal() { $SUDO journalctl -u ghost-link -n 30 --no-pager; }

cat > "$STAGE/iroh-relay"
[ "$(sha256sum "$STAGE/iroh-relay" | cut -d' ' -f1)" = "${sum}" ] || { echo "x the link helper arrived changed"; exit 1; }
[ "$(uname -m)" = x86_64 ] || { echo "x this box is $(uname -m); the link helper was built for x86_64"; exit 1; }
chmod +x "$STAGE/iroh-relay"
# Run here before anything is changed: a build this box cannot start (its C library too old, say) stops the deploy.
SAID=$("$STAGE/iroh-relay" --version 2>&1) || { echo "x the link helper does not run on this box: $SAID"; exit 1; }
[ "$SAID" = "iroh-relay ${VERSION}" ] || { echo "x what arrived says it is \"$SAID\", not iroh-relay ${VERSION}"; exit 1; }
for tool in ufw runuser timeout openssl curl ss; do command -v $tool >/dev/null || { echo "x this box has no $tool, which this script uses"; exit 1; }; done

# Its four ports are its own already (held by the service's own process), or nobody's.
MAIN=$($SUDO systemctl show -p MainPID --value ghost-link 2>/dev/null || true)
ours_or_free() {
  OTHERS=$($SUDO ss -lnp$1 | grep ":$2 " | grep -v "pid=$MAIN," || true)
  [ -z "$OTHERS" ] || { echo "x port $2 is in use by something else:"; echo "$OTHERS"; exit 1; }
}
ours_or_free t ${PORT}; ours_or_free u ${QUIC}; ours_or_free t ${PLAIN}; ours_or_free t ${METRICS}

# What copies the certificate: written here, asked first whether there is one to copy, and installed further down.
cat > "$STAGE/ghost-link-cert" <<'EOF_CERT'
#!/bin/sh
# Copies Caddy's certificate for ${DOMAIN} where the link helper reads it (tool/deploy-link.mjs in the glyph
# repository's messaging/). Nothing is restarted: the helper reads the two files again by itself once a day.
# With --check it copies nothing, and says only whether Caddy has a pair to copy.
set -e
CRT=$(ls -t ${CADDY}/*/${DOMAIN}/${DOMAIN}.crt 2>/dev/null | head -1)
[ -n "$CRT" ] || { echo "Caddy holds no certificate for ${DOMAIN}"; exit 1; }
KEY=$(dirname "$CRT")/${DOMAIN}.key
# Caddy writes the two one after the other. A pair caught half way through a renewal is left for the next run.
PUBLIC=$(openssl x509 -in "$CRT" -noout -pubkey) && [ -n "$PUBLIC" ] && [ "$PUBLIC" = "$(openssl pkey -in "$KEY" -pubout)" ] || { echo "Caddy's certificate and key for ${DOMAIN} are not a pair (a renewal under way?)"; exit 1; }
[ "$1" = "--check" ] && exit 0
TO=${ETC}/certs/${DOMAIN}
if cmp -s "$CRT" "$TO.crt" && cmp -s "$KEY" "$TO.key"; then exit 0; fi
install -m 640 -o root -g ghost-link "$CRT" "$TO.crt.new"
install -m 640 -o root -g ghost-link "$KEY" "$TO.key.new"
mv "$TO.key.new" "$TO.key"
mv "$TO.crt.new" "$TO.crt"
EOF_CERT
$SUDO sh "$STAGE/ghost-link-cert" --check || { echo "x no certificate to give the link helper"; exit 1; }

cat > "$STAGE/config.toml" <<'EOF_SETTINGS'
# Uplink's link helper (iroh-relay ${VERSION}), written by tool/deploy-link.mjs in the glyph repository's
# messaging/. Why each line is as it is: relay/deploy/link-helper.toml.example there.
${SETTINGS}
EOF_SETTINGS
cat > "$STAGE/ghost-link.service" <<'EOF_SERVICE'
${SERVICE}
EOF_SERVICE
cat > "$STAGE/ghost-link-cert.service" <<'EOF_UNIT'
[Unit]
Description=Copy ${DOMAIN}'s certificate for the link helper (Uplink, tool/deploy-link.mjs)
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ghost-link-cert
EOF_UNIT
cat > "$STAGE/ghost-link-cert.timer" <<'EOF_UNIT'
[Unit]
Description=Copy ${DOMAIN}'s certificate for the link helper each day
[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
EOF_UNIT

# From here things are made, beside what is running and never in its place: its user, its folders, the certificate
# where it can read it, and the new program and settings under other names.
id ghost-link >/dev/null 2>&1 || $SUDO useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin ghost-link
$SUDO install -d -m 755 -o root -g root ${DIR}
$SUDO install -d -m 750 -o ghost-link -g ghost-link ${DATA}
$SUDO install -d -m 750 -o root -g ghost-link ${ETC} ${ETC}/certs
$SUDO install -m 755 -o root -g root "$STAGE/ghost-link-cert" /usr/local/sbin/ghost-link-cert
$SUDO /usr/local/sbin/ghost-link-cert
$SUDO install -m 755 -o root -g root "$STAGE/iroh-relay" ${DIR}/iroh-relay.next
$SUDO install -m 640 -o root -g ghost-link "$STAGE/config.toml" ${ETC}/config.toml.next

# The new program with the new settings, as its own user, for three seconds on whatever ports are free. Still up
# when the three seconds end (timeout says 124) and listening: it will start. Anything else, and the deploy stops
# with nothing running touched.
sed -E -e 's/^(https_bind_addr|quic_bind_addr) = .*/\1 = "0.0.0.0:0"/' -e 's/^(http_bind_addr|metrics_bind_addr) = .*/\1 = "127.0.0.1:0"/' "$STAGE/config.toml" > "$STAGE/try.toml"
[ "$(grep -c ':0"$' "$STAGE/try.toml")" -eq 4 ] || { echo "x the settings do not have the four addresses this script expects"; exit 1; }
$SUDO install -m 640 -o root -g ghost-link "$STAGE/try.toml" ${ETC}/try.toml
TRY=0
$SUDO runuser -u ghost-link -- env RUST_LOG=info NO_COLOR=1 timeout 3 ${DIR}/iroh-relay.next --config-path ${ETC}/try.toml </dev/null >"$STAGE/try.log" 2>&1 || TRY=$?
$SUDO rm -f ${ETC}/try.toml
if [ "$TRY" -ne 124 ] || ! grep -q 'relay: serving on' "$STAGE/try.log" || ! grep -q 'QUIC server listening' "$STAGE/try.log"; then
  echo "x the new link helper does not start with the new settings (nothing that is running was touched). It said:"; cat "$STAGE/try.log"; exit 1
fi
echo "ok the new program starts with the new settings, as ghost-link"

$SUDO ufw allow ${PORT}/tcp comment 'link helper (Uplink direct links)' >/dev/null
$SUDO ufw allow ${QUIC}/udp comment 'link helper, QUIC address discovery (Uplink direct links)' >/dev/null
echo "ok ufw lets in ${PORT} (TCP) and ${QUIC} (UDP)"

# The swap and the restart.
$SUDO mv ${DIR}/iroh-relay.next ${DIR}/iroh-relay
$SUDO mv ${ETC}/config.toml.next ${ETC}/config.toml
$SUDO install -m 644 -o root -g root "$STAGE/ghost-link.service" ${UNIT}
$SUDO install -m 644 -o root -g root "$STAGE/ghost-link-cert.service" "$STAGE/ghost-link-cert.timer" /etc/systemd/system/
$SUDO systemctl daemon-reload
$SUDO systemctl enable -q --now ghost-link-cert.timer
$SUDO systemctl enable -q ghost-link
$SUDO systemctl restart ghost-link
sleep 2
$SUDO systemctl is-active -q ghost-link || { echo "x the link helper did not stay up:"; journal; exit 1; }
for want in 'tcp.*:${PORT} ' 'udp.*:${QUIC} '; do
  $SUDO ss -lnptu | grep -E "$want" | grep -q iroh-relay || { echo "x the link helper is not listening on $want"; journal; exit 1; }
done
# Asked on the box itself, by name, so the certificate it answers with is held to ${DOMAIN}'s.
ANSWER=$(curl -s --max-time 5 --resolve ${DOMAIN}:${PORT}:127.0.0.1 https://${DOMAIN}:${PORT}/healthz || true)
case "$ANSWER" in
  *'"status":"ok"'*'"version":"${VERSION}"'*) ;;
  *) echo "x the link helper does not answer https://${DOMAIN}:${PORT}/healthz on the box (it said: $ANSWER)"; journal; exit 1 ;;
esac
echo "ok the link helper is running as ghost-link, on ${PORT} (TCP) and ${QUIC} (UDP); $(free -m | awk '/^Mem:/ {print $7}') MB of the box's memory is free"
`;

if (printOnly) {
  process.stdout.write(REMOTE);
  process.exit(0);
}

console.log(`> ${BIN}: iroh-relay ${built}, ${(program.length / 1e6).toFixed(1)} MB, sha256 ${sum.slice(0, 16)}…`);
const { BOX_ENV_KEYS, boxSshOptions, openBox } = await import('./lib/box.mjs');
const { loadEnv } = await import('./lib/box.mjs');
const env = loadEnv(BOX_ENV_KEYS);
const box = openBox(env, boxSshOptions({ connectTimeout: 20, knownHosts: join(homedir(), '.ssh', 'known_hosts') }));
console.log('> Logging in to the box');
box.logIn();
console.log('> Installing the link helper (one ssh session)');
const result = box.exec(REMOTE, { input: program, stdio: ['pipe', 'inherit', 'inherit'] });
if (!args.includes('--keep-connection')) box.close();
if (result.status !== 0) fail('The remote step failed (output above).');

// From here, as an app reaches it: by name, on its own port, the certificate checked as any https client checks one.
const health = spawnSync('curl', ['-s', '--max-time', '15', `https://${DOMAIN}:${PORT}/healthz`], { encoding: 'utf8' }).stdout.trim();
if (health.includes('"status":"ok"') && health.includes(`"version":"${VERSION}"`)) {
  console.log(`ok live: https://${DOMAIN}:${PORT} answers as iroh-relay ${VERSION}, with ${DOMAIN}'s certificate`);
} else {
  console.log(`  https://${DOMAIN}:${PORT}/healthz did not answer from here (${health || 'no answer'}): the box says it is up, so look at what is between (a firewall before the box?).`);
}
console.log(`  UDP ${QUIC} is not something curl can ask. This does, and links two devices through it: (cd native/link-check && cargo run -- https://${DOMAIN}:${PORT})`);
console.log(`  Then, for the hub to hand it out: GHOST_LINK_HELPERS=https://${DOMAIN}:${PORT} in the relay's environment file, and node tool/deploy-relay.mjs --env <file>`);
