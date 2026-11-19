// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'backdrop_frame.dart';
import 'surfaces.dart';

/// 全屏页面背景:**竖向雾蓝渐变 + 两团极淡的光**。
///
/// - 底层:`backdropTop → backdropBottom` 竖向渐变(浅色彩度 ≤ 0.019)。
/// - 右上:主色光晕(跟随 accent)。左下:暮紫光晕。透明度都在 0.25–0.42,
///   画在大半径径向渐变里,肉眼只觉得"有点透亮",看不出是两个圆。
/// - 光晕的作用是给玻璃一点可"透"的颜色;纯平背景上的玻璃看起来只是白块。
///
/// **同一主题内所有页共用同一张背景**,
/// 切 tab 时背景不动,只有前景内容在变 —— 切换顺滑的关键。
///
/// 内部自带一个透明 `Material`:子树里的 `InkWell` 水波画在背景**之上**。
/// (若水波宿主是背景下面的 Scaffold,不透明的渐变会把水波整个盖住。)
///
/// 给了 [picture](自定义壁纸,lib/ui/wallpaper/wallpaper_backdrop.dart)就画那张
/// 预先烘好的图,不画渐变;子树里的 [BackdropVeil] 跟着画同一张图。
///
/// 给了 [live](循环视频 / .json 动态壁纸)就把它画在渐变之上、内容之下:视频和
/// 动画自己会动,烘不出图,所以另外盖一层淡淡的本页底色 [liveScrim] 保证字看得清。
/// 页里的 [BackdropVeil] 拿同一个 [live] 再画一遍自己那一条——和静态图一样,
/// 内容滑到浮动控件后面时淡出的仍是背景本身,而不是一块底色。
class AppBackdrop extends StatelessWidget {
  const AppBackdrop({
    super.key,
    required this.child,
    this.glow = true,
    this.picture,
    this.live,
    this.liveBand = true,
  });

  final Widget child;

  /// 是否画光晕。全屏 WebView、安装页等自带背景的场景可以关掉。
  final bool glow;

  /// A picture in place of the gradient; null: the gradient.
  final BackdropPicture? picture;

  /// A live background (video / .json scene) drawn over the gradient.
  final Widget? live;

  /// Whether the [BackdropVeil]s over this may re-draw [live] in their own band.
  ///
  /// A .json scene is cheap to paint twice. A video is a whole page of pixels every
  /// frame: the veil's band would have to build a page-sized layer and mask it, which
  /// on a phone starves the raster thread and drags the whole page down to zero fps
  /// while something is being dragged over it. The video wallpaper turns this off and
  /// the band paints [bandAlpha] of the page's own colour instead.
  final bool liveBand;

  /// 动态背景(视频)之上那条遮罩的实心端不透明度:视频不重画,只盖一层本页底色。
  static const bandAlpha = 0.9;

  /// 动态背景上盖的本页底色透明度:浅色页薄一点,深色页厚一点,视频/动画
  /// 仍然看得见,直接压在背景上的次要文字也不至于糊。
  static double liveScrim(Brightness brightness) => brightness == Brightness.dark ? 0.52 : 0.4;

  @override
  Widget build(BuildContext context) {
    final s = DshSurfaces.of(context);
    final live = this.live;
    final scrim = liveScrim(Theme.of(context).brightness);
    // 视频 / 场景 + 盖在它上面的本页底色,算一张图:页里的 BackdropVeil 拿它
    // 再画一遍那一条时,画出来的就是背景在该位置的样子。
    final layer = live == null
        ? null
        : Stack(
            // 由背景那一层的 key 决定换没换(换视频 / 换 .json 文件)。
            key: live.key,
            fit: StackFit.expand,
            children: [
              Positioned.fill(child: IgnorePointer(child: RepaintBoundary(child: live))),
              Positioned.fill(
                child: IgnorePointer(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: _LiveScrimPainter(top: s.backdropTop, bottom: s.backdropBottom, alpha: scrim),
                    ),
                  ),
                ),
              ),
            ],
          );
    return _BackdropScope(
      picture: picture,
      live: liveBand ? layer : null,
      scrimBand: layer != null && !liveBand,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _BackdropPainter(
                    top: s.backdropTop,
                    bottom: s.backdropBottom,
                    glowPrimary: glow ? s.glowPrimary : null,
                    glowSecondary: glow ? s.glowSecondary : null,
                    picture: live == null ? picture : null,
                  ),
                ),
              ),
            ),
          ),
          if (layer != null) Positioned.fill(child: IgnorePointer(child: layer)),
          Material(type: MaterialType.transparency, child: child),
        ],
      ),
    );
  }
}

/// What [AppBackdrop] paints instead of its gradient: [image], baked to the screen's size (the
/// custom wallpaper), faded in at [fade] over [from] (the picture it replaces; null: the
/// gradient). [image] null fades back to the gradient. The images belong to whoever made this;
/// they must outlive it.
@immutable
class BackdropPicture {
  const BackdropPicture({required this.image, this.from, this.fade = kAlwaysCompleteAnimation});

  final ui.Image? image;
  final ui.Image? from;
  final Animation<double> fade;

  @override
  bool operator ==(Object other) =>
      other is BackdropPicture && other.image == image && other.from == from && other.fade == fade;

  @override
  int get hashCode => Object.hash(image, from, fade);
}

/// The picture and the live layer of the nearest [AppBackdrop], for the [BackdropVeil]s over it.
class _BackdropScope extends InheritedWidget {
  const _BackdropScope({
    required this.picture,
    required this.live,
    this.scrimBand = false,
    required super.child,
  });

  final BackdropPicture? picture;

  /// 背景是动态的(视频 / .json 场景):遮罩拿这一层原样再画一遍,而不是重画背景。
  final Widget? live;

  /// 背景是动态的、但重画太贵(视频):遮罩不画背景,只盖一层本页底色。
  final bool scrimBand;

  static BackdropPicture? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_BackdropScope>()?.picture;

  static Widget? liveOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_BackdropScope>()?.live;

  static bool scrimBandOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_BackdropScope>()?.scrimBand ?? false;

  @override
  bool updateShouldNotify(_BackdropScope old) =>
      old.picture != picture ||
      old.scrimBand != scrimBand ||
      old.live?.key != live?.key ||
      old.live?.runtimeType != live?.runtimeType;
}

/// [AppBackdrop] 的一角:同一张背景,只画底部 [solidHeight] + [feather] 这一条,
/// 底部 [solidHeight] 实心,往上 [feather] 缓缓淡出。
///
/// 叠在滚动内容之上、浮动控件(输入条、思考胶囊)之下:内容滑到控件后面时
/// 淡出,控件之间的缝里只露背景,底色不跟着滚动内容闪、也不出现割裂的缝。
/// 不用遮罩去裁内容本身,是因为列表里的玻璃卡片要采样真背景做模糊。
///
/// 渐变和光晕按整屏尺寸算(与 [AppBackdrop] 相同),从页面顶端画起、只留
/// 这一条,所以和真背景严丝合缝;键盘弹起页面变矮时也对得上。要求铺满
/// 整页、和页面左上角对齐。分栏布局里的一栏(宽屏的聊天栏、详情栏)由
/// [BackdropFrame] 告知它在整张背景里的位置,照样对得上。
class BackdropVeil extends StatelessWidget {
  const BackdropVeil({super.key, required this.solidHeight, this.feather = 14, this.glow = true}) : fromTop = false;

  /// 顶部版:从顶边往下 [height] 实心,再往下 [feather] 缓缓淡出(页面顶栏
  /// 后面)。同样要铺满整页、和页面左上角对齐。
  BackdropVeil.top({super.key, required double height, this.feather = 14, this.glow = true})
    : solidHeight = _FixedHeight(height),
      fromTop = true;

  /// 从底边往上实心的高度。由页面布局在排好浮动控件时写入:遮罩画在布局
  /// 之后,不经过重建,这一帧就按新高度画,和控件严丝合缝。
  final ValueListenable<double> solidHeight;

  /// 实心区之外(底部版在上、顶部版在下)的淡出高度。
  final double feather;
  final bool glow;

  /// 顶部版([BackdropVeil.top])。
  final bool fromTop;

  @override
  Widget build(BuildContext context) {
    final s = DshSurfaces.of(context);
    final frame = BackdropFrame.maybeOf(context);
    final live = _BackdropScope.liveOf(context);
    if (live != null) {
      // 动态背景:把同一层背景(同一个控制器 / 引擎)裁成这一条再淡出,内容和
      // 静态图时一样淡进背景本身。
      return IgnorePointer(
        child: _LiveBand(
          solidHeight: solidHeight,
          feather: feather,
          fromTop: fromTop,
          area: frame?.area,
          origin: frame?.origin ?? Offset.zero,
          live: live,
        ),
      );
    }
    final scrimBand = live == null && _BackdropScope.scrimBandOf(context);
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _VeilPainter(
          solidHeight: solidHeight,
          feather: feather,
          fromTop: fromTop,
          backdrop: _BackdropPainter(
            // 视频背景:整页背景每帧重画一次再套遮罩太贵(见 AppBackdrop.liveBand),
            // 这一条改成盖本页底色,底下那段视频照常透出来。
            top: scrimBand ? s.backdropTop.withValues(alpha: AppBackdrop.bandAlpha) : s.backdropTop,
            bottom: scrimBand ? s.backdropBottom.withValues(alpha: AppBackdrop.bandAlpha) : s.backdropBottom,
            glowPrimary: !scrimBand && glow ? s.glowPrimary : null,
            glowSecondary: !scrimBand && glow ? s.glowSecondary : null,
            area: frame?.area ?? MediaQuery.sizeOf(context),
            origin: frame?.origin ?? Offset.zero,
            picture: _BackdropScope.of(context),
          ),
        ),
      ),
    );
  }
}

/// [BackdropVeil] 的动态背景版:同一条带子,画的是 [live] 本身。
class _LiveBand extends StatelessWidget {
  const _LiveBand({
    required this.solidHeight,
    required this.feather,
    required this.fromTop,
    required this.live,
    this.area,
    this.origin = Offset.zero,
  });

  final ValueListenable<double> solidHeight;
  final double feather;
  final bool fromTop;
  final Widget live;

  /// 分栏布局里这一栏在整张背景里的位置,与 [_BackdropPainter] 一致。
  final Size? area;
  final Offset origin;

  @override
  Widget build(BuildContext context) {
    // 整张背景多大:分栏布局由 [BackdropFrame] 告知,否则就是整页。
    final page = area ?? MediaQuery.sizeOf(context);
    final live = this.live;
    // 遮罩本身可能只是页面顶上的一小条(page_frame 的 TopFade):把整页大小的
    // 背景按 -origin 摆回它在页面里的位置,而不是压进这一条里。
    final content = OverflowBox(
      alignment: Alignment.topLeft,
      minWidth: 0,
      minHeight: 0,
      maxWidth: double.infinity,
      maxHeight: double.infinity,
      child: Transform.translate(
        offset: -origin,
        child: SizedBox(width: page.width, height: page.height, child: live),
      ),
    );
    return ValueListenableBuilder<double>(
      valueListenable: solidHeight,
      builder: (context, solid, child) => LayoutBuilder(
        builder: (context, constraints) {
          final band = (solid + feather).clamp(0.0, page.height);
          if (band <= 0 || page.isEmpty) return const SizedBox.shrink();
          final rect = (fromTop
                  ? Rect.fromLTWH(0, 0, page.width, band)
                  : Rect.fromLTWH(0, page.height - band, page.width, band))
              .shift(-origin);
          final fade = (feather / band).clamp(0.0, 1.0);
          // 与 [_VeilPainter] 同一条缓动:实心端 1,淡出端 0。
          const samples = 8;
          final stops = <double>[];
          final alphas = <double>[];
          if (fromTop) {
            stops.add(0);
            alphas.add(1);
          }
          for (var i = 0; i <= samples; i++) {
            final t = i / samples;
            stops.add(fromTop ? 1 - fade + fade * t : fade * t);
            alphas.add(fromTop ? 1 - Curves.easeInOutCubic.transform(t) : Curves.easeInOutCubic.transform(t));
          }
          if (!fromTop) {
            stops.add(1);
            alphas.add(1);
          }
          return ClipRect(
            clipper: _BandClipper(rect),
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (bounds) => LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [for (final alpha in alphas) Colors.black.withValues(alpha: alpha)],
                stops: stops,
              ).createShader(rect),
              child: child,
            ),
          );
        },
      ),
      child: content,
    );
  }
}

/// 只留一条:动态背景版的遮罩按这条带子裁剪。
class _BandClipper extends CustomClipper<Rect> {
  const _BandClipper(this.rect);

  final Rect rect;

  @override
  Rect getClip(Size size) => rect;

  @override
  bool shouldReclip(_BandClipper oldClipper) => oldClipper.rect != rect;
}

/// A fixed height for [BackdropVeil.top].
class _FixedHeight implements ValueListenable<double> {
  const _FixedHeight(this.value);

  @override
  final double value;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  bool operator ==(Object other) => other is _FixedHeight && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// [BackdropVeil] 的一条:底部实心,往上缓缓淡出(顶部版反过来)。
class _VeilPainter extends CustomPainter {
  _VeilPainter({
    required this.solidHeight,
    required this.feather,
    required this.backdrop,
    this.fromTop = false,
  }) : super(repaint: backdrop.picture == null ? solidHeight : Listenable.merge([solidHeight, backdrop.picture!.fade]));

  final ValueListenable<double> solidHeight;
  final double feather;
  final _BackdropPainter backdrop;
  final bool fromTop;

  @override
  void paint(Canvas canvas, Size size) {
    final band = (solidHeight.value + feather).clamp(0.0, size.height);
    if (band <= 0) return;
    final rect = fromTop
        ? Rect.fromLTWH(0, 0, size.width, band)
        : Rect.fromLTWH(0, size.height - band, size.width, band);
    final fade = (feather / band).clamp(0.0, 1.0);
    // Eased ramp: a linear one reads as a crease at both ends.
    const samples = 8;
    final stops = <double>[];
    final alphas = <double>[];
    if (fromTop) {
      stops.add(0);
      alphas.add(1);
    }
    for (var i = 0; i <= samples; i++) {
      final t = i / samples;
      stops.add(fromTop ? 1 - fade + fade * t : fade * t);
      final eased = Curves.easeInOutCubic.transform(t);
      alphas.add(fromTop ? 1 - eased : eased);
    }
    if (!fromTop) {
      stops.add(1);
      alphas.add(1);
    }

    canvas.saveLayer(rect, Paint());
    canvas.clipRect(rect);
    // The whole backdrop from the page's top, so the band lines up with it.
    backdrop.paint(canvas, size);
    canvas.drawRect(
      rect,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [for (final alpha in alphas) Colors.black.withValues(alpha: alpha)],
          stops: stops,
        ).createShader(rect),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_VeilPainter old) =>
      old.solidHeight != solidHeight ||
      old.feather != feather ||
      old.fromTop != fromTop ||
      backdrop.shouldRepaint(old.backdrop);
}

class _BackdropPainter extends CustomPainter {
  _BackdropPainter({
    required this.top,
    required this.bottom,
    this.glowPrimary,
    this.glowSecondary,
    this.area,
    this.origin = Offset.zero,
    this.picture,
  }) : super(repaint: picture?.fade);

  final Color top;
  final Color bottom;
  final Color? glowPrimary;
  final Color? glowSecondary;

  /// The whole backdrop's size when this paints only a band of it.
  final Size? area;

  /// Where the canvas sits inside [area] (a column of a split layout).
  final Offset origin;

  /// A picture in place of the gradient.
  final BackdropPicture? picture;

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final size = area ?? canvasSize;
    if (area != null) {
      // Only the band: CustomPaint does not clip what is drawn outside it.
      canvas.save();
      canvas.clipRect(Offset.zero & canvasSize);
      canvas.translate(-origin.dx, -origin.dy);
    }
    final picture = this.picture;
    if (picture == null) {
      _gradient(canvas, size);
    } else {
      final t = picture.fade.value;
      if (t < 1) _layer(canvas, size, picture.from);
      if (t > 0) {
        final fading = t < 1;
        if (fading) canvas.saveLayer(Offset.zero & size, Paint()..color = Color.fromRGBO(0, 0, 0, t));
        _layer(canvas, size, picture.image);
        if (fading) canvas.restore();
      }
    }
    if (area != null) canvas.restore();
  }

  void _layer(Canvas canvas, Size size, ui.Image? image) {
    if (image == null) {
      _gradient(canvas, size);
      return;
    }
    // Baked to the screen's shape; covers whatever else this is asked to fill.
    final w = image.width.toDouble();
    final h = image.height.toDouble();
    final scale = size.isEmpty ? 1.0 : (w / size.width < h / size.height ? w / size.width : h / size.height);
    final src = Rect.fromCenter(center: Offset(w / 2, h / 2), width: size.width * scale, height: size.height * scale);
    canvas.drawImageRect(image, src, Offset.zero & size, Paint()..filterQuality = FilterQuality.medium);
  }

  void _gradient(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [top, bottom],
        ).createShader(rect),
    );
    final longest = size.longestSide;
    if (glowPrimary case final color?) {
      _glow(canvas, Offset(size.width * 0.92, 0), longest * 0.62, color);
    }
    if (glowSecondary case final color?) {
      _glow(canvas, Offset(0, size.height), longest * 0.55, color);
    }
  }

  void _glow(Canvas canvas, Offset center, double radius, Color color) {
    final bounds = Rect.fromCircle(center: center, radius: radius);
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = RadialGradient(
          colors: [color, color.withValues(alpha: 0)],
          stops: const [0, 1],
        ).createShader(bounds),
    );
  }

  @override
  bool shouldRepaint(_BackdropPainter old) =>
      old.top != top ||
      old.bottom != bottom ||
      old.glowPrimary != glowPrimary ||
      old.glowSecondary != glowSecondary ||
      old.area != area ||
      old.origin != origin ||
      old.picture != picture;
}

/// 动态背景(video / .json)之上的一层本页底色:画面还看得见,压在背景上的
/// 次要文字也不至于糊成一片。
class _LiveScrimPainter extends CustomPainter {
  _LiveScrimPainter({required this.top, required this.bottom, required this.alpha});

  final Color top;
  final Color bottom;
  final double alpha;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [top.withValues(alpha: alpha), bottom.withValues(alpha: alpha * 0.78)],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_LiveScrimPainter old) => old.top != top || old.bottom != bottom || old.alpha != alpha;
}
