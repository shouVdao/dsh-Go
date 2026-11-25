// 设置 › 主题 › 壁纸 › 调整显示位置: the looping video over the whole screen, as the screen will
// frame it. Drag to move it; 填满 covers the screen, 居中 fits all of it in.
//
//   (×)                                  ( 完成 )
//
//               the video, looping
//
//              ( 填满 | 居中 · 复原 )

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/wallpaper_state.dart';
import '../../wallpaper/live_wallpaper.dart';
import '../common/pressable.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'live_backdrop.dart';

Future<void> showVideoWallpaperEditor(BuildContext context, VideoWallpaper wallpaper) => Navigator.of(context).push(
  PageRouteBuilder<void>(
    opaque: true,
    transitionDuration: AppMotion.of(context, AppMotion.standard),
    reverseTransitionDuration: AppMotion.of(context, AppMotion.quick),
    pageBuilder: (context, _, _) => VideoWallpaperEditorPage(wallpaper: wallpaper),
    transitionsBuilder: (context, animation, _, child) => FadeTransition(opacity: animation, child: child),
  ),
);

class VideoWallpaperEditorPage extends ConsumerStatefulWidget {
  const VideoWallpaperEditorPage({super.key, required this.wallpaper});

  final VideoWallpaper wallpaper;

  @override
  ConsumerState<VideoWallpaperEditorPage> createState() => _VideoWallpaperEditorPageState();
}

class _VideoWallpaperEditorPageState extends ConsumerState<VideoWallpaperEditorPage> {
  late VideoFit _fit = widget.wallpaper.fit;
  late double _alignX = widget.wallpaper.alignX;
  late double _alignY = widget.wallpaper.alignY;

  /// 编辑页自己的播放器:拖动时只改摆放方式,不重开文件。
  late final VideoWallpaperHandle _handle = VideoWallpaperHandle(widget.wallpaper);

  VideoWallpaper get _draft => widget.wallpaper.copyWith(fit: _fit, alignX: _alignX, alignY: _alignY);

  @override
  void dispose() {
    _handle.dispose();
    super.dispose();
  }

  /// A drag across half the screen moves the picture from edge to edge.
  void _drag(Size screen, Offset delta) => setState(() {
    _alignX = (_alignX + delta.dx / (screen.width / 2)).clamp(-1.0, 1.0);
    _alignY = (_alignY + delta.dy / (screen.height / 2)).clamp(-1.0, 1.0);
    _handle.wallpaper = _draft;
  });

  Future<void> _done() async {
    final notifier = ref.read(videoWallpaperProvider.notifier);
    await notifier.setFit(_fit);
    await notifier.frame(alignX: _alignX, alignY: _alignY);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  void _reset() => setState(() {
    _alignX = 0;
    _alignY = 0;
    _handle.wallpaper = _draft;
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final padding = MediaQuery.paddingOf(context);
    final screen = MediaQuery.sizeOf(context);
    final hint = Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.onSurface);
    final primary = Theme.of(context).colorScheme.primary;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              key: const ValueKey('video-wallpaper-editor-view'),
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (details) => _drag(screen, details.delta),
              child: VideoWallpaperView(handle: _handle),
            ),
            // A soft shade under the status bar and the keys, so both read on any frame.
            const IgnorePointer(child: _Shade()),
            Positioned(
              left: 12,
              right: 12,
              top: padding.top + 6,
              child: Row(
                children: [
                  _GlassKey(
                    key: const ValueKey('video-wallpaper-editor-cancel'),
                    tooltip: MaterialLocalizations.of(context).cancelButtonLabel,
                    onTap: () => Navigator.of(context).pop(),
                    child: Icon(AppIcons.close, size: 20, color: Theme.of(context).colorScheme.onSurface),
                  ),
                  const Spacer(),
                  GlassSurface(
                    key: const ValueKey('video-wallpaper-editor-done'),
                    tier: GlassTier.chrome,
                    stadium: true,
                    onTap: () => unawaited(_done()),
                    child: SizedBox(
                      height: 44,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Center(
                          child: Text(
                            l10n.commonDone,
                            style: hint?.copyWith(color: primary, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: padding.bottom + 20,
              child: Center(
                child: GlassSurface(
                  tier: GlassTier.chrome,
                  stadium: true,
                  child: SizedBox(
                    height: 40,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(width: 8),
                        _FitKey(
                          key: const ValueKey('video-wallpaper-editor-fill'),
                          label: l10n.wallpaperVideoFill,
                          selected: _fit == VideoFit.fill,
                          onTap: () => setState(() {
                            _fit = VideoFit.fill;
                            _handle.wallpaper = _draft;
                          }),
                        ),
                        _FitKey(
                          key: const ValueKey('video-wallpaper-editor-center'),
                          label: l10n.wallpaperVideoCenter,
                          selected: _fit == VideoFit.center,
                          onTap: () => setState(() {
                            _fit = VideoFit.center;
                            _handle.wallpaper = _draft;
                          }),
                        ),
                        SizedBox(
                          height: 16,
                          child: VerticalDivider(width: 1, color: Theme.of(context).colorScheme.outlineVariant),
                        ),
                        Semantics(
                          button: true,
                          child: Pressable(
                            key: const ValueKey('video-wallpaper-editor-reset'),
                            onTap: _reset,
                            child: SizedBox(
                              height: 40,
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(12, 0, 18, 0),
                                child: Center(
                                  child: Text(l10n.wallpaperEditorReset, style: hint?.copyWith(color: primary)),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
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
}

/// 填满 / 居中 in the bottom bar: the chosen one in the accent.
class _FitKey extends StatelessWidget {
  const _FitKey({super.key, required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelLarge;
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      child: Pressable(
        onTap: onTap,
        child: SizedBox(
          height: 40,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Center(
              child: Text(
                label,
                style: style?.copyWith(
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                  fontWeight: selected ? FontWeight.w600 : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GlassKey extends StatelessWidget {
  const _GlassKey({super.key, required this.tooltip, required this.onTap, required this.child});

  final String tooltip;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: GlassSurface(
      tier: GlassTier.chrome,
      circle: true,
      onTap: onTap,
      child: SizedBox.square(dimension: 44, child: Center(child: child)),
    ),
  );
}

class _Shade extends StatelessWidget {
  const _Shade();

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    const shade = Color(0x59000000);
    return Column(
      children: [
        Container(
          height: padding.top + 72,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [shade, Color(0x00000000)],
            ),
          ),
        ),
        const Spacer(),
        Container(
          height: padding.bottom + 88,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [shade, Color(0x00000000)],
            ),
          ),
        ),
      ],
    );
  }
}
