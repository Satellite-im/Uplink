// /ghost link, /ghost unlink and /ghost status: what they answer, without discord.js (bot.js passes the interaction's
// subcommand, server and the asker's Manage Server permission in, and sends the answer back ephemerally).

/** The command as Discord is told of it (an application command's JSON). Permissions in Discord are per command,
 * not per subcommand, so all of /ghost is for Manage Server by default; a server can open it to others under
 * Server Settings › Integrations, and link/unlink still check Manage Server themselves. */
export const COMMAND = {
  name: 'ghost',
  description: 'Link this server to Uplink, so its voice channels show there as spaces.',
  type: 1,
  default_member_permissions: String(1 << 5), // ManageGuild (0x20)
  contexts: [0], // servers only
  integration_types: [0], // installed to a server
  options: [
    { type: 1, name: 'link', description: 'A one-time code to link this server in Uplink (Manage Server).' },
    { type: 1, name: 'unlink', description: 'Unlink every Uplink app linked to this server (Manage Server).' },
    { type: 1, name: 'status', description: 'How many Uplink links this server has.' },
  ],
};

const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;

/** The words a /ghost subcommand answers with, doing what it asks on the way: link makes a code, unlink revokes
 * the server's tokens and waiting codes, status counts its links. */
export function answer({ sub, guildId, canManage }, { codes, store }) {
  if (!guildId) return 'Use this in a server.';
  if ((sub === 'link' || sub === 'unlink') && !canManage) return 'Only members who can Manage Server can do that.';
  if (sub === 'link') {
    const code = codes.issue(guildId);
    return `Your code is ${code}. In Uplink tap New › Add a Discord server and enter it. It works once, for 10 minutes.`;
  }
  if (sub === 'unlink') {
    const n = store.revokeGuild(guildId);
    codes.dropGuild(guildId);
    return n === 0
      ? 'This server had no Uplink links. Any waiting codes are cancelled too.'
      : `Unlinked: ${plural(n, 'Uplink link was', 'Uplink links were')} revoked, and any waiting codes cancelled.`;
  }
  if (sub === 'status') {
    const n = store.countGuild(guildId);
    return n === 0 ? 'This server has no Uplink links yet. /ghost link makes a code.' : `This server has ${plural(n, 'Uplink link', 'Uplink links')}.`;
  }
  return 'Unknown command.';
}
