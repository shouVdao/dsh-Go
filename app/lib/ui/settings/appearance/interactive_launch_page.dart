// 设置 › 主题 › 启动画面 › 互动: the interactive launch screen's look, words, backgrounds, pace,
// exit and how often it plays; a preview at the bottom.
//
//   外观            ( 跟随系统 | 浅色 | 深色 )
//   强调色                     ● ● ● ● ●
//   文字      标题 · 副标题 · 昵称 · 编号 · 两个按钮 · 欢迎语     (empty: the default)
//   背景      开始 · 确认 · 展开: none, a picture or a video (muted)
//   节奏      等待时 ( 循环 | 停在最后一帧 ) · 视频速度 · 特效速度
//   转场      ( 淡出 | 光晕 | 色散 )
//   频率      ( 每次冷启动 | 每天第一次 )
//   预览                                      ›

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../launch/custom_launch.dart';
import '../../../launch/interactive_launch.dart';
import '../../../state/app_info.dart';
import '../../../state/launch_screen_state.dart';
import '../../common/brief_notice.dart';
import '../../common/pressable.dart';
import '../../launch/launch_preview_page.dart';
import '../../shell/page_frame.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../../workspace/text_prompt.dart';
import '../settings_widgets.dart';
import 'launch_screen_section.dart' show launchProblemNotice;

Future<void> showInteractiveLaunchPage(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const InteractiveLaunchPage()));

class InteractiveLaunchPage extends ConsumerStatefulWidget {
  const InteractiveLaunchPage({super.key});

  @override
  ConsumerState<InteractiveLaunchPage> createState() => _InteractiveLaunchPageState();
}

class _InteractiveLaunchPageState extends ConsumerState<InteractiveLaunchPage> {
  /// The scene whose background is being picked (one picker at a time).
  InteractiveScene? _picking;

  InteractiveLaunchController get _notifier => ref.read(interactiveLaunchProvider.notifier);

  void _update(InteractiveLaunch Function(InteractiveLaunch) change) => unawaited(_notifier.change(change));

  Future<void> _editText(String field, String title, String fallback) async {
    final config = ref.read(interactiveLaunchProvider).value;
    if (config == null) return;
    final text = await showTextPrompt(
      context,
      title: title,
      initial: config.texts[field] ?? '',
      hint: fallback,
      caption: context.l10n.launchShowTextCaption,
      maxLength: InteractiveTexts.limits[field],
    );
    if (text == null) return;
    _update((c) => c.copyWith(texts: c.texts.withField(field, text)));
  }

  Future<void> _chooseBackground(InteractiveScene scene) async {
    if (_picking != null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final l10n = context.l10n;
    setState(() => _picking = scene);
    try {
      final problem = await _notifier.chooseBackground(scene);
      if (problem != null) {
        final text = launchProblemNotice(l10n, problem);
        if (text != null) messenger?.showBriefNotice(text);
      }
    } finally {
      if (mounted) setState(() => _picking = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final config = ref.watch(interactiveLaunchProvider).value ?? const InteractiveLaunch();
    final texts = config.texts;
    final tertiary = DshColors.of(context).textTertiary;

    Widget textTile(String field, String title, String fallback) {
      final own = texts[field];
      return SettingsTile(
        key: ValueKey('interactive-text-$field'),
        title: title,
        value: Text(
          own ?? fallback,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: own == null ? TextStyle(color: tertiary) : null,
        ),
        onTap: () => unawaited(_editText(field, title, fallback)),
      );
    }

    Widget sceneTile(InteractiveScene scene, String title) {
      final media = config.backgrounds[scene];
      final picking = _picking == scene;
      return SettingsTile(
        key: ValueKey('interactive-scene-${scene.name}'),
        title: title,
        value: Text(switch (media?.kind) {
          null => l10n.launchShowBackgroundNone,
          LaunchMediaKind.video => l10n.launchShowBackgroundVideo,
          _ => l10n.launchShowBackgroundImage,
        }),
        trailing: media == null || picking
            ? null
            : Semantics(
                button: true,
                label: l10n.launchShowBackgroundRemove,
                excludeSemantics: true,
                child: Pressable(
                  onTap: () => unawaited(_notifier.clearBackground(scene)),
                  child: SizedBox.square(
                    dimension: 48,
                    child: Icon(AppIcons.close, size: 18, color: tertiary),
                  ),
                ),
              ),
        onTap: _picking == null ? () => unawaited(_chooseBackground(scene)) : null,
      );
    }

    String speed(double v) => '${v.toStringAsFixed(v * 10 % 5 == 0 ? 1 : 2)}×';
    // 0.5–2 in 0.25 steps on the 0–1 slider.
    const span = InteractiveLaunch.maxSpeed - InteractiveLaunch.minSpeed;
    double toSlider(double v) => (v - InteractiveLaunch.minSpeed) / span;
    double fromSlider(double v) => InteractiveLaunch.minSpeed + v * span;

    return AppPage.list(
      title: l10n.launchShowEdit,
      children: [
        SettingsSection(
          title: l10n.launchShowLook,
          children: [
            SettingsSegmentTile<InteractiveLook>(
              title: l10n.launchShowLook,
              segments: [
                PillSegment(InteractiveLook.auto, l10n.launchShowLookAuto),
                PillSegment(InteractiveLook.light, l10n.launchShowLookLight),
                PillSegment(InteractiveLook.dark, l10n.launchShowLookDark),
              ],
              selected: config.look,
              onChanged: (look) => _update((c) => c.copyWith(look: look)),
            ),
            SettingsTile(
              title: l10n.launchShowAccent,
              value: _AccentSwatches(
                selected: config.accent,
                onChanged: (accent) => _update((c) => c.copyWith(accent: accent)),
              ),
            ),
          ],
        ),
        SettingsSection(
          title: l10n.launchShowTexts,
          footer: Text(l10n.launchShowTextsFooter),
          children: [
            textTile('title', l10n.launchShowTextTitle, AppInfo.name.toUpperCase()),
            textTile('subtitle', l10n.launchShowTextSubtitle, l10n.launchShowSubtitle),
            textTile('nickname', l10n.launchShowTextNickname, l10n.launchShowNickname),
            textTile('number', l10n.launchShowTextNumber, '0001'),
            textTile('start', l10n.launchShowTextStart, l10n.launchShowStart),
            textTile('confirm', l10n.launchShowTextConfirm, l10n.launchShowConfirm),
            textTile('welcome', l10n.launchShowTextWelcome, l10n.launchShowWelcome),
          ],
        ),
        SettingsSection(
          title: l10n.launchShowBackgrounds,
          footer: Text(l10n.launchShowBackgroundsFooter),
          children: [
            sceneTile(InteractiveScene.start, l10n.launchShowSceneStart),
            sceneTile(InteractiveScene.confirm, l10n.launchShowSceneConfirm),
            sceneTile(InteractiveScene.scan, l10n.launchShowSceneScan),
          ],
        ),
        SettingsSection(
          title: l10n.launchShowPace,
          children: [
            SettingsSegmentTile<InteractiveWait>(
              title: l10n.launchShowWait,
              segments: [
                PillSegment(InteractiveWait.loop, l10n.launchShowWaitLoop),
                PillSegment(InteractiveWait.hold, l10n.launchShowWaitHold),
              ],
              selected: config.wait,
              onChanged: (wait) => _update((c) => c.copyWith(wait: wait)),
            ),
            _SpeedTile(
              key: const ValueKey('interactive-video-speed'),
              title: l10n.launchShowVideoSpeed,
              value: config.videoSpeed,
              toSlider: toSlider,
              fromSlider: fromSlider,
              label: speed,
              onChanged: (v) => _update((c) => c.copyWith(videoSpeed: v)),
            ),
            _SpeedTile(
              key: const ValueKey('interactive-effect-speed'),
              title: l10n.launchShowEffectSpeed,
              value: config.effectSpeed,
              toSlider: toSlider,
              fromSlider: fromSlider,
              label: speed,
              onChanged: (v) => _update((c) => c.copyWith(effectSpeed: v)),
            ),
          ],
        ),
        SettingsSection(
          title: l10n.launchShowExit,
          children: [
            SettingsSegmentTile<InteractiveTransition>(
              title: l10n.launchShowTransition,
              segments: [
                PillSegment(InteractiveTransition.fade, l10n.launchShowTransitionFade),
                PillSegment(InteractiveTransition.bloom, l10n.launchShowTransitionBloom),
                PillSegment(InteractiveTransition.chroma, l10n.launchShowTransitionChroma),
              ],
              selected: config.transition,
              onChanged: (t) => _update((c) => c.copyWith(transition: t)),
            ),
            SettingsSegmentTile<InteractiveFrequency>(
              title: l10n.launchShowFrequency,
              segments: [
                PillSegment(InteractiveFrequency.always, l10n.launchShowFrequencyAlways),
                PillSegment(InteractiveFrequency.daily, l10n.launchShowFrequencyDaily),
              ],
              selected: config.frequency,
              onChanged: (f) => _update((c) => c.copyWith(frequency: f)),
            ),
          ],
        ),
        SettingsSection(
          footer: Text(l10n.launchShowPreviewFooter),
          children: [
            SettingsTile(
              key: const ValueKey('interactive-preview'),
              title: l10n.launchPreview,
              onTap: () => unawaited(showLaunchPreview(context, interactive: config)),
            ),
          ],
        ),
      ],
    );
  }
}

/// A speed slider that keeps its own value while dragging and saves on release.
class _SpeedTile extends StatefulWidget {
  const _SpeedTile({
    super.key,
    required this.title,
    required this.value,
    required this.toSlider,
    required this.fromSlider,
    required this.label,
    required this.onChanged,
  });

  final String title;
  final double value;
  final double Function(double) toSlider;
  final double Function(double) fromSlider;
  final String Function(double) label;
  final ValueChanged<double> onChanged;

  @override
  State<_SpeedTile> createState() => _SpeedTileState();
}

class _SpeedTileState extends State<_SpeedTile> {
  double? _dragging;

  @override
  Widget build(BuildContext context) => SettingsSliderTile(
    title: widget.title,
    value: _dragging ?? widget.toSlider(widget.value),
    steps: 6,
    label: (v) => widget.label(widget.fromSlider(v)),
    onChanged: (v) => setState(() => _dragging = v),
    onChangeEnd: (v) {
      setState(() => _dragging = null);
      widget.onChanged(widget.fromSlider(v));
    },
  );
}

/// The accent presets as small discs; the chosen one ringed.
class _AccentSwatches extends StatelessWidget {
  const _AccentSwatches({required this.selected, required this.onChanged});

  final int selected;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [
        for (final (i, accent) in InteractiveLaunch.accents.indexed)
          Semantics(
            button: true,
            selected: accent == selected,
            inMutuallyExclusiveGroup: true,
            label: '${context.l10n.launchShowAccent} ${i + 1}',
            excludeSemantics: true,
            child: Pressable(
              key: ValueKey('interactive-accent-$i'),
              onTap: () => onChanged(accent),
              child: SizedBox.square(
                dimension: 30,
                child: Center(
                  child: Container(
                    width: 28,
                    height: 28,
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: accent == selected ? scheme.primary : Colors.transparent, width: 2),
                    ),
                    child: DecoratedBox(decoration: BoxDecoration(color: Color(accent), shape: BoxShape.circle)),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
