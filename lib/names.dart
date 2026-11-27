/// A person's name as it is shown and said, with no "@" in front (Matt, 2026-11-19: "Some users have @ prefixes and
/// others don't find out what's causing this and normalize things so we don't have the @ prefix before names on the
/// platform"): someone with no display name went by "@" and their username, said as their name in spaces, calls,
/// circles and Files, while someone with one went by it plainly. A name heard from a build from before is put right
/// here too. An "@" stays where a handle is shown as one (Settings › Me, an address), not where a name is.
String bareName(String name) => name.trim().replaceFirst(RegExp(r'^@+'), '').trim();
