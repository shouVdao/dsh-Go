import 'package:dsh_app/state/balance_state.dart';
import 'package:dsh_app/state/pendant_options.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/chat/pendant/whale_pendant.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/harness.dart' show TestSettings, healthyBalance, testKey, testTheme;

/// Settings with a key and no storage behind them, plus the pendant setters
/// the widget really calls (the base ones await `_loaded`, which a stubbed
/// controller never sets). The sound starts off so a press never builds an
/// `AudioPlayer`, which a test host has no plugin for.
class _PendantSettings extends TestSettings {
  _PendantSettings([
    super.initial = const AppSettings(loaded: true, apiKey: testKey, pendantSound: pendantSoundOff),
  ]);

  @override
  Future<void> setPendant(bool value) async => state = state.copyWith(pendant: value);

  @override
  Future<void> setPendantPlace(double x, double y) async => state = state.copyWith(pendantX: x, pendantY: y);

  @override
  Future<void> setPendantLines(String lines) async => state = state.copyWith(pendantLines: lines);
}

void main() {
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BalanceController.now = () => DateTime(2026, 11, 17, 12);
    container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(_PendantSettings.new),
        balanceFetcherProvider.overrideWithValue((key) async => healthyBalance),
        accountWalletBalanceProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
  });

  tearDown(() => BalanceController.now = DateTime.now);

  /// The open bubble runs a one-second ticker, so nothing here can
  /// `pumpAndSettle`; the tree is torn down inside the test so its timers go.
  Future<void> pump(WidgetTester tester, {bool aside = false}) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: testTheme(Brightness.light),
          home: Scaffold(
            body: Align(alignment: Alignment.bottomCenter, child: WhalePendant(aside: aside)),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  testWidgets('collapsed it is only the character', (tester) async {
    await pump(tester);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('余额'), findsNothing);
    await close(tester);
  });

  testWidgets('a tap shows the balance for three seconds, then it goes away', (tester) async {
    await pump(tester);
    await tester.tap(find.byType(Image));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('余额'), findsOneWidget);
    expect(find.text('¥110.00'), findsOneWidget);
    // 12:00 Beijing on a Tuesday is already off-peak.
    expect(find.text('谷'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^\d{2}:\d{2}:\d{2}$')), findsOneWidget);

    // It never stays: three seconds later the whale is art again.
    await tester.pump(const Duration(milliseconds: 3200));
    expect(find.text('余额'), findsNothing);
    expect(find.text('¥110.00'), findsNothing);

    await close(tester);
  });

  testWidgets('tapping the balance bubble says a line in a bubble of its own', (tester) async {
    await pump(tester);
    await tester.tap(find.byType(Image));
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('¥110.00'));
    await tester.pump(const Duration(milliseconds: 400));

    // No title, no amount: just the line.
    expect(find.text('鲸娘说'), findsNothing);
    expect(find.text('余额'), findsNothing);
    expect(find.text('¥110.00'), findsNothing);
    final said = pendantDefaultLines.where((line) => find.text(line).evaluate().isNotEmpty);
    expect(said, hasLength(1));

    await close(tester);
  });

  testWidgets('tapping the character never says a line', (tester) async {
    await pump(tester);
    await tester.tap(find.byType(Image));
    await tester.pump(const Duration(milliseconds: 400));

    final said = pendantDefaultLines.where((line) => find.text(line).evaluate().isNotEmpty);
    expect(said, isEmpty);
    await close(tester);
  });

  testWidgets('a long press squeezes instead of offering a menu', (tester) async {
    await pump(tester);
    await tester.longPress(find.byType(Image));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('刷新余额'), findsNothing);
    expect(find.text('收起小鲸鱼'), findsNothing);
    expect(container.read(settingsProvider).pendant, isTrue);
    await close(tester);
  });

  testWidgets('dragging it to the other edge snaps it flush and turns it around', (tester) async {
    await pump(tester);
    // It docks on the left, away from the scroll-to-bottom button.
    expect(container.read(settingsProvider).pendantX, lessThan(0.5));

    await tester.drag(find.byType(Image), const Offset(1200, 0));
    await tester.pump(const Duration(milliseconds: 400));

    // Parked on the edge itself, not a few dp short of it.
    expect(container.read(settingsProvider).pendantX, 1.0);
    await close(tester);
  });

  testWidgets('the aside flag tucks it away while typing', (tester) async {
    await pump(tester, aside: true);
    final fade = tester.widget<AnimatedOpacity>(
      find.ancestor(of: find.byType(Image), matching: find.byType(AnimatedOpacity)).first,
    );
    expect(fade.opacity, 0);
    await close(tester);
  });
}
