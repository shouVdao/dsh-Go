// 互动启动画面的画面：步骤在 lib/launch/interactive_show.dart，这里只画。
//
// 两套内置外观（浅色暖白、深色），版式取自参考的“深度求索”式启动演出：左上品牌块、四角
// 细线、中间准星和逐字出现的状态、底部步骤计数与进度条，最后是 WELCOME TO 和光晕 / 色散。
// 不用任何第三方标志或音频：品牌入场用 App 自己的图标。
//
// 只有“跳过”和每一幕自己的按钮接收点击（不是点任意处跳过）；返回键结束演出。App 去了后台
// 演出和视频都停住，回来接着放，不补播。减少动画：不转、不扫、不闪，按钮照旧。

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../l10n/l10n.dart';
import '../../launch/custom_launch.dart';
import '../../launch/interactive_launch.dart';
import '../../launch/interactive_show.dart';
import '../../launch/launch_media.dart';
import '../../state/app_info.dart';
import '../theme/theme.dart';
import 'launch_overlay.dart' show CustomLaunchView;

/// The colours of one built-in look.
@immutable
class InteractivePalette {
  const InteractivePalette._({
    required this.bg,
    required this.bg2,
    required this.ink,
    required this.inkSoft,
    required this.muted,
    required this.hair,
    required this.hairSoft,
    required this.boxBg,
    required this.boxInk,
    required this.highlight,
    required this.vignette,
    required this.watermark,
    required this.intro,
    required this.introInk,
    required this.scan,
    required this.sweep,
    required this.flare,
  });

  final Color bg;
  final Color bg2;
  final Color ink;
  final Color inkSoft;
  final Color muted;
  final Color hair;
  final Color hairSoft;
  final Color boxBg;
  final Color boxInk;
  final Color highlight;
  final Color vignette;
  final Color watermark;

  /// The brand intro's page and text.
  final Color intro;
  final Color introInk;
  final Color scan;
  final Color sweep;

  /// The welcome's bloom, streak and flash.
  final Color flare;

  /// 暖白。
  static const light = InteractivePalette._(
    bg: Color(0xFFE5E3DF),
    bg2: Color(0xFFECEAE6),
    ink: Color(0xFF0A0A0A),
    inkSoft: Color(0xFF3A3936),
    muted: Color(0xFF7A7873),
    hair: Color(0x290A0A0A),
    hairSoft: Color(0x120A0A0A),
    boxBg: Color(0xFF0A0A0A),
    boxInk: Color(0xFFFFFFFF),
    highlight: Color(0xD9FFFFFF),
    vignette: Color(0x170A0A0A),
    watermark: Color(0x8CFFFFFF),
    intro: Color(0xFFF3F2EF),
    introInk: Color(0xFF0A0A0A),
    scan: Color(0x1C0A0A0A),
    sweep: Color(0xB3FFFFFF),
    flare: Color(0xFFFFFFFF),
  );

  /// 深色。
  static const dark = InteractivePalette._(
    bg: Color(0xFF0B0B0C),
    bg2: Color(0xFF131315),
    ink: Color(0xFFF2F1EE),
    inkSoft: Color(0xFFCFCECB),
    muted: Color(0xFF85847F),
    hair: Color(0x2EFFFFFF),
    hairSoft: Color(0x12FFFFFF),
    boxBg: Color(0xFFF2F1EE),
    boxInk: Color(0xFF0B0B0C),
    highlight: Color(0x0FFFFFFF),
    vignette: Color(0x6B000000),
    watermark: Color(0x09FFFFFF),
    intro: Color(0xFF000000),
    introInk: Color(0xFFFFFFFF),
    scan: Color(0x1FFFFFFF),
    sweep: Color(0x1FFFFFFF),
    flare: Color(0xFFFFFFFF),
  );
}

/// The interactive launch screen: one run of the show.
class InteractiveLaunchView extends StatefulWidget {
  const InteractiveLaunchView({
    super.key,
    required this.config,
    required this.dark,
    required this.reduced,
    required this.onDone,
    required this.onSkip,
    this.icon,
  });

  final InteractiveLaunch config;

  /// The dark look (else the light one).
  final bool dark;

  /// 减少动画.
  final bool reduced;

  /// The show has played to its end.
  final VoidCallback onDone;

  /// 跳过 or back.
  final VoidCallback onSkip;

  /// The app's icon (the brand intro's mark); a drawn one without.
  final ui.Image? icon;

  static const skipKey = ValueKey('interactive-skip');
  static const startKey = ValueKey('interactive-start');
  static const confirmKey = ValueKey('interactive-confirm');

  @override
  State<InteractiveLaunchView> createState() => _InteractiveLaunchViewState();
}

InteractiveScene? _sceneOf(ShowStage stage) => switch (stage) {
  ShowStage.brand => null,
  ShowStage.start => InteractiveScene.start,
  ShowStage.confirm => InteractiveScene.confirm,
  ShowStage.scan || ShowStage.welcome || ShowStage.done => InteractiveScene.scan,
};

double _ramp(double t, double from, double length) => ((t - from) / length).clamp(0.0, 1.0);
double _ease(double v) => Curves.easeOutCubic.transform(v);

class _InteractiveLaunchViewState extends State<InteractiveLaunchView>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final InteractiveShow _show = InteractiveShow(
    reduced: widget.reduced,
    effectSpeed: widget.config.effectSpeed,
    scanWaitsForMedia:
        !widget.reduced && widget.config.backgrounds[InteractiveScene.scan]?.kind == LaunchMediaKind.video,
  );
  late final Ticker _ticker = createTicker(_onTick);
  Duration _last = Duration.zero;

  /// Wall seconds since the view came (the button's pulse and the caret's blink).
  double _clock = 0;
  double _bar = 0;
  final _media = <InteractiveScene, LaunchMedia>{};
  InteractiveScene? _scene;
  bool _opened = false;
  bool _reported = false;
  bool _disposed = false;

  /// Where the show was when it was skipped: that frame stays while the launch screen fades.
  (ShowStage, double)? _frozen;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _show.addListener(_follow);
    unawaited(_ticker.start());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_opened) return;
    _opened = true;
    final screen = View.of(context).physicalSize;
    final config = widget.config;
    for (final MapEntry(key: scene, value: background) in config.backgrounds.entries) {
      unawaited(
        LaunchMedia.open(
          background,
          screen: screen,
          loop: scene != InteractiveScene.scan && config.wait == InteractiveWait.loop,
          speed: config.videoSpeed,
        ).then((media) {
          if (media == null) return;
          if (_disposed) return media.dispose();
          setState(() => _media[scene] = media);
          if (scene == _scene) _playScene();
        }),
      );
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _show.removeListener(_follow);
    _ticker.dispose();
    _show.dispose();
    // Nothing draws them after this frame.
    final media = [..._media.values];
    _media.clear();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      for (final m in media) {
        m.dispose();
      }
    });
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final dt = elapsed - _last;
    _last = elapsed;
    final seconds = math.min(dt.inMicroseconds / Duration.microsecondsPerSecond, InteractiveShow.maxStep);
    if (!_show.paused) {
      _clock += seconds;
      _bar = widget.reduced ? _show.progress : _bar + (_show.progress - _bar) * math.min(1, seconds * 6);
    }
    _show.tick(dt);
  }

  void _follow() {
    final scene = _sceneOf(_show.stage);
    if (scene != _scene) {
      _media[_scene]?.pause();
      _scene = scene;
      _playScene();
    }
    if (_show.done && !_reported) {
      _reported = true;
      widget.onDone();
    }
  }

  /// The current scene's clip plays (a still has nothing to play); with 减少动画 it stays on its
  /// first frame.
  void _playScene() {
    final scene = _scene;
    final media = _media[scene];
    if (media == null || widget.reduced) return;
    media.play(onDone: scene == InteractiveScene.scan ? _show.mediaEnded : null);
  }

  void _skip() {
    if (_show.done) return;
    _frozen = (_show.stage, _show.t);
    // Skipped, not played through: only [onSkip] reports it.
    _reported = true;
    _show.skip();
    widget.onSkip();
  }

  @override
  Future<bool> didPopRoute() async {
    if (_show.done) return false;
    _skip();
    return true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final away = state != AppLifecycleState.resumed;
    if (away == _show.paused) return;
    _show.paused = away;
    if (away) {
      _media[_scene]?.pause();
    } else {
      _media[_scene]?.resume();
    }
  }

  void _press(ShowStage at) => _show.press(at);

  @override
  Widget build(BuildContext context) {
    final query = MediaQuery.of(context);
    return MediaQuery(
      // Large fonts grow the words, not past the layout (it also scales down to fit).
      data: query.copyWith(textScaler: query.textScaler.clamp(maxScaleFactor: 1.3)),
      child: AnimatedBuilder(animation: _show, builder: (context, _) => _frame(context)),
    );
  }

  Widget _frame(BuildContext context) {
    final p = widget.dark ? InteractivePalette.dark : InteractivePalette.light;
    final l10n = context.l10n;
    final query = MediaQuery.of(context);
    final size = query.size;
    final pad = query.padding;
    final reduced = widget.reduced;
    final texts = widget.config.texts;
    final accent = widget.config.accentColor;
    final title = texts.title ?? AppInfo.name.toUpperCase();

    // What to draw: after a skip, the frame it was skipped on; after the end, the last one.
    final ShowStage stage;
    final double t;
    if (_show.done) {
      (stage, t) = _frozen ?? (ShowStage.welcome, _show.welcomeLengthNow);
    } else {
      (stage, t) = (_show.stage, _show.t);
    }

    final brandLength = _show.brandLengthNow;
    final wash = reduced ? 0.3 : 0.45;
    final intro = stage == ShowStage.brand ? 1 - _ramp(t, brandLength - wash, wash) : 0.0;
    final chrome = 1 - intro;
    final shownIn = stage == ShowStage.brand && !reduced ? _ease(_ramp(t, 0, 0.3)) : 1.0;
    final handoff = stage == ShowStage.welcome && !reduced
        ? 1 + 0.035 * Curves.easeIn.transform(_ramp(t, _show.welcomeLengthNow - 0.6, 0.6))
        : 1.0;
    final scene = _sceneOf(stage);
    final landscape = size.width > size.height;

    return Opacity(
      opacity: shownIn,
      child: Transform.scale(
        scale: handoff,
        child: Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(child: CustomPaint(painter: _PlatePainter(p))),
            ..._backgrounds(p, scene, stage, t),
            if (stage == ShowStage.scan && !reduced)
              IgnorePointer(
                child: CustomPaint(
                  painter: _ScanPainter(phase: (_show.effectTime / 2.6) % 1, color: p.scan, accent: accent),
                ),
              ),
            Opacity(
              opacity: chrome,
              child: _Chrome(
                palette: p,
                accent: accent,
                title: title,
                subtitle: texts.subtitle ?? l10n.launchShowSubtitle,
                step: switch (stage) {
                  ShowStage.brand || ShowStage.start => 0,
                  ShowStage.confirm => 1,
                  ShowStage.scan => 2,
                  ShowStage.welcome || ShowStage.done => 3,
                },
                reveal: chrome,
                bar: _bar,
                padding: pad,
              ),
            ),
            if (stage == ShowStage.scan && !reduced)
              Positioned(
                right: 26 + pad.right,
                top: pad.top + (landscape ? 92 : 138),
                child: _HexStream(
                  seed: (_show.effectTime / 0.11).floor(),
                  color: p.muted,
                  opacity: 0.6 * _ramp(t, 0.2, 0.4),
                ),
              ),
            if (stage != ShowStage.brand) _main(context, p, accent, stage, t, size, pad, landscape),
            if (stage == ShowStage.welcome) ..._welcome(context, p, accent, title, t, size),
            if (intro > 0)
              Opacity(
                opacity: intro,
                child: _Intro(palette: p, title: title, t: t, reduced: reduced, icon: _icon(76, p)),
              ),
            Positioned(
              top: pad.top + 6,
              right: pad.right + 10,
              child: Semantics(
                button: true,
                label: l10n.launchShowSkip,
                excludeSemantics: true,
                child: GestureDetector(
                  key: InteractiveLaunchView.skipKey,
                  behavior: HitTestBehavior.opaque,
                  onTap: _skip,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 64, minHeight: 48),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Center(
                        widthFactor: 1,
                        child: Text(
                          '${l10n.launchShowSkip.toUpperCase()}  ▸',
                          style: AppType.mono(size: 11, color: p.muted, height: 1.2).copyWith(letterSpacing: 1.6),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Each scene's picture or clip over the plate, crossfading as the scenes change.
  List<Widget> _backgrounds(InteractivePalette p, InteractiveScene? scene, ShowStage stage, double t) {
    final now = scene?.index ?? -1;
    final ramp = stage == ShowStage.welcome ? 1.0 : _ramp(t, 0, 0.5);
    return [
      for (final MapEntry(key: s, value: media) in _media.entries)
        if (widget.config.backgrounds[s] case final custom? when s.index <= now)
          Opacity(
            opacity: s.index == now ? ramp : 1 - ramp,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CustomLaunchView(custom: custom, media: media, dark: widget.dark),
                // The words stay legible on any picture.
                ColoredBox(color: p.bg.withValues(alpha: 0.38)),
              ],
            ),
          ),
    ];
  }

  Widget _icon(double size, InteractivePalette p) {
    final image = widget.icon;
    if (image != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.22),
        child: RawImage(image: image, width: size, height: size, fit: BoxFit.cover),
      );
    }
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: p.introInk, borderRadius: BorderRadius.circular(size * 0.22)),
      child: Text(AppInfo.wordmark, style: AppType.wordmark(size: size * 0.3, color: p.intro)),
    );
  }

  /// The reticle, the status and the scene's button.
  Widget _main(
    BuildContext context,
    InteractivePalette p,
    Color accent,
    ShowStage stage,
    double t,
    Size size,
    EdgeInsets pad,
    bool landscape,
  ) {
    final l10n = context.l10n;
    final reduced = widget.reduced;
    final texts = widget.config.texts;
    final welcome = stage == ShowStage.welcome;
    // The scan's words fade as the welcome comes.
    final center = welcome ? ShowStage.scan : stage;
    final typed = welcome ? 99.0 : t;
    final centerOpacity = welcome ? 1 - _ramp(t, 0, 0.3) : 1 - _show.leaving;

    final reticleIn = switch (stage) {
      ShowStage.start => reduced ? 1.0 : _ease(_ramp(t, 0, 0.9)),
      ShowStage.welcome => 1 - _ramp(t, 0, 0.35),
      _ => 1.0,
    };
    final reticle = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340, maxHeight: 340),
        child: AspectRatio(
          aspectRatio: 1,
          child: Opacity(
            opacity: reticleIn,
            child: Transform.scale(
              scale: 0.86 + 0.14 * reticleIn,
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _ReticlePainter(turn: _show.effectTime, ink: p.ink, soft: p.inkSoft, accent: accent),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final (status, tag) = switch (center) {
      ShowStage.confirm => (l10n.launchShowStatusConfirm, 'PROFILE  REVIEW'),
      ShowStage.scan => (l10n.launchShowStatusScan, 'WORKSPACE  CALIBRATION'),
      _ => (l10n.launchShowStatusStart, 'INITIATE  SESSION'),
    };
    final width = math.min(420.0, (landscape ? size.width * 0.5 : size.width) - 52 - pad.horizontal);
    final waiting = _show.waiting && !welcome;
    final caretOn = waiting && (reduced || _clock % 1.0 < 0.55);

    final words = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Typed(
          text: status,
          t: reduced ? 99 : typed - 0.15,
          step: 0.046,
          fade: 0.34,
          style: AppType.wordmark(size: 30, color: p.ink).copyWith(fontWeight: FontWeight.w700, letterSpacing: 30 * 0.18),
          caret: Container(
            width: 15,
            height: 4,
            margin: const EdgeInsets.only(left: 4, bottom: 6),
            color: caretOn ? accent : Colors.transparent,
          ),
        ),
        const SizedBox(height: 8),
        _Typed(
          text: tag,
          t: reduced ? 99 : typed - 0.35,
          step: 0.013,
          fade: 0.2,
          style: AppType.mono(size: 11, color: p.muted, height: 1.4).copyWith(letterSpacing: 11 * 0.44),
        ),
        const SizedBox(height: 14),
        Align(
          alignment: Alignment.center,
          child: Container(
            width: width * (reduced ? 1 : _ease(_ramp(typed, 0.1, 0.62))),
            height: 1,
            color: p.hair,
          ),
        ),
      ],
    );

    final startOpacity = stage == ShowStage.start ? _ramp(t, 0.3, 0.25) * (1 - _show.leaving) : 0.0;
    final confirmOpacity = stage == ShowStage.confirm ? _ramp(t, 0.3, 0.25) * (1 - _show.leaving) : 0.0;
    final pulse = waiting && !reduced ? 0.5 + 0.5 * math.sin(_clock * 2 * math.pi / 1.9) : 0.0;
    final today = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');

    final actions = Stack(
      alignment: Alignment.bottomCenter,
      children: [
        IgnorePointer(
          ignoring: stage != ShowStage.start || _show.pressed,
          child: Opacity(
            opacity: startOpacity,
            child: _Button(
              key: InteractiveLaunchView.startKey,
              label: texts.start ?? l10n.launchShowStart,
              tag: texts.start == null ? 'START' : null,
              palette: p,
              accent: accent,
              pulse: stage == ShowStage.start ? pulse : 0,
              onTap: () => _press(ShowStage.start),
            ),
          ),
        ),
        IgnorePointer(
          ignoring: stage != ShowStage.confirm || _show.pressed,
          child: Opacity(
            opacity: confirmOpacity,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: width,
                  child: _Card(
                    palette: p,
                    reveal: stage == ShowStage.confirm ? (reduced ? 9.0 : t) : 0,
                    rows: [
                      (l10n.launchShowName, texts.nickname ?? l10n.launchShowNickname),
                      (l10n.launchShowNumber, texts.number ?? '0001'),
                      (l10n.launchShowDate, '${today.year}.${two(today.month)}.${two(today.day)}'),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                _Button(
                  key: InteractiveLaunchView.confirmKey,
                  label: texts.confirm ?? l10n.launchShowConfirm,
                  tag: texts.confirm == null ? 'CONFIRM' : null,
                  palette: p,
                  accent: accent,
                  pulse: stage == ShowStage.confirm ? pulse : 0,
                  onTap: () => _press(ShowStage.confirm),
                ),
              ],
            ),
          ),
        ),
      ],
    );

    final info = SizedBox(
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Opacity(opacity: centerOpacity, child: words),
          const SizedBox(height: 22),
          actions,
          const SizedBox(height: 12),
          Opacity(
            opacity: waiting ? (stage == ShowStage.start ? startOpacity : confirmOpacity) : 0,
            child: Text(
              l10n.launchShowHint,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, height: 1.4, color: p.muted),
            ),
          ),
        ],
      ),
    );

    return Positioned.fill(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          26 + pad.left,
          pad.top + (landscape ? 84 : 150),
          26 + pad.right,
          pad.bottom + (landscape ? 48 : 64),
        ),
        child: LayoutBuilder(
          builder: (context, box) {
            final fitted = ConstrainedBox(
              constraints: BoxConstraints(maxHeight: landscape ? box.maxHeight : box.maxHeight * 0.62),
              child: FittedBox(fit: BoxFit.scaleDown, child: info),
            );
            if (landscape) {
              return Row(
                children: [
                  Expanded(flex: 5, child: reticle),
                  const SizedBox(width: 24),
                  Expanded(flex: 6, child: Center(child: fitted)),
                ],
              );
            }
            return Column(
              children: [
                Expanded(child: reticle),
                const SizedBox(height: 16),
                fitted,
              ],
            );
          },
        ),
      ),
    );
  }

  /// WELCOME TO, the title in its box, the welcome line; then the hand-over's light.
  List<Widget> _welcome(BuildContext context, InteractivePalette p, Color accent, String title, double t, Size size) {
    final l10n = context.l10n;
    final reduced = widget.reduced;
    final texts = widget.config.texts;
    final transition = widget.config.transition;
    final line = '${texts.welcome ?? l10n.launchShowWelcome} · ${texts.nickname ?? l10n.launchShowNickname}';
    final shown = reduced ? 1.0 : _ease(_ramp(t, 0.25, 0.5));

    Widget block({required Color ink, required Color soft, required Color boxBg, required Color boxInk}) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'WELCOME TO',
          style: AppType.wordmark(size: 34, color: ink).copyWith(fontWeight: FontWeight.w800, letterSpacing: 34 * 0.2),
        ),
        const SizedBox(height: 12),
        Container(
          color: boxBg,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
          child: Text(
            title.toUpperCase(),
            style: AppType.wordmark(size: 24, color: boxInk).copyWith(fontWeight: FontWeight.w800, letterSpacing: 2.4),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          title.toUpperCase().split('').join(' '),
          style: AppType.mono(size: 10, color: soft, height: 1.3).copyWith(letterSpacing: 2),
        ),
        const SizedBox(height: 14),
        Text(line, style: TextStyle(fontSize: 15, height: 1.4, color: soft, letterSpacing: 15 * 0.2)),
      ],
    );

    final glitching =
        transition == InteractiveTransition.chroma && !reduced && ((t > 0.35 && t < 0.78) || (t > 1.2 && t < 1.63));
    final seed = (t / 0.07).floor();
    Widget copy(Color color, double dx, int salt) => Transform.translate(
      offset: Offset(dx, 0),
      child: ClipPath(
        clipper: _Slices(seed * 7 + salt),
        child: Opacity(
          opacity: 0.85,
          child: block(ink: color, soft: color, boxBg: color, boxInk: Colors.transparent),
        ),
      ),
    );

    final flares = transition != InteractiveTransition.fade && !reduced;
    final bloom = _ramp(t, 0.2, 1.25);
    final streak = _ramp(t, 0.35, 1.0);
    final flash = t < 1.2 ? 0.0 : (t < 1.27 ? 0.72 : 0.72 * (1 - _ramp(t, 1.27, 0.34)));
    final focus = Offset(size.width / 2, size.height * 0.45);

    return [
      if (flares)
        IgnorePointer(
          child: CustomPaint(
            painter: _FlarePainter(
              center: focus,
              bloom: bloom,
              streak: streak,
              color: p.flare,
              streakColor: widget.dark ? p.flare : accent,
            ),
          ),
        ),
      Align(
        alignment: const Alignment(0, -0.1),
        child: Opacity(
          opacity: shown,
          child: Transform.translate(
            offset: Offset(0, 12 * (1 - shown)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 26),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Stack(
                  children: [
                    if (glitching) copy(const Color(0xFFFF3B30), -3, 1),
                    if (glitching) copy(const Color(0xFF2971B8), 3, 2),
                    block(ink: p.ink, soft: p.inkSoft, boxBg: p.boxBg, boxInk: p.boxInk),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      if (flares && flash > 0) IgnorePointer(child: ColoredBox(color: p.flare.withValues(alpha: flash))),
    ];
  }
}

/// Characters coming in one after another ([t] seconds in, one every [step], each over [fade]).
class _Typed extends StatelessWidget {
  const _Typed({required this.text, required this.t, required this.step, required this.fade, required this.style, this.caret});

  final String text;
  final double t;
  final double step;
  final double fade;
  final TextStyle style;
  final Widget? caret;

  @override
  Widget build(BuildContext context) {
    final color = style.color ?? const Color(0xFF000000);
    final chars = text.characters.toList();
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text.rich(
          TextSpan(
            children: [
              for (var i = 0; i < chars.length; i++)
                TextSpan(
                  text: chars[i],
                  style: TextStyle(color: color.withValues(alpha: color.a * _ramp(t, i * step, fade))),
                ),
            ],
          ),
          style: style,
          maxLines: 1,
          semanticsLabel: text,
        ),
        ?caret,
      ],
    );
  }
}

/// The brand intro: the app's icon, the title tightening, a light passing over.
class _Intro extends StatelessWidget {
  const _Intro({required this.palette, required this.title, required this.t, required this.reduced, required this.icon});

  final InteractivePalette palette;
  final String title;
  final double t;
  final bool reduced;
  final Widget icon;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final iconIn = reduced ? 1.0 : _ease(_ramp(t, 0.1, 0.6));
    final titleIn = reduced ? 1.0 : _ease(_ramp(t, 0.35, 0.5));
    final spacing = reduced ? 0.2 : 0.62 - 0.42 * Curves.easeInOut.transform(_ramp(t, 0.35, 1.3));
    final subIn = reduced ? 1.0 : _ramp(t, 0.8, 0.5);
    final sweep = _ramp(t, 1.0, 1.15);
    return ColoredBox(
      color: p.intro,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 26),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Opacity(
                      opacity: iconIn,
                      child: Transform.scale(scale: 0.92 + 0.08 * iconIn, child: icon),
                    ),
                    const SizedBox(height: 24),
                    Opacity(
                      opacity: titleIn,
                      child: Text(
                        title.toUpperCase(),
                        style: AppType.wordmark(size: 28, color: p.introInk)
                            .copyWith(fontWeight: FontWeight.w800, letterSpacing: 28 * spacing),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Opacity(
                      opacity: subIn * 0.5,
                      child: Text(
                        'DEEPSEEK HARNESS',
                        style: AppType.mono(size: 10, color: p.introInk, height: 1.3).copyWith(letterSpacing: 3),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (!reduced && sweep > 0 && sweep < 1) IgnorePointer(child: CustomPaint(painter: _SweepPainter(sweep, p.sweep))),
        ],
      ),
    );
  }
}

/// The frame: the brand block, corners, step count, footer and the progress bar.
class _Chrome extends StatelessWidget {
  const _Chrome({
    required this.palette,
    required this.accent,
    required this.title,
    required this.subtitle,
    required this.step,
    required this.reveal,
    required this.bar,
    required this.padding,
  });

  final InteractivePalette palette;
  final Color accent;
  final String title;
  final String subtitle;

  /// 0–3: start, confirm, scan, welcome.
  final int step;

  /// 0 → 1 as the frame comes in after the intro.
  final double reveal;
  final double bar;
  final EdgeInsets padding;

  static const steps = ['READY', 'PROFILE', 'CALIBRATE', 'WELCOME'];

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final mono = AppType.mono(size: 10, color: p.muted, height: 1.3).copyWith(letterSpacing: 1.4);
    Widget slide(int i, Widget child) {
      final v = _ease(_ramp(reveal, i * 0.12, 0.64));
      return Opacity(opacity: v, child: Transform.translate(offset: Offset(-22 * (1 - v), 0), child: child));
    }

    final width = MediaQuery.sizeOf(context).width;
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Padding(
            padding: padding + const EdgeInsets.all(12),
            child: CustomPaint(painter: _CornersPainter(p.muted.withValues(alpha: 0.7))),
          ),
          Positioned(
            left: 30 + padding.left,
            top: padding.top + 26,
            right: 120 + padding.right,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                slide(
                  0,
                  Text(
                    title.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.wordmark(size: 26, color: p.ink).copyWith(fontWeight: FontWeight.w800, letterSpacing: 1),
                  ),
                ),
                slide(
                  1,
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, height: 1.5, fontWeight: FontWeight.w700, color: p.inkSoft, letterSpacing: 1.2),
                  ),
                ),
                const SizedBox(height: 10),
                slide(
                  2,
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: 'REV ${AppInfo.version.split('+').first} · ANDROID   '),
                        TextSpan(
                          text: '${two(now.hour)}:${two(now.minute)}:${two(now.second)}',
                          style: TextStyle(color: accent),
                        ),
                      ],
                    ),
                    style: mono,
                    maxLines: 1,
                  ),
                ),
                const SizedBox(height: 10),
                slide(
                  3,
                  Row(
                    children: [
                      for (var i = 0; i < steps.length; i++)
                        Container(
                          width: i == step ? 34 : 20,
                          height: 2,
                          margin: const EdgeInsets.only(right: 5),
                          color: i == step ? accent : (i < step ? p.ink.withValues(alpha: 0.3) : p.hair),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            left: 30 + padding.left,
            bottom: padding.bottom + 26,
            child: Text('[ 0${step + 1} / 0${steps.length} ]  ${steps[step]}', style: mono),
          ),
          Positioned(
            right: 30 + padding.right,
            bottom: padding.bottom + 26,
            child: Row(
              children: [
                Text('POWERED BY DSH', style: mono),
                const SizedBox(width: 8),
                Container(width: 26, height: 7, color: p.ink),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: padding.bottom + 8,
            child: Center(
              child: SizedBox(
                width: math.min(420, width * 0.5),
                height: 10,
                child: CustomPaint(
                  painter: _BarPainter(value: bar, track: p.hairSoft, tick: p.hair, fill: p.ink, accent: accent),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Button extends StatelessWidget {
  const _Button({
    super.key,
    required this.label,
    required this.tag,
    required this.palette,
    required this.accent,
    required this.pulse,
    required this.onTap,
  });

  final String label;

  /// The small English word beside a default label.
  final String? tag;
  final InteractivePalette palette;
  final Color accent;

  /// 0–1: the accent's glow while it waits.
  final double pulse;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 50, minWidth: 160),
          padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 13),
          decoration: BoxDecoration(
            border: Border.all(color: p.ink, width: 1.5),
            boxShadow: [
              if (pulse > 0) BoxShadow(color: accent.withValues(alpha: 0.35 * pulse), blurRadius: 18, spreadRadius: 1),
            ],
            color: p.bg.withValues(alpha: 0.6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15, height: 1.3, fontWeight: FontWeight.w700, color: p.ink, letterSpacing: 2),
                ),
              ),
              if (tag case final tag?) ...[
                const SizedBox(width: 12),
                Text(
                  tag,
                  style: AppType.mono(size: 11, color: p.ink.withValues(alpha: 0.62), height: 1.3).copyWith(letterSpacing: 1.6),
                ),
              ],
              const SizedBox(width: 10),
              Container(width: 6, height: 6, color: accent),
            ],
          ),
        ),
      ),
    );
  }
}

/// The profile card: label and value per row, between hairlines.
class _Card extends StatelessWidget {
  const _Card({required this.palette, required this.rows, required this.reveal});

  final InteractivePalette palette;
  final List<(String, String)> rows;

  /// Seconds into the scene (the rows come in one after another).
  final double reveal;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return DecoratedBox(
      decoration: BoxDecoration(border: Border(top: BorderSide(color: p.hair), bottom: BorderSide(color: p.hair))),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++)
            Opacity(
              opacity: _ramp(reveal, 0.2 + i * 0.08, 0.3),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 9),
                decoration: i == 0 ? null : BoxDecoration(border: Border(top: BorderSide(color: p.hairSoft))),
                child: Row(
                  children: [
                    Text(rows[i].$1, style: TextStyle(fontSize: 12.5, height: 1.4, color: p.muted)),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        rows[i].$2,
                        textAlign: TextAlign.end,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 15, height: 1.4, fontWeight: FontWeight.w700, color: p.ink, letterSpacing: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A column of changing hex numbers (decoration).
class _HexStream extends StatelessWidget {
  const _HexStream({required this.seed, required this.color, required this.opacity});

  final int seed;
  final Color color;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final random = math.Random(seed);
    String word() => random.nextInt(0x10000).toRadixString(16).padLeft(4, '0').toUpperCase();
    return IgnorePointer(
      child: Opacity(
        opacity: opacity,
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFFFFFFF), Color(0x00FFFFFF)],
          ).createShader(rect),
          child: Text(
            [for (var i = 0; i < 10; i++) '${word()} ${word()} ${word()}'].join('\n'),
            textAlign: TextAlign.end,
            style: AppType.mono(size: 10, color: color, height: 1.45),
          ),
        ),
      ),
    );
  }
}

/// The background plate: a soft gradient, a highlight, faint panels and a vignette.
class _PlatePainter extends CustomPainter {
  const _PlatePainter(this.p);

  final InteractivePalette p;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    // CSS 168deg: down, tilted a little to the right.
    const angle = 168 * math.pi / 180;
    final dir = Offset(math.sin(angle), -math.cos(angle));
    final half = (size.width.abs() * dir.dx.abs() + size.height.abs() * dir.dy.abs()) / 2;
    final c = size.center(Offset.zero);
    canvas.drawRect(
      rect,
      Paint()..shader = ui.Gradient.linear(c - dir * half, c + dir * half, [p.bg2, p.bg, p.bg], [0, 0.42, 1]),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(size.width * 0.78, size.height * 0.12),
          size.longestSide * 0.65,
          [p.highlight, p.highlight.withValues(alpha: 0)],
        ),
    );
    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = p.hairSoft;
    for (final panel in [
      Rect.fromLTWH(size.width * 0.60, size.height * 0.02, size.width * 0.16, size.height * 0.96),
      Rect.fromLTWH(size.width * 0.78, size.height * 0.02, size.width * 0.16, size.height * 0.96),
      Rect.fromLTWH(size.width * 0.96, size.height * 0.02, size.width * 0.16, size.height * 0.96),
      Rect.fromLTWH(size.width * 0.05, size.height * 0.02, size.width * 0.10, size.height * 0.5),
    ]) {
      canvas.drawRect(
        panel,
        Paint()
          ..shader = ui.Gradient.linear(panel.topCenter, panel.bottomCenter, [
            p.watermark,
            p.watermark.withValues(alpha: 0),
          ]),
      );
      canvas.drawRect(panel, border);
    }
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.radial(c, size.longestSide * 0.75, [p.vignette.withValues(alpha: 0), p.vignette], [0.55, 1]),
    );
  }

  @override
  bool shouldRepaint(_PlatePainter old) => old.p != p;
}

/// Two counter-rotating arcs with a dot at one end, fixed brackets and three accent dots, in a
/// 400 × 400 box.
class _ReticlePainter extends CustomPainter {
  const _ReticlePainter({required this.turn, required this.ink, required this.soft, required this.accent});

  /// Effect seconds (one turn of the outer ring every 9 s, the inner the other way every 5.4 s).
  final double turn;
  final Color ink;
  final Color soft;
  final Color accent;

  static double _rad(double deg) => (deg - 90) * math.pi / 180;
  static Offset _at(double r, double deg) => Offset(r * math.cos(_rad(deg)), r * math.sin(_rad(deg)));

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.shortestSide / 400;
    canvas
      ..save()
      ..translate(size.width / 2, size.height / 2)
      ..scale(k);
    void arc(double r, double from, double to, Paint paint) =>
        canvas.drawArc(Rect.fromCircle(center: Offset.zero, radius: r), _rad(from), (to - from) * math.pi / 180, false, paint);
    Paint stroke(Color color, double width) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..color = color;

    canvas
      ..save()
      ..rotate(turn * 2 * math.pi / 9);
    arc(150, 215, 505, stroke(ink, 6));
    canvas
      ..drawCircle(_at(150, 505), 7, Paint()..color = ink)
      ..restore()
      ..save()
      ..rotate(-turn * 2 * math.pi / 5.4);
    arc(104, 200, 490, stroke(soft, 2.2));
    canvas
      ..drawCircle(_at(104, 200), 4, Paint()..color = soft)
      ..restore();
    final bracket = stroke(ink.withValues(alpha: ink.a * 0.85), 1.6);
    arc(62, 118, 242, bracket);
    arc(62, 298, 422, bracket);
    final dot = Paint()..color = accent;
    for (final o in const [Offset(-48, -68), Offset(52, 68), Offset(78, -50)]) {
      canvas.drawCircle(o, 2.8, dot);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ReticlePainter old) =>
      old.turn != turn || old.ink != ink || old.soft != soft || old.accent != accent;
}

/// A soft band moving down the screen ([phase] 0 → 1).
class _ScanPainter extends CustomPainter {
  const _ScanPainter({required this.phase, required this.color, required this.accent});

  final double phase;
  final Color color;
  final Color accent;

  static const band = 96.0;

  @override
  void paint(Canvas canvas, Size size) {
    final y = phase * (size.height + band) - band;
    final rect = Rect.fromLTWH(0, y, size.width, band);
    canvas.drawRect(
      rect,
      Paint()..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter, [color.withValues(alpha: 0), color]),
    );
    canvas.drawRect(Rect.fromLTWH(0, y + band - 1, size.width, 1), Paint()..color = accent.withValues(alpha: 0.5));
  }

  @override
  bool shouldRepaint(_ScanPainter old) => old.phase != phase || old.color != color || old.accent != accent;
}

/// The intro's light band passing left to right ([t] 0 → 1).
class _SweepPainter extends CustomPainter {
  const _SweepPainter(this.t, this.color);

  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final width = size.width * 0.42;
    final x = -width + (size.width + width) * Curves.easeInOut.transform(t);
    final rect = Rect.fromLTWH(x, 0, width, size.height);
    final clear = color.withValues(alpha: 0);
    canvas.drawRect(
      rect,
      Paint()..shader = ui.Gradient.linear(rect.centerLeft, rect.centerRight, [clear, color, clear], [0, 0.5, 1]),
    );
  }

  @override
  bool shouldRepaint(_SweepPainter old) => old.t != t || old.color != color;
}

/// The welcome's bloom from the centre and the streak across it.
class _FlarePainter extends CustomPainter {
  const _FlarePainter({
    required this.center,
    required this.bloom,
    required this.streak,
    required this.color,
    required this.streakColor,
  });

  final Offset center;
  final double bloom;
  final double streak;
  final Color color;
  final Color streakColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (bloom > 0 && bloom < 1) {
      final radius = size.longestSide * 0.5 * (0.08 + 1.34 * _ease(bloom));
      final a = 0.55 * math.sin(math.pi * bloom);
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = ui.Gradient.radial(center, radius, [
            color.withValues(alpha: a),
            color.withValues(alpha: 0),
          ]),
      );
    }
    if (streak > 0 && streak < 1) {
      final width = size.width * 1.32 * _ease(streak);
      final rect = Rect.fromCenter(center: center, width: width, height: 3);
      final a = 1 - streak;
      canvas
        ..drawRect(
          rect.inflate(3),
          Paint()
            ..color = streakColor.withValues(alpha: 0.45 * a)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
        )
        ..drawRect(rect, Paint()..color = streakColor.withValues(alpha: a));
    }
  }

  @override
  bool shouldRepaint(_FlarePainter old) =>
      old.bloom != bloom || old.streak != streak || old.center != center || old.color != color || old.streakColor != streakColor;
}

/// The thin progress bar: ticks above a track, the filled part ending in the accent.
class _BarPainter extends CustomPainter {
  const _BarPainter({required this.value, required this.track, required this.tick, required this.fill, required this.accent});

  final double value;
  final Color track;
  final Color tick;
  final Color fill;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height - 3;
    canvas.drawRect(Rect.fromLTWH(0, y, size.width, 3), Paint()..color = track);
    final ticks = Paint()..color = tick;
    for (var x = 0.0; x <= size.width; x += 30) {
      canvas.drawRect(Rect.fromLTWH(x, y - 5, 1, 3), ticks);
    }
    final w = size.width * value.clamp(0.0, 1.0);
    if (w <= 0) return;
    canvas
      ..drawRect(Rect.fromLTWH(0, y, w, 3), Paint()..color = fill)
      ..drawRect(Rect.fromLTWH(math.max(0, w - 6), y, math.min(6, w), 3), Paint()..color = accent);
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.value != value || old.track != track || old.tick != tick || old.fill != fill || old.accent != accent;
}

/// Hairline corners.
class _CornersPainter extends CustomPainter {
  const _CornersPainter(this.color);

  final Color color;

  static const arm = 16.0;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(0, arm)
      ..lineTo(0, 0)
      ..lineTo(arm, 0)
      ..moveTo(w - arm, 0)
      ..lineTo(w, 0)
      ..lineTo(w, arm)
      ..moveTo(w, h - arm)
      ..lineTo(w, h)
      ..lineTo(w - arm, h)
      ..moveTo(arm, h)
      ..lineTo(0, h)
      ..lineTo(0, h - arm);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_CornersPainter old) => old.color != color;
}

/// A few horizontal slices (the chromatic copies only show through them).
class _Slices extends CustomClipper<Path> {
  const _Slices(this.seed);

  final int seed;

  @override
  Path getClip(Size size) {
    final random = math.Random(seed);
    final path = Path();
    for (var i = 0; i < 3; i++) {
      final top = random.nextDouble() * size.height;
      path.addRect(Rect.fromLTWH(0, top, size.width, 4 + random.nextDouble() * size.height * 0.18));
    }
    return path;
  }

  @override
  bool shouldReclip(_Slices old) => old.seed != seed;
}

/// The interactive launch screen's first scene, still (the settings' small phone).
class InteractiveLaunchStill extends StatelessWidget {
  const InteractiveLaunchStill({super.key, required this.config, required this.dark});

  final InteractiveLaunch config;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final p = dark ? InteractivePalette.dark : InteractivePalette.light;
    final accent = config.accentColor;
    final title = config.texts.title ?? AppInfo.name.toUpperCase();
    return Stack(
      fit: StackFit.expand,
      children: [
        CustomPaint(painter: _PlatePainter(p)),
        Positioned(
          left: 30,
          top: 60,
          right: 30,
          child: Text(
            title.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textScaler: TextScaler.noScaling,
            style: AppType.wordmark(size: 26, color: p.ink).copyWith(fontWeight: FontWeight.w800, letterSpacing: 1),
          ),
        ),
        Align(
          alignment: const Alignment(0, -0.15),
          child: FractionallySizedBox(
            widthFactor: 0.74,
            child: AspectRatio(
              aspectRatio: 1,
              child: CustomPaint(
                painter: _ReticlePainter(turn: 0, ink: p.ink, soft: p.inkSoft, accent: accent),
              ),
            ),
          ),
        ),
        Align(
          alignment: const Alignment(0, 0.62),
          child: Container(
            width: 170,
            height: 50,
            decoration: BoxDecoration(border: Border.all(color: p.ink, width: 1.5)),
            alignment: Alignment.center,
            child: Container(width: 60, height: 6, color: accent),
          ),
        ),
      ],
    );
  }
}