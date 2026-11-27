import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/ui/swipe_actions.dart';

/// Where a row dragged sideways comes to (Matt, 2026-11-14: "add swiping to archive, further drag to delete, drag the
/// other direction to pin, add haptic detents for each"). The dragging itself, with its ticks, is driven in
/// test/screens_test.dart, where the list is drawn.
void main() {
  test('a little to the left is nothing, more is archive, far is delete', () {
    expect(SwipeActions.stageFor(-20, 400), SwipeStage.none);
    expect(SwipeActions.stageFor(-SwipeActions.archiveAt, 400), SwipeStage.archive);
    expect(SwipeActions.stageFor(-150, 400), SwipeStage.archive);
    expect(SwipeActions.stageFor(-SwipeActions.deleteAt(400), 400), SwipeStage.delete);
    expect(SwipeActions.stageFor(-400, 400), SwipeStage.delete);
  });

  test('to the right is pin, and never delete however far', () {
    expect(SwipeActions.stageFor(40, 400), SwipeStage.none);
    expect(SwipeActions.stageFor(SwipeActions.pinAt, 400), SwipeStage.pin);
    expect(SwipeActions.stageFor(400, 400), SwipeStage.pin);
  });

  test('delete is well past archive on a narrow screen and a wide one', () {
    for (final width in [320.0, 412.0, 900.0]) {
      expect(SwipeActions.deleteAt(width), greaterThan(SwipeActions.archiveAt * 2.5), reason: '$width');
      expect(SwipeActions.deleteAt(width), lessThan(width), reason: 'a row $width wide can be dragged that far');
    }
  });
}
