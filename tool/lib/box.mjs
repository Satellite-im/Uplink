/**
 * The box: the server gogho.st, its update feeds, the relay and the site run on, reached over SSH by the release and
 * deploy scripts (tool/release*.mjs, tool/deploy-*.mjs).
 *
 * Its login is read from ~/.config/uplink/release.env (or the file $UPLINK_RELEASE_ENV names), never from this
 * repository. Each value may instead be set in the environment, which wins over the file:
 *
 *   UPLINK_DEPLOY_HOST=        the box's address (a name or an IP)
 *   UPLINK_DEPLOY_USER=        the account to log in as
 *   UPLINK_DEPLOY_PASS=        its password
 *   UPLINK_DEPLOY_PORT=22      optional: SSH's port, 22 where it is not given
 *
 * Until 2026-11-28 the scripts borrowed Ghost.md's own box code and its tauri/.env (AFM_DEPLOY_HOST, AFM_DEPLOY_USER,
 * AFM_DEPLOY_PASS), from a checkout of that repository beside this one (Matt: "we should only be working on Uplink",
 * then "set it up to open from ~/.config/uplink/release.env"). The AFM_ names are still read where the UPLINK_ ones
 * are not set, so a file copied from that .env works as it is.
 *
 * THE BOX COUNTS LOGINS and locks an account out after a few in a short window, so a script logs in ONCE ([logIn])
 * and everything after rides that one connection (SSH's ControlMaster). --keep-connection on a script leaves it open
 * for the next for ten minutes, so a run of several scripts spends a single login.
 *
 * The password goes to sshpass by its environment (`sshpass -e`), never on a command line where `ps` would show it.
 * sshpass answers 5 for a password the box refused.
 */
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

/** The values the box needs, in the order they are said to be missing. */
export const BOX_ENV_KEYS = ['UPLINK_DEPLOY_HOST', 'UPLINK_DEPLOY_USER', 'UPLINK_DEPLOY_PASS'];

/** Where the login is kept. */
export const RELEASE_ENV = process.env.UPLINK_RELEASE_ENV || join(homedir(), '.config', 'uplink', 'release.env');

/** What each value was called in Ghost.md's .env, read where the Uplink name is not set. */
const BEFORE = { UPLINK_DEPLOY_HOST: 'AFM_DEPLOY_HOST', UPLINK_DEPLOY_USER: 'AFM_DEPLOY_USER', UPLINK_DEPLOY_PASS: 'AFM_DEPLOY_PASS' };

const stop = (why) => {
  console.error(`x ${why}`);
  process.exit(1);
};

/** One `KEY=value` file read into an object: blank lines and `#` comments passed over, quotes round a value taken off. */
export function parseEnv(text) {
  const out = {};
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const at = line.indexOf('=');
    if (at < 1) continue;
    const key = line.slice(0, at).replace(/^export\s+/, '').trim();
    let value = line.slice(at + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) value = value.slice(1, -1);
    out[key] = value;
  }
  return out;
}

/**
 * The box's login: [keys] (and the optional port) from the environment, else [RELEASE_ENV]. Stops the script, saying
 * which are missing and where to put them, where any is empty. A file others can read is refused: it holds a password.
 */
export function loadEnv(keys = BOX_ENV_KEYS) {
  let file = {};
  if (existsSync(RELEASE_ENV)) {
    const mode = statSync(RELEASE_ENV).mode & 0o077;
    if (mode) stop(`${RELEASE_ENV} can be read by others (it holds the box's password): chmod 600 ${RELEASE_ENV}`);
    file = parseEnv(readFileSync(RELEASE_ENV, 'utf8'));
  }
  const pick = (key) => process.env[key] || file[key] || (BEFORE[key] && (process.env[BEFORE[key]] || file[BEFORE[key]])) || '';
  const env = {};
  for (const key of [...keys, 'UPLINK_DEPLOY_PORT']) env[key] = pick(key);
  const missing = keys.filter((key) => !env[key]);
  if (missing.length) {
    stop(`The box's login is missing ${missing.join(', ')}. Put ${missing.length === 1 ? 'it' : 'them'} in ${RELEASE_ENV} (one KEY=value a line, chmod 600), or set ${missing.length === 1 ? 'it' : 'them'} in the environment.`);
  }
  if (env.UPLINK_DEPLOY_PORT && !/^\d+$/.test(env.UPLINK_DEPLOY_PORT)) stop(`UPLINK_DEPLOY_PORT is ${env.UPLINK_DEPLOY_PORT}, not a port number.`);
  return env;
}

/**
 * SSH's options for the box: one shared connection (its socket under ~/.config/uplink), a time limit to connect,
 * keep-alives, and the known hosts file ([knownHosts], else SSH's own). A box never seen before is taken and
 * remembered; one whose key has changed since is refused, as SSH does.
 */
export function boxSshOptions({ connectTimeout = 20, knownHosts } = {}) {
  const sockets = join(homedir(), '.config', 'uplink');
  mkdirSync(sockets, { recursive: true, mode: 0o700 });
  return [
    '-o', `ConnectTimeout=${connectTimeout}`,
    '-o', 'ServerAliveInterval=15',
    '-o', 'ServerAliveCountMax=4',
    '-o', 'StrictHostKeyChecking=accept-new',
    ...(knownHosts ? ['-o', `UserKnownHostsFile=${knownHosts}`] : []),
    '-o', 'ControlMaster=auto',
    '-o', `ControlPath=${join(sockets, 'box-%C')}`,
    '-o', 'ControlPersist=600',
  ];
}

/** The site, or any folder, as a gzipped tarball in memory: dot files and folders too, no macOS extras. */
export function tarball(dir, maxBuffer = 64 * 1024 * 1024) {
  const tar = spawnSync('tar', ['-czf', '-', '--no-xattrs', '--no-mac-metadata', '-C', dir, '.'], { maxBuffer });
  if (tar.error) stop(`tar could not run: ${tar.error.message}`);
  if (tar.status !== 0) stop(`tar failed: ${String(tar.stderr)}`);
  return tar.stdout;
}

/**
 * The box, reached with [env] (from [loadEnv]) and [sshOptions] (from [boxSshOptions]):
 *
 *   logIn()                         the one login; stops the script where it is refused
 *   ssh(command)                    runs a shell command there, its output shown; stops the script where it fails
 *   exec(command, { input, stdio }) runs one with [input] on its stdin; the result is spawnSync's, for the caller
 *   rsync(flags, from, to)          copies a file here to a path there; stops the script where it fails
 *   close()                         ends the shared connection
 */
export function openBox(env, sshOptions = boxSshOptions()) {
  const port = env.UPLINK_DEPLOY_PORT || '22';
  const target = `${env.UPLINK_DEPLOY_USER}@${env.UPLINK_DEPLOY_HOST}`;
  const base = ['-p', port, ...sshOptions];
  // sshpass reads SSHPASS; nothing else of this process's environment changes.
  const withPass = { ...process.env, SSHPASS: env.UPLINK_DEPLOY_PASS };
  const sshpass = (args, options = {}) => {
    const result = spawnSync('sshpass', ['-e', ...args], { env: withPass, maxBuffer: 1024 * 1024 * 1024, ...options });
    if (result.error?.code === 'ENOENT') stop('sshpass is not installed: brew install sshpass');
    if (result.error) stop(`ssh could not run: ${result.error.message}`);
    return result;
  };
  const refused = (status) => (status === 5 ? 'the box refused the password: if release.env is right, this is the box\'s lockout; wait it out.' : `ssh ended with ${status}.`);
  return {
    target,
    logIn() {
      const result = sshpass(['ssh', ...base, target, 'true'], { stdio: ['ignore', 'inherit', 'inherit'] });
      if (result.status !== 0) stop(`Could not log in to ${env.UPLINK_DEPLOY_HOST} as ${env.UPLINK_DEPLOY_USER}: ${refused(result.status)}`);
      console.log(`ok logged in to ${env.UPLINK_DEPLOY_HOST}`);
    },
    ssh(command) {
      const result = sshpass(['ssh', ...base, target, command], { stdio: ['ignore', 'inherit', 'inherit'] });
      if (result.status !== 0) stop(`The step on the box failed (output above): ${refused(result.status)}`);
      return result;
    },
    exec(command, { input, stdio = ['pipe', 'inherit', 'inherit'] } = {}) {
      return sshpass(['ssh', ...base, target, command], { input, stdio });
    },
    rsync(flags, from, to) {
      const shell = ['ssh', ...base].map((a) => (/[\s'"]/.test(a) ? `'${a.replace(/'/g, "'\\''")}'` : a)).join(' ');
      const result = sshpass(['rsync', '-e', shell, ...flags, from, `${target}:${to}`], { stdio: ['ignore', 'inherit', 'inherit'] });
      if (result.status !== 0) stop(`Copying ${from} to the box failed: ${refused(result.status)}`);
      return result;
    },
    close() {
      spawnSync('ssh', [...base, '-O', 'exit', target], { stdio: 'ignore' });
    },
  };
}
