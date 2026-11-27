/**
 * Where the platforms a Mac cannot build are built: GitHub's runners, in the app's own repository.
 *
 * Until 2026-11-27 the Windows and Linux builds ran in the repository the app is developed in (InfamousVague/glyph,
 * its .github/workflows/messaging-windows.yml and messaging-linux.yml, which build that repository's main). They run
 * now in Satellite-im/Uplink, where the source is published with every release (Matt, asked "Move the Windows, Linux
 * and relay builds onto Satellite-im/Uplink?": "Yes, move them"): the workflows are the app's own files
 * (.github/workflows/windows.yml and linux.yml in this folder, which is that repository's root), so they travel with
 * the source and build what was published beside them.
 *
 * A RUNNER BUILDS WHAT ITS REPOSITORY HOLDS, never what is on this computer (0.12.24 and 0.12.25 went out for Windows
 * and Linux as 0.12.23's code under their numbers: tool/lib/built_ref.mjs). So before a build is asked for there,
 * tool/publish-source.mjs brings Satellite-im/Uplink's main up to this checkout's commit, the build is asked for at
 * main, and when it ends it is held to the commit that was published: a build of anything else is refused.
 *
 * `--on glyph` on a release script builds where it was built before, for as long as that repository keeps the old
 * workflows. Windows does so by itself while Satellite-im/Uplink lacks the signing account's secrets (signingLacks):
 * an installer built there would be unsigned, and an unsigned one is never released in a signed one's place.
 *
 * NOT YET, THOUGH ([RUNS_IN]). The day the workflows were first published there and asked to run (2026-11-27), every
 * job ended before it began: "The job was not started because your account is locked due to a billing issue". The
 * Satellite-im organization's GitHub account is locked for billing, which only its owner can settle, and until it is
 * no runner there starts anything. So a release builds where it always did, unless `--on uplink` says to try there.
 * Once the account is settled: `gh workflow run linux.yml --repo Satellite-im/Uplink --ref main -f version=<v> -f
 * build=<n>` (and windows.yml) as a trial, and when one has passed, [RUNS_IN] becomes 'uplink'.
 */
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { refLacksRelease } from './built_ref.mjs';

export const UPLINK = 'Satellite-im/Uplink';
export const GLYPH = 'InfamousVague/glyph';
/** Where a release builds when it is not told: 'glyph' until Satellite-im/Uplink's runners can start a job (above). */
export const RUNS_IN = 'glyph';

/** The repository and the workflow file for [name] ('windows' or 'linux'), built [on] 'uplink' or 'glyph'. */
export const runnerFor = (on, name) => (on === 'uplink' ? { repo: UPLINK, workflow: `${name}.yml` } : { repo: GLYPH, workflow: `messaging-${name}.yml` });

/** What a Windows build needs of a repository's secrets to sign (the workflow's own test, and what its steps read). */
export const SIGNING_SECRETS = ['AZURE_TENANT_ID', 'AZURE_CLIENT_ID', 'AZURE_SIGNING_ENDPOINT', 'AZURE_SIGNING_ACCOUNT', 'AZURE_SIGNING_PROFILE'];

/**
 * Which of [SIGNING_SECRETS] Satellite-im/Uplink lacks: none where a Windows build there would be signed. Null
 * where the repository's secrets could not be listed (their names alone are read; a secret's value never is).
 */
export function signingLacks() {
  const r = spawnSync('gh', ['secret', 'list', '--repo', UPLINK, '--json', 'name'], { encoding: 'utf8' });
  if (r.status !== 0) return null;
  const there = new Set(JSON.parse(r.stdout || '[]').map((s) => s.name));
  return SIGNING_SECRETS.filter((name) => !there.has(name));
}

/**
 * Brings Satellite-im/Uplink's main up to what is committed here and gives the commit main then stands at
 * (`{ sha }`), or why it could not (`{ why }`). tool/publish-source.mjs does the publishing, and keeps its checkout
 * of that repository in build/public/Uplink: its HEAD is what was pushed, and main is asked to be sure.
 */
export function uplinkHolds(root) {
  const published = spawnSync('node', [join(root, 'tool/publish-source.mjs')], { stdio: 'inherit' });
  if (published.status !== 0) return { why: `The source could not be published to ${UPLINK}, so there is nothing there to build.` };
  const head = spawnSync('git', ['-C', join(root, 'build/public/Uplink'), 'rev-parse', 'HEAD'], { encoding: 'utf8' });
  if (head.status !== 0) return { why: `No checkout of ${UPLINK} in build/public/Uplink after publishing.` };
  const sha = head.stdout.trim();
  const main = spawnSync('gh', ['api', `repos/${UPLINK}/commits/main`, '--jq', '.sha'], { encoding: 'utf8' });
  if (main.status !== 0) return { why: `${UPLINK}'s main could not be read.` };
  if (main.stdout.trim() !== sha) return { why: `${UPLINK}'s main is ${main.stdout.trim().slice(0, 9)}, not the ${sha.slice(0, 9)} just published: something else pushed there. Run it again.` };
  return { sha };
}

/**
 * Starts the build of [versionName] ([versionCode]) for [name] and gives `{ run, repo, sha }`: the run's id, the
 * repository it runs in, and, built in Satellite-im/Uplink, the commit it must be of ([finished] holds it to it).
 * [out] runs a command for what it prints and stops the release where it fails; [fail] stops it with words.
 */
export async function started({ root, on, name, versionName, versionCode, noP2p, ref, out, say, fail, sleep }) {
  const { repo, workflow } = runnerFor(on, name);
  let sha = null;
  let at = ref ?? 'main';
  if (on === 'uplink') {
    // The source first: the runner builds what that repository's main holds.
    say(`> The source to ${UPLINK}, where it is built`);
    const held = uplinkHolds(root);
    if (held.why) fail(`${held.why} Nothing was built.`);
    sha = held.sha;
    at = 'main';
  } else {
    const lacks = refLacksRelease(root, at);
    if (lacks) fail(`${lacks} Nothing was built.`);
  }
  const listed = () => JSON.parse(out('gh', ['run', 'list', '--repo', repo, '--workflow', workflow, '--limit', '20', '--json', 'databaseId'])).map((r) => r.databaseId);
  const before = new Set(listed());
  // --no-p2p: the runner leaves the direct network's core out (the workflow's own `p2p` input; the app then has no
  // direct route). Not said at all otherwise, so a workflow from before the core is asked nothing it doesn't know.
  out('gh', ['workflow', 'run', workflow, '--repo', repo, '--ref', at, '-f', `version=${versionName}`, '-f', `build=${versionCode}`, ...(noP2p ? ['-f', 'p2p=no'] : [])]);
  let run = null;
  for (let i = 0; i < 30 && !run; i++) {
    await sleep(4000);
    const fresh = listed().find((id) => !before.has(id));
    if (fresh) run = String(fresh);
  }
  if (!run) fail(`The build did not start on GitHub (${repo}, ${workflow}).`);
  return { run, repo, sha };
}

/**
 * Waits for [run] in [repo] to end. Stops the release where it did not succeed, or, where [sha] is given, where it
 * was a build of another commit than [sha]. [what] names the build in the words that stop it ("Windows").
 */
export async function finished({ run, repo, sha, what, out, fail, sleep }) {
  for (;;) {
    const r = JSON.parse(out('gh', ['run', 'view', run, '--repo', repo, '--json', 'status,conclusion,headSha']));
    if (r.status === 'completed') {
      if (r.conclusion !== 'success') fail(`The ${what} build ended ${r.conclusion}: gh run view ${run} --repo ${repo} --log-failed`);
      if (sha && r.headSha !== sha) fail(`The ${what} build was of ${String(r.headSha).slice(0, 9)}, not of this release (${sha.slice(0, 9)}): ${repo}'s main moved before it started. Nothing was published.`);
      return;
    }
    await sleep(20000);
  }
}
