// 互动启动画面的步骤: it advances on time and on the buttons only, takes one tap per scene,
// skips at any point, and stands still while the app is away (no catch-up).

import 'package:dsh_app/launch/interactive_show.dart';
import 'package:flutter_test/flutter_test.dart';

/// [seconds] of frames at 60 fps.
void run(InteractiveShow show, double seconds) {
  const frame = Duration(microseconds: 16667);
  for (var i = 0; i < (seconds * 60).ceil(); i++) {
    show.tick(frame);
  }
}

void main() {
  test('plays brand → start, waits there until the button', () {
    final show = InteractiveShow();
    expect(show.stage, ShowStage.brand);
    run(show, InteractiveShow.brandLength + 0.05);
    expect(show.stage, ShowStage.start);
    run(show, 30);
    expect(show.stage, ShowStage.start, reason: 'a waiting scene never moves on by itself');
    expect(show.waiting, isTrue);
  });

  test('start → confirm → scan → welcome → done with two presses', () {
    final show = InteractiveShow();
    run(show, InteractiveShow.brandLength + 0.05);
    run(show, InteractiveShow.acceptAfter);
    expect(show.press(ShowStage.start), isTrue);
    run(show, InteractiveShow.exit + 0.05);
    expect(show.stage, ShowStage.confirm);
    run(show, InteractiveShow.acceptAfter);
    expect(show.press(ShowStage.confirm), isTrue);
    run(show, InteractiveShow.exit + 0.05);
    expect(show.stage, ShowStage.scan);
    run(show, InteractiveShow.scanLength + 0.05);
    expect(show.stage, ShowStage.welcome);
    run(show, InteractiveShow.welcomeLength + 0.05);
    expect(show.done, isTrue);
  });

  test('rapid taps count once: the next scene ignores taps before its button is ready', () {
    final show = InteractiveShow();
    run(show, InteractiveShow.brandLength + 0.05);
    expect(show.press(ShowStage.start), isFalse, reason: 'the button is still coming in');
    run(show, InteractiveShow.acceptAfter);
    expect(show.press(ShowStage.start), isTrue);
    expect(show.press(ShowStage.start), isFalse);
    expect(show.press(ShowStage.confirm), isFalse, reason: 'not on the confirm scene yet');
    run(show, InteractiveShow.exit + 0.05);
    expect(show.stage, ShowStage.confirm);
    // A burst right after arriving: none of it counts.
    for (var i = 0; i < 5; i++) {
      expect(show.press(ShowStage.confirm), isFalse);
      run(show, 0.05);
    }
    expect(show.stage, ShowStage.confirm);
    expect(show.waiting, isTrue);
  });

  test('skip ends it from any stage', () {
    for (final at in [0.5, InteractiveShow.brandLength + 1]) {
      final show = InteractiveShow();
      run(show, at);
      show.skip();
      expect(show.done, isTrue);
      run(show, 1);
      expect(show.done, isTrue);
    }
  });

  test('stands still while paused; a long gap is one short step, not a jump', () {
    final show = InteractiveShow();
    run(show, 1);
    final t = show.t;
    show.paused = true;
    run(show, 10);
    expect(show.t, t);
    expect(show.stage, ShowStage.brand);
    show.paused = false;
    show.tick(const Duration(minutes: 5));
    expect(show.t, closeTo(t + InteractiveShow.maxStep, 1e-9));
    expect(show.stage, ShowStage.brand);
  });

  test('a press while paused does not count', () {
    final show = InteractiveShow();
    run(show, InteractiveShow.brandLength + 1);
    show.paused = true;
    expect(show.press(ShowStage.start), isFalse);
  });

  test('effects speed up after the confirm press', () {
    final show = InteractiveShow(effectSpeed: 1.5);
    run(show, InteractiveShow.brandLength + 1);
    expect(show.effectRate, closeTo(1.5, 0.01));
    expect(show.press(ShowStage.start), isTrue);
    run(show, InteractiveShow.exit + 1);
    expect(show.press(ShowStage.confirm), isTrue);
    run(show, 0.2);
    final early = show.effectRate;
    run(show, 1.5);
    expect(early, greaterThan(1.5));
    expect(show.effectRate, greaterThan(early));
    expect(show.effectRate, lessThanOrEqualTo(1.5 * InteractiveShow.boostTo));
  });

  test('a scan clip holds the scan until it ends (within its bounds)', () {
    final show = InteractiveShow(scanWaitsForMedia: true);
    run(show, InteractiveShow.brandLength + 1);
    show.press(ShowStage.start);
    run(show, InteractiveShow.exit + 1);
    show.press(ShowStage.confirm);
    run(show, InteractiveShow.exit + 0.05);
    expect(show.stage, ShowStage.scan);
    run(show, InteractiveShow.scanLength + 2);
    expect(show.stage, ShowStage.scan, reason: 'the clip is still playing');
    show.mediaEnded();
    run(show, 0.05);
    expect(show.stage, ShowStage.welcome);
  });

  test('reduced motion: short intro and welcome, frozen effects, buttons still wait', () {
    final show = InteractiveShow(reduced: true);
    run(show, InteractiveShow.brandLengthReduced + 0.05);
    expect(show.stage, ShowStage.start);
    expect(show.effectTime, 0);
    run(show, 10);
    expect(show.stage, ShowStage.start);
  });
}
