import '../updates.dart';

/// What the Mac app says of its own updates in a line (lib/desktop/updates.dart), for its Settings. Over every page
/// it is the phone's own banner that says so (lib/ui/update_banner.dart, fed by remote.dart `updateState`).
String updateLine(MacUpdates u) {
  final version = u.release?.version ?? '';
  return switch (u.phase) {
    MacUpdatePhase.idle => u.checked == null ? 'Not looked for yet' : 'Up to date',
    MacUpdatePhase.checking => 'Looking for a newer version…',
    MacUpdatePhase.downloading => u.progress >= 1 ? 'Putting Uplink $version in place…' : 'Getting Uplink $version · ${(u.progress * 100).round()}%',
    MacUpdatePhase.ready => 'Uplink $version is ready',
    MacUpdatePhase.restarting => 'Restarting as Uplink $version…',
    MacUpdatePhase.manual => 'Uplink $version is out, and this copy can\'t update itself. ${u.problem ?? ''}'.trim(),
    MacUpdatePhase.failed => 'The update didn\'t come: ${u.problem ?? 'no reason given'}. It is tried again later.',
  };
}
