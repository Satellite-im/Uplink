import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/feedback/feedback_api.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart' show KeysSigner;

/// Share feedback against the relay that is really there (relay/lib/feedback.dart; Matt, 2026-11-19: "wire up notion
/// to create user feedback tickets"): a fresh install sends one report with a small screenshot, and the relay files it
/// in the Notion board. It makes a real ticket, titled as a test, to delete afterwards.
///
///     flutter test tool/net/live_feedback_test.dart --dart-define=HUB=wss://gogho.st/hub
const hub = String.fromEnvironment('HUB');

/// A 2x2 PNG.
const _png = 'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGPwj74KRAwQCgAn2gX9Gu6j8QAAAABJRU5ErkJggg==';

void main() {
  test('a report filed through $hub', () async {
    expect(hub, isNotEmpty, reason: 'say which: --dart-define=HUB=wss://…/hub');
    final keys = NetKeys.generate();
    final id = await sendFeedback(
      FeedbackReport(
        type: FeedbackType.other,
        title: 'Test report from setting up Share feedback (delete me)',
        text: 'Sent by tool/net/live_feedback_test.dart after the relay was deployed with feedback.dart, to check a ticket lands here with its screenshot.',
        platform: 'mac',
        version: 'test',
        shots: [FeedbackShot(name: 'test.png', mime: 'image/png', bytes: base64Decode(_png))],
      ),
      signer: KeysSigner(keys),
      hubUrl: hub,
    );
    debugPrint('filed as $id');
    expect(id, startsWith('GMFB-'));
  });
}
