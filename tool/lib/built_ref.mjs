import { spawnSync } from 'node:child_process';

/**
 * A GitHub runner builds what GitHub has at a branch, not what is on this computer. Uplink 0.12.24 and
 * 0.12.25 went out for Windows and Linux as 0.12.23's code under their numbers: each was released from the release
 * checkout while main, which the runners build, had not been given it (found 2026-11-24, as 0.12.26 was released,
 * in `gh run list`: both builds were of main at the 0.12.23 merge).
 *
 * Says why not where `ref` on GitHub does not hold exactly this checkout's app (everything under `root`, as it is
 * committed here); null where it does. Asked by tool/release-windows.mjs and tool/release-linux.mjs before they start
 * a build, so a release that main has not been given is refused, with what to do, in place of going out wrong.
 */
export function refLacksRelease(root, ref) {
  const git = (args) => spawnSync('git', ['-C', root, ...args], { encoding: 'utf8' });
  const fetched = git(['fetch', '--quiet', 'origin', ref]);
  if (fetched.status !== 0) return `GitHub's ${ref} could not be read (${(fetched.stderr || '').trim().split('\n').pop() || 'git fetch failed'}).`;
  const same = git(['diff', '--quiet', 'FETCH_HEAD', 'HEAD', '--', '.']);
  if (same.status === 0) return null;
  if (same.status === 1) {
    return `GitHub's ${ref} is not this release: what is committed here is not what ${ref} holds. Merge this release's commit into ${ref} and push it first, or name the branch that has it with --ref.`;
  }
  return `This checkout could not be compared with GitHub's ${ref}.`;
}
