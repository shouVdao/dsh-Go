// 互动启动画面 in the overlay: it holds the launch screen though the app is ready, the two
// buttons take it through, a tap elsewhere does nothing, 跳过 and back end it, the onboarding
// ends it, and both looks lay out on a phone and in landscape.

import 'package:dsh_app/launch/interactive_launch.dart';
import 'package:dsh_app/launch/interactive_show.dart';
import 'package:dsh_app/launch/launch_state.dart';
import 'package:dsh_app/ui/launch/interactive_launch_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const _config = InteractiveLaunch(on: true, texts: InteractiveTexts(nickname: '一个很长很长很长很长很长的昵称'));

/// [seconds] of 50 ms frames (the show takes at most 100 ms a frame).
Future<void> _run(WidgetTester tester, double seconds) async {
  for (var i = 0; i < (seconds * 20).ceil(); i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late FakeLaunchChannel channel;
  setUp(() => channel = FakeLaunchChannel());

  Future<LaunchController> start(
    WidgetTester tester, {
    InteractiveLaunch config = _config,
    bool dark = false,
    bool reduceMotion = false,
  }) async {
    usePhone(tester);
    final controller = LaunchController(
      snapshot: snapshotFor(systemSplash: false, dark: dark),
      interactive: config,
      channel: channel,
      native: false,
    );
    await tester.pumpWidget(launchApp(controller, reduceMotion: reduceMotion));
    await tester.pump();
    return controller;
  }

  Future<void> toStart(WidgetTester tester) => _run(tester, InteractiveShow.brandLength + InteractiveShow.enter + 0.2);

  testWidgets('holds while the app is ready; the two buttons play it through', (tester) async {
    final c = await start(tester);
    c.ready();
    await toStart(tester);
    expect(c.phase, LaunchPhase.playing, reason: 'ready does not end the interactive show');
    expect(find.byKey(InteractiveLaunchView.startKey), findsOneWidget);

    // A tap away from the buttons does nothing (no tap-anywhere skip).
    await tester.tapAt(const Offset(30, 600));
    await _run(tester, 2);
    expect(c.phase, LaunchPhase.playing);

    await tester.tap(find.byKey(InteractiveLaunchView.startKey));
    await _run(tester, InteractiveShow.exit + InteractiveShow.enter + 0.2);
    expect(find.byKey(InteractiveLaunchView.confirmKey).hitTestable(), findsOneWidget);
    expect(c.phase, LaunchPhase.playing);

    await tester.tap(find.byKey(InteractiveLaunchView.confirmKey));
    await _run(tester, InteractiveShow.exit + InteractiveShow.scanLength + InteractiveShow.welcomeLength + 0.3);
    expect(c.phase, isNot(LaunchPhase.playing));
    await _run(tester, 1);
    expect(c.phase, LaunchPhase.gone);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a double tap on start counts once', (tester) async {
    final c = await start(tester);
    c.ready();
    await toStart(tester);
    await tester.tap(find.byKey(InteractiveLaunchView.startKey));
    await tester.pump(const Duration(milliseconds: 30));
    await tester.tap(find.byKey(InteractiveLaunchView.startKey), warnIfMissed: false);
    await _run(tester, InteractiveShow.exit + InteractiveShow.enter + 0.2);
    // On the confirm scene, still waiting.
    expect(find.byKey(InteractiveLaunchView.confirmKey).hitTestable(), findsOneWidget);
    expect(c.phase, LaunchPhase.playing);
    c.skip();
    await _run(tester, 1);
  });

  testWidgets('跳过 ends it at once', (tester) async {
    final c = await start(tester);
    c.ready();
    await _run(tester, 1);
    expect(find.byKey(InteractiveLaunchView.skipKey), findsOneWidget);
    expect(tester.getSize(find.byKey(InteractiveLaunchView.skipKey)).height, greaterThanOrEqualTo(48));
    await tester.tap(find.byKey(InteractiveLaunchView.skipKey));
    await _run(tester, 1);
    expect(c.phase, LaunchPhase.gone);
  });

  testWidgets('back ends it', (tester) async {
    final c = await start(tester);
    c.ready();
    await toStart(tester);
    await tester.binding.handlePopRoute();
    await _run(tester, 1);
    expect(c.phase, LaunchPhase.gone);
  });

  testWidgets('the onboarding as the first page ends it', (tester) async {
    final c = await start(tester);
    await _run(tester, 0.5);
    c.ready(guided: true);
    await _run(tester, 1);
    expect(c.phase, LaunchPhase.gone);
  });

  testWidgets('away from the app it stands still', (tester) async {
    final c = await start(tester);
    c.ready();
    await _run(tester, 0.5);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await _run(tester, 10);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _run(tester, 0.5);
    // 1 s of showing time: still the brand intro, the start button not there yet.
    expect(find.byKey(InteractiveLaunchView.startKey).hitTestable(), findsNothing);
    expect(c.phase, LaunchPhase.playing);
    c.skip();
    await _run(tester, 1);
  });

  testWidgets('reduced motion keeps the buttons', (tester) async {
    final c = await start(tester, reduceMotion: true);
    c.ready();
    await _run(tester, InteractiveShow.brandLengthReduced + InteractiveShow.enter + 0.2);
    expect(c.phase, LaunchPhase.playing);
    expect(find.byKey(InteractiveLaunchView.startKey).hitTestable(), findsOneWidget);
    c.skip();
    await _run(tester, 1);
  });

  for (final dark in [false, true]) {
    for (final landscape in [false, true]) {
      testWidgets('lays out (${dark ? 'dark' : 'light'}, ${landscape ? 'landscape' : 'portrait'}, large text)', (
        tester,
      ) async {
        usePhone(tester);
        if (landscape) tester.view.physicalSize = const Size(1688, 780);
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final controller = LaunchController(
          snapshot: snapshotFor(systemSplash: false),
          interactive: _config.copyWith(look: dark ? InteractiveLook.dark : InteractiveLook.light),
          channel: channel,
          native: false,
        );
        await tester.pumpWidget(launchApp(controller));
        await tester.pump();
        controller.ready();
        await toStart(tester);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(InteractiveLaunchView.startKey));
        await _run(tester, InteractiveShow.exit + InteractiveShow.enter + 0.2);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(InteractiveLaunchView.confirmKey));
        await _run(tester, InteractiveShow.exit + InteractiveShow.scanLength + 1.5);
        expect(tester.takeException(), isNull);
        await _run(tester, InteractiveShow.welcomeLength + 1);
        expect(controller.phase, LaunchPhase.gone);
      });
    }
  }
}
