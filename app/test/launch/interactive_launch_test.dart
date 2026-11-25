// 互动启动画面的设置: what is stored reads back the same, a newer or broken record is ignored
// (the launch falls back), loose values are cut to their limits, and 每天第一次 plays once a day.

import 'dart:convert';

import 'package:dsh_app/launch/interactive_launch.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('round-trips through prefs', () async {
    final prefs = await SharedPreferences.getInstance();
    const config = InteractiveLaunch(
      on: true,
      look: InteractiveLook.dark,
      accent: 0xFF2F80ED,
      texts: InteractiveTexts(nickname: '小明', number: '0087', start: '进入'),
      wait: InteractiveWait.hold,
      videoSpeed: 1.5,
      effectSpeed: 0.75,
      transition: InteractiveTransition.bloom,
      frequency: InteractiveFrequency.daily,
    );
    await InteractiveLaunch.save(config, prefs);
    expect(await InteractiveLaunch.load(prefs), config);
  });

  test('a newer version or a broken record reads as none', () async {
    expect(InteractiveLaunch.fromJson({'version': InteractiveLaunch.version + 1, 'on': true}), isNull);
    expect(InteractiveLaunch.fromJson({'on': true}), isNull);
    expect(InteractiveLaunch.fromJson('x'), isNull);
    SharedPreferences.setMockInitialValues({InteractiveLaunch.prefsKey: '{not json'});
    expect(await InteractiveLaunch.load(), isNull);
  });

  test('loose values are clamped, cut and defaulted', () {
    final config = InteractiveLaunch.fromJson({
      'version': 1,
      'on': true,
      'look': 'neon',
      'accent': 0x123456,
      'texts': {'nickname': '  ${'长' * 40}\n ', 'title': '', 'number': 42},
      'videoSpeed': 9,
      'effectSpeed': double.nan,
      'transition': 'warp',
      'backgrounds': {
        'start': {'kind': 'animation', 'path': '/a.gif', 'width': 10, 'height': 10},
      },
    })!;
    expect(config.look, InteractiveLook.auto);
    expect(config.accent, 0xFF123456, reason: 'always opaque');
    expect(config.texts.nickname!.runes.length, InteractiveTexts.limits['nickname']);
    expect(config.texts.title, isNull, reason: 'empty is the default');
    expect(config.texts.number, isNull);
    expect(config.videoSpeed, InteractiveLaunch.maxSpeed);
    expect(config.effectSpeed, 1);
    expect(config.transition, InteractiveTransition.chroma);
    expect(config.backgrounds, isEmpty, reason: 'an animation is never a scene background');
  });

  test('a background whose file is gone is dropped on load', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      InteractiveLaunch.prefsKey,
      jsonEncode({
        'version': 1,
        'on': true,
        'backgrounds': {
          'scan': {'kind': 'image', 'path': '/nowhere/custom-1.png', 'width': 100, 'height': 200},
        },
      }),
    );
    final config = await InteractiveLaunch.load(prefs);
    expect(config!.on, isTrue);
    expect(config.backgrounds, isEmpty);
  });

  test('texts: one line, trimmed; withField empties back to the default', () {
    const texts = InteractiveTexts(title: 'DSH');
    expect(texts.withField('title', 'a\nb').title, 'a b');
    expect(texts.withField('title', '   ').title, isNull);
    expect(texts.withField('welcome', 'hi').title, 'DSH');
  });

  group('takeTurn', () {
    test('off never plays; always plays every time without recording', () async {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime(2026, 11, 25, 9);
      expect(await const InteractiveLaunch().takeTurn(prefs, now), isFalse);
      const always = InteractiveLaunch(on: true);
      expect(await always.takeTurn(prefs, now), isTrue);
      expect(await always.takeTurn(prefs, now), isTrue);
      expect(prefs.getString(InteractiveLaunch.dayKey), isNull);
    });

    test('daily plays on the first cold start of each day', () async {
      final prefs = await SharedPreferences.getInstance();
      const daily = InteractiveLaunch(on: true, frequency: InteractiveFrequency.daily);
      expect(await daily.takeTurn(prefs, DateTime(2026, 11, 25, 8)), isTrue);
      expect(await daily.takeTurn(prefs, DateTime(2026, 11, 25, 23, 59)), isFalse);
      expect(await daily.takeTurn(prefs, DateTime(2026, 11, 26, 0, 1)), isTrue);
    });
  });
}
