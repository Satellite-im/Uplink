import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/friends/buddies.dart';

/// Friends shown once each (Matt, 2026-11-19: "my friends are duplicated I have two copies of all my friends on the
/// app"): the same username under two ids is one friend in a list, the newest standing for them.
void main() {
  test('one per username, the newest of each, in the list\'s order, every id still kept', () {
    const kevinOld = Buddy(username: 'kevin', id: 'k1', key: 'a', name: 'Kevin', at: 1);
    const jerbo = Buddy(username: 'jerbo', id: 'j1', key: 'b', at: 5);
    const kevinNew = Buddy(username: 'Kevin', id: 'k2', key: 'c', name: 'Kevin Moss', at: 9);
    final once = Buddies.onePerUsername(const [kevinOld, jerbo, kevinNew]);
    expect(once.map((b) => b.id), ['j1', 'k2'], reason: 'Kevin once, his newest; Jerbo as he is');
    expect(Buddies.onePerUsername(const []), isEmpty);
    expect(Buddies.onePerUsername(const [jerbo]), [jerbo]);
  });
}
