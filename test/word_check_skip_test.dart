import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/account/account.dart';
import 'package:ghost_messaging/ui/account_screens.dart';

import 'support/space_call_harness.dart';

const _words = ['abandon', 'ability', 'able', 'about', 'above', 'absent', 'absorb', 'abstract', 'absurd', 'abuse', 'access', 'accident'];

/// Opens the words' check over a page, as the first page does once the account is made (lib/standalone/welcome.dart).
class _Opener extends StatefulWidget {
  const _Opener();
  @override
  State<_Opener> createState() => _OpenerState();
}

class _OpenerState extends State<_Opener> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => Navigator.of(context).push(PageRouteBuilder<void>(
          pageBuilder: (_, _, _) => const CreateAccountScreen(step: CreateStep.confirm, draft: AccountDraft(_words, '0x0000000000000000000000000000000000000000'), made: true),
        )));
  }

  @override
  Widget build(BuildContext context) => const Text('underneath');
}

/// Matt, 2026-11-20: "add a button to skip verifying the seed phrase". The check has a Skip, and after the first
/// page (the account made already) it closes the check and leaves the app underneath.
void main() {
  testWidgets('the words\' check can be skipped', (tester) async {
    final h = await SpaceHarness.load(tester);
    await h.shoot(tester, const _Opener(), 'word-check-skip');
    expect(find.byType(CreateAccountScreen), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('skip-word-check')), 200, scrollable: find.byType(Scrollable).last);
    await tester.tap(find.byKey(const ValueKey('skip-word-check')));
    await tester.pumpAndSettle();
    expect(find.byType(CreateAccountScreen), findsNothing);
    expect(find.text('underneath'), findsOneWidget);
  });
}
