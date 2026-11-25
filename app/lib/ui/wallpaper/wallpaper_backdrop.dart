// The page behind 首页 / 对话 and the drawer over them: the wallpaper in use — a baked custom
// picture, a looping video, or a .json scene — else the usual gradient ([AppBackdrop]). Settings
// and other pages keep the gradient, and so does every page with the system's high contrast on.
//
// A custom picture is baked once for this screen and mode (lib/wallpaper/wallpaper_render.dart)
// and only drawn after that; a new bake fades in over the old one. A live wallpaper (video /
// .json) is drawn by AppBackdrop's `live` layer instead. While either shows, text colours fainter
// than the secondary one are guarded for it (WallpaperLook.guardTheme), unless the user switched
// that off (CustomWallpaper.guard).
//
// An animated picture plays (lib/wallpaper/wallpaper_frames.dart) over the bake of its first
// frame, each frame painted by the backdrop's own painter. It doesn't with motion reduced, the
// animation switched off, or this page covered by another; the bake alone shows then.
//
// [WallpaperBackdrop.scene] does the same for a page's own picture (a tavern chat's background)
// in place of the app's wallpaper: the gradient when it has none. A scene is always the guarded
// bake of its first frame.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../performance/performance_state.dart';
import '../../state/wallpaper_state.dart';
import '../../wallpaper/custom_wallpaper.dart';
import '../../wallpaper/live_wallpaper.dart';
import '../../wallpaper/scene_view.dart';
import '../../wallpaper/wallpaper_frames.dart';
import '../../wallpaper/wallpaper_look.dart';
import '../../wallpaper/wallpaper_render.dart';
import '../chat/chat_header.dart' show ChatHeader;
import '../theme/theme.dart';
import 'live_backdrop.dart';

class WallpaperBackdrop extends ConsumerStatefulWidget {
  const WallpaperBackdrop({super.key, required this.child}) : scene = false, picture = null;

  /// [picture] instead of the app's wallpaper; null: the gradient.
  const WallpaperBackdrop.scene({super.key, required this.picture, required this.child}) : scene = true;

  final Widget child;

  /// A page's own picture ([picture]) rather than the app's wallpaper.
  final bool scene;
  final CustomWallpaper? picture;

  /// The composer and what's around it, over the navigation bar (dp).
  static const composerZone = 96.0;

  /// What the page [context] is on bakes for: the window, its bars, the page's look. Insets come
  /// from the view's own padding, so the keyboard doesn't ask for a new bake.
  static WallpaperFrame frameOf(BuildContext context) {
    final padding = MediaQuery.viewPaddingOf(context);
    return WallpaperFrame(
      size: MediaQuery.sizeOf(context),
      pixelRatio: MediaQuery.devicePixelRatioOf(context),
      look: WallpaperLook.of(context),
      top: padding.top + ChatHeader.barHeightOf(context) + 8,
      bottom: padding.bottom + composerZone,
      // The system's setting and the app's own (lib/app.dart folds it in).
      motion: !MediaQuery.disableAnimationsOf(context),
    );
  }

  @override
  ConsumerState<WallpaperBackdrop> createState() => _WallpaperBackdropState();
}

class _WallpaperBackdropState extends ConsumerState<WallpaperBackdrop> with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(vsync: this, duration: AppMotion.standard, value: 1)
    ..addStatusListener(_faded);

  /// The provider's image last taken (compared by identity), and this widget's own handles:
  /// the picture shown, and the one it is fading in over (null: the gradient).
  ui.Image? _taken;
  ui.Image? _image;
  ui.Image? _from;
  bool _fading = false;

  /// The wallpaper [_image] is a bake of; null for a scene's picture.
  CustomWallpaper? _shown;

  ThemeData? _theme;
  ThemeData? _guarded;

  /// 动态壁纸的控制器 / 引擎:整屏一层和 [BackdropVeil] 那一条共用同一份。
  VideoWallpaperHandle? _video;
  JsonWallpaperHandle? _json;

  @override
  void dispose() {
    _video?.dispose();
    _json?.dispose();
    _fade.dispose();
    _image?.dispose();
    _from?.dispose();
    super.dispose();
  }

  VideoWallpaperHandle _videoFor(VideoWallpaper wallpaper) {
    final current = _video;
    if (current != null && current.wallpaper.path == wallpaper.path) {
      // 改的只是摆放方式,控制器不重开。
      current.wallpaper = wallpaper;
      return current;
    }
    current?.dispose();
    return _video = VideoWallpaperHandle(wallpaper);
  }

  JsonWallpaperHandle _jsonFor(JsonWallpaper wallpaper) {
    final current = _json;
    if (current != null && current.wallpaper == wallpaper) return current;
    current?.dispose();
    return _json = JsonWallpaperHandle(wallpaper);
  }

  void _take(ui.Image? next, [CustomWallpaper? of]) {
    _shown = next == null ? null : of;
    if (identical(next, _taken)) return;
    _taken = next;
    _from?.dispose();
    _from = _image;
    _image = next?.clone();
    if (MediaQuery.disableAnimationsOf(context) || (_from == null && _image == null)) {
      _from?.dispose();
      _from = null;
      _fading = false;
      _fade.value = 1;
      return;
    }
    _fading = true;
    _fade.forward(from: 0);
  }

  void _faded(AnimationStatus status) {
    if (status != AnimationStatus.completed || !_fading || !mounted) return;
    setState(() {
      _from?.dispose();
      _from = null;
      _fading = false;
    });
  }

  /// [wallpaper]'s frames as they play over its bake for [frame].
  BackdropLive _live(CustomWallpaper wallpaper, WallpaperFrame frame) {
    final window = wallpaper.window(frame.size);
    final look = frame.look;
    return BackdropLive(
      // One decoder however many pages show it; it stops when none does.
      frames: ref.watch(pictureFramesProvider(WallpaperBake.motionSource(wallpaper))),
      window: Rect.fromLTRB(
        window.left / wallpaper.width,
        window.top / wallpaper.height,
        window.right / wallpaper.width,
        window.bottom / wallpaper.height,
      ),
      veilTop: look.veilTop,
      veilBottom: look.veilBottom,
      sigma: WallpaperBake.sigmaOf(wallpaper, frame),
      tone: wallpaper.toneFor(look.brightness).clamp(0.0, 1.0) * WallpaperBake.maxTone,
    );
  }

  @override
  Widget build(BuildContext context) {
    final frame = WallpaperBackdrop.frameOf(context);
    Widget? live;
    // A video layer is a whole page of pixels per frame; the composer's veil must not
    // re-draw it (see AppBackdrop.liveBand). A .json scene paints twice cheaply.
    var liveBand = true;
    final lightweight = ref.watch(performanceDefaultsProvider.select((p) => p.lightweight));
    if (MediaQuery.maybeHighContrastOf(context) ?? false) {
      // The system's high contrast: the plain page.
      _take(null);
    } else if (widget.scene) {
      final scene = widget.picture;
      if (scene == null) {
        _take(null);
      } else {
        final baked = ref.watch(sceneImageProvider((scene, frame)));
        // Not as the bake of [scene]: a scene neither plays nor goes unguarded.
        if (!baked.isLoading) _take(baked.value);
      }
    } else {
      switch (ref.watch(wallpaperKindProvider).value ?? WallpaperKind.gradient) {
        case WallpaperKind.image:
          final baked = ref.watch(wallpaperImageProvider(frame));
          // While a new bake runs, the picture on screen stays.
          if (!baked.isLoading) _take(baked.value, ref.watch(customWallpaperProvider).value);
        case WallpaperKind.video:
          _take(null);
          liveBand = false;
          final video = ref.watch(videoWallpaperProvider).value;
          if (video == null) {
            _video?.dispose();
            _video = null;
          } else {
            final handle = _videoFor(video);
            live = VideoWallpaperView(key: ObjectKey(handle), handle: handle);
          }
        case WallpaperKind.json:
          _take(null);
          final json = ref.watch(jsonWallpaperProvider).value ?? const JsonWallpaper(JsonWallpaper.bundled);
          final handle = _jsonFor(json)..setAnimationsEnabled(!MediaQuery.disableAnimationsOf(context));
          live = JsonWallpaperView(key: ObjectKey(handle), handle: handle);
        case WallpaperKind.gradient:
          _take(null);
      }
    }
    if (live == null) {
      // 不在用动态壁纸:别让控制器 / 引擎在后台继续跑。
      _video?.dispose();
      _video = null;
      _json?.dispose();
      _json = null;
    }
    final shown = _shown;
    // A page under another one's route doesn't tick, and doesn't decode either.
    final on = frame.copyWith(lightweight: lightweight);
    final plays = shown != null && on.plays(shown) && TickerMode.valuesOf(context).enabled;
    final picture = _image == null && !_fading
        ? null
        : BackdropPicture(
            image: _image,
            from: _from,
            fade: _fading ? _fade : kAlwaysCompleteAnimation,
            live: plays ? _live(shown, on) : null,
          );
    final theme = Theme.of(context);
    final guard = live != null || (_image != null && (shown?.guard ?? true));
    if (guard && !identical(theme, _theme)) {
      _theme = theme;
      _guarded = frame.look.guardTheme(theme);
    }
    // Always a Theme, so the page under it keeps its state when a wallpaper comes or goes.
    return AppBackdrop(
      picture: picture,
      live: live,
      liveBand: liveBand,
      child: Theme(data: guard ? _guarded! : theme, child: widget.child),
    );
  }
}
