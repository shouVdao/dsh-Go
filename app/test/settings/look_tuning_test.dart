// 设置 › 主题 › 材质与文字: the glass opacity / blur sliders and the text ink.
//
//   flutter test test/settings/look_tuning_test.dart

import 'package:dsh_app/app.dart';
import 'package:dsh_app/state/appearance_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/settings/appearance/appearance_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';

class _NoWallpaper extends DynamicColorChannel {
  const _NoWallpaper();

  @override
  Future<Color?> wallpaperAccent() async => null;
}

/// The real app shell around the page, tall enough that every group is laid out.
Future<ProviderContainer> _pumpApp(WidgetTester tester) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(390 * 2, 2000 * 2);
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
      dynamicColorChannelProvider.overrideWithValue(const _NoWallpaper()),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const DshApp(home: AppearancePage())),
  );
  await tester.pumpAndSettle();
  return container;
}

ThemeData _theme(WidgetTester tester) => Theme.of(tester.element(find.byType(AppearancePage)));

DshSurfaces _surfaces(WidgetTester tester) => DshSurfaces.of(tester.element(find.byType(AppearancePage)));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the sliders start at the theme and store when released', (tester) async {
    final container = await _pumpApp(tester);
    expect(find.text('不透明度'), findsOneWidget);
    expect(find.text('模糊'), findsOneWidget);
    expect(find.text('字体颜色'), findsOneWidget);
    final appearance = container.read(appearanceProvider);
    expect(appearance.glassOpacity, 1);
    expect(appearance.glassBlur, 1);

    // Released, not dragged: the commit lands on onChangeEnd only.
    await tester.drag(find.byType(Slider).first, const Offset(-60, 0));
    await tester.pumpAndSettle();
    final opacity = container.read(appearanceProvider).glassOpacity;
    expect(opacity, lessThan(1));
    expect(opacity, greaterThanOrEqualTo(AppearanceSettings.minOpacity));
    expect((await SharedPreferences.getInstance()).getDouble('appearance.glass_opacity'), opacity);
    expect(_surfaces(tester).card.fill.a, closeTo(0.62 * opacity, 0.01));
  });

  testWidgets('stored sliders come back at launch', (tester) async {
    SharedPreferences.setMockInitialValues({
      'appearance.glass_opacity': 0.4,
      'appearance.glass_blur': 0.25,
      'appearance.font_color': 0xFF334455,
    });
    final container = await _pumpApp(tester);
    final appearance = container.read(appearanceProvider);
    expect(appearance.glassOpacity, 0.4);
    expect(appearance.glassBlur, 0.25);
    expect(appearance.fontColor, 0xFF334455);
    expect(_surfaces(tester).blurAmount, 0.25);
    expect(_surfaces(tester).card.fill.a, closeTo(0.62 * 0.4, 0.01));
    final look = Oklch.fromColor(const Color(0xFF334455));
    expect(
      _theme(tester).colorScheme.onSurface,
      textInkFor(hue: look.h, chroma: look.c, brightness: _theme(tester).brightness),
    );
  });

  test('the picked ink keeps its hue and stays readable in both modes', () {
    const pick = Color(0xFF7A4FBF);
    final hue = Oklch.fromColor(pick).h;
    for (final theme in [buildLightTheme(fontColor: pick), buildDarkTheme(fontColor: pick)]) {
      final ink = theme.colorScheme.onSurface;
      expect(Oklch.fromColor(ink).h, closeTo(hue, 8));
      expect(theme.textTheme.bodyMedium?.color, ink);
      expect(contrastRatio(ink, theme.colorScheme.surface), greaterThan(4.5));
      // Secondary text keeps the palette, so hierarchy does not collapse.
      expect(theme.colorScheme.onSurfaceVariant, isNot(ink));
    }
    expect(buildLightTheme().colorScheme.onSurface, isNot(textInkFor(hue: hue, chroma: 0.08, brightness: Brightness.light)));
  });

  test('opacity scales every glass fill; the blur amount rides along', () {
    final base = DshSurfaces.light(AppAccent.mist);
    final half = DshSurfaces.light(AppAccent.mist, opacity: 0.5, blurAmount: 0);
    expect(base.blurAmount, 1);
    expect(half.blurAmount, 0);
    for (final pair in [(base.chrome, half.chrome), (base.sheet, half.sheet), (base.card, half.card), (base.pill, half.pill)]) {
      expect(pair.$2.fill.a, closeTo(pair.$1.fill.a * 0.5, 0.01));
      expect(pair.$2.fallbackFill.a, closeTo(pair.$1.fallbackFill.a * 0.5, 0.01));
      expect(pair.$2.blurSigma, pair.$1.blurSigma);
    }
  });

  testWidgets('zero blur keeps the glass fill and drops the filter', (tester) async {
    Future<void> pump(double amount) => tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(glassBlurAmount: amount),
        home: const Scaffold(
          body: Center(child: GlassSurface(tier: GlassTier.chrome, child: SizedBox.square(dimension: 80))),
        ),
      ),
    );

    await pump(0);
    expect(find.byType(BackdropFilter), findsNothing);

    await pump(1);
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  testWidgets('an ink pick tints the body text and can go back to the theme', (tester) async {
    final container = await _pumpApp(tester);
    final before = _theme(tester).colorScheme.onSurface;

    await tester.tap(find.bySemanticsLabel('珊瑚'));
    await tester.pumpAndSettle();
    final pick = container.read(appearanceProvider).fontColor;
    expect(pick, isNotNull);
    expect(_theme(tester).colorScheme.onSurface, isNot(before));
    expect(Oklch.fromColor(_theme(tester).colorScheme.onSurface).h, closeTo(22, 8));

    await tester.tap(find.bySemanticsLabel('跟随主题'));
    await tester.pumpAndSettle();
    expect(container.read(appearanceProvider).fontColor, isNull);
    expect(_theme(tester).colorScheme.onSurface, before);
    expect((await SharedPreferences.getInstance()).getInt('appearance.font_color'), isNull);
  });
}
