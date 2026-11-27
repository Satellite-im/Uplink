import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/plugins/auto_leveler.dart';
import 'package:ghost_messaging/plugins/plugin.dart';
import 'package:ghost_messaging/plugins/registry.dart';
import 'package:ghost_messaging/voice/leveler.dart';

double db(double x) => 20 * math.log(x) / math.ln10;

/// The auto leveler (lib/voice/leveler.dart; Matt, 2026-11-20: "build the auto leveler plugin that levels everyone's
/// voice levels").
void main() {
  /// [n] readings (about 150 ms each) of everyone talking at [levels], with a breath of silence every fourth.
  Map<String, double> talk(LevelerCore core, Map<String, double> levels, int n) {
    var g = core.gains;
    for (var i = 0; i < n; i++) {
      g = core.feed(i % 4 == 3 ? {for (final k in levels.keys) k: 0.0} : levels);
    }
    return g;
  }

  test('a quiet voice is brought up and a loud one down, until they are heard at about the same loudness', () {
    final core = LevelerCore();
    final g = talk(core, {'quiet': 0.04, 'loud': 0.5, 'me': 0.9}, 200);
    expect(g['quiet']!, greaterThan(1.5));
    expect(g['loud']!, lessThan(0.6));
    final heardQuiet = db(0.04 * g['quiet']!), heardLoud = db(0.5 * g['loud']!);
    // 0.04 is -28 dB and 0.5 is -6 dB, 22 dB apart. The quiet one comes up to the target (-22 dB); the loud one comes
    // down the most it may (9 dB): under 8 dB apart after.
    expect(heardQuiet, closeTo(-22, 0.5));
    expect((heardQuiet - heardLoud).abs(), lessThan(8), reason: 'before: ${(db(0.04) - db(0.5)).abs().toStringAsFixed(1)} dB apart');
    expect(g.containsKey('me'), isFalse, reason: 'this device is never levelled');
  });

  test('it moves slowly: a shout or a laugh does not swing anyone', () {
    final core = LevelerCore();
    talk(core, {'a': 0.08}, 100);
    final settled = core.gains['a']!;
    core.feed({'a': 0.9});
    expect((core.gains['a']! - settled).abs() / settled, lessThan(0.1));
  });

  test('silence teaches it nothing, and nobody is moved past the most it may', () {
    final core = LevelerCore(mostUp: 6);
    talk(core, {'silent': 0.0}, 50);
    expect(core.gains, isEmpty, reason: 'nothing heard, nothing done');
    final g = talk(core, {'whisper': 0.031}, 300);
    expect(db(g['whisper']!), closeTo(6, 0.3), reason: 'it would want 8 dB; it may give 6');
    final shout = talk(LevelerCore(), {'shout': 1.0}, 300);
    expect(db(shout['shout']!), closeTo(-9, 0.3));
  });

  test('someone who leaves is forgotten', () {
    final core = LevelerCore();
    talk(core, {'a': 0.1, 'b': 0.1}, 40);
    core.feed({'a': 0.1});
    expect(core.gains.keys, ['a']);
  });

  test('turned off in the middle of a call, everyone is put back at once', () {
    final lv = AutoLeveler.instance;
    final levels = ValueNotifier<Map<String, double>>(const {});
    var on = true;
    lv.isOn = () => on;
    lv.attachForTest(levels);
    addTearDown(() {
      lv.attachForTest(null);
      lv.isOn = AutoLevelerPlugin.onInCall;
    });
    for (var i = 0; i < 60; i++) {
      levels.value = {'a': i.isEven ? 0.04 : 0.041};
    }
    expect(lv.dbOf('a'), greaterThan(3));
    expect(lv.active, isTrue);
    on = false;
    levels.value = {'a': 0.04};
    expect(lv.dbOf('a'), 0);
    expect(lv.active, isFalse);
  });

  test('the player is told a gain all the way to where it settles, not left behind as the steps grow small', () {
    final lv = AutoLeveler.instance;
    final levels = ValueNotifier<Map<String, double>>(const {});
    final told = <double>[];
    lv.isOn = () => true;
    lv.attachForTest(levels, told: (id, gain) => told.add(gain));
    addTearDown(() {
      lv.attachForTest(null);
      lv.isOn = AutoLevelerPlugin.onInCall;
    });
    for (var i = 0; i < 400; i++) {
      levels.value = {'a': i.isEven ? 0.04 : 0.041};
    }
    final settled = lv.core.gains['a']!;
    expect(settled, greaterThan(1.8));
    // Within the step that is worth telling (0.03) of where the gain is; before, the last told was 0.2 short.
    expect((settled - told.last).abs(), lessThan(0.03), reason: 'told ${told.last}, settled at $settled');
    expect(told.length, lessThan(60), reason: 'and still not told at every reading');
  });

  test('a plugin for a device or a whole circle, off until turned on', () {
    final p = shippedPlugins.whereType<AutoLevelerPlugin>().single;
    expect(p.id, 'autoleveler');
    expect(() => PluginRegistry.instance.plugins, returnsNormally, reason: 'the registry takes its id (lower-case letters and digits)');
    expect(p.onByDefault, isFalse);
    expect(p.scopes, {PluginScope.device, PluginScope.circle});
  });
}
