// The widget that puts a .json scene on screen: load the file once, decode its
// images at most once, then drive one ticker. The scene is repainted through a
// ChangeNotifier so the widget tree itself never rebuilds per frame.
//
// A scene may be a single .json using data: URIs, or a package (a directory
// unpacked from a `.jsonwall` / `.zip`) whose manifest names pictures and videos
// by relative path. Each 时段 may point at its own video; the video sits behind
// the scene's layers, so glow / image / particles / gradient layers decorate
// footage instead of replacing it.
//
// The engine and the ticker live in [JsonWallpaperHandle] rather than in the
// widget's state because the layer behind the content is drawn more than once:
// the whole screen behind the page, and again inside the band the chat fades its
// list into (see BackdropVeil). Both draw the same handle, so the video/scene is
// decoded and stepped once.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import 'live_wallpaper.dart';
import 'scene_document.dart';
import 'scene_engine.dart';

/// Largest side an image from a scene is decoded at: a 4K texture solely to
/// paint a 30 fps background is wasted memory on a phone.
const int sceneMaxImageSide = 2048;

/// Owns the parsed scene of one .json wallpaper: its images, its engine, the
/// video of the current 时段 and the single ticker that steps them. It starts as
/// soon as it is made and stops when the app leaves the foreground or animations
/// are off.
class JsonWallpaperHandle extends ChangeNotifier with WidgetsBindingObserver {
  JsonWallpaperHandle(this.wallpaper) {
    _ticker = Ticker(_tick);
    WidgetsBinding.instance.addObserver(this);
    unawaited(load());
  }

  JsonWallpaper wallpaper;

  SceneEngine? _engine;
  Map<String, ui.Image> _images = const {};
  late final Ticker _ticker;
  VideoPlayerController? _video;
  SceneVideo? _videoSpec;
  String? _videoPath;
  bool _videoReady = false;
  double _last = 0;
  double _accumulated = 0;
  int _generation = 0;
  bool _animationsEnabled = true;
  bool _disposed = false;

  /// The scene being painted; null until the file is read and parsed.
  SceneEngine? get engine => _engine;

  /// The video of the current 时段, once it is playing.
  VideoPlayerController? get video => _videoReady ? _video : null;

  /// How the video fills the screen.
  BoxFit get videoFit => switch (_videoSpec?.fit) {
    SceneFit.contain => BoxFit.contain,
    SceneFit.fill => BoxFit.fill,
    _ => BoxFit.cover,
  };

  double get videoOpacity => _videoSpec?.opacity ?? 1;

  Directory? get _package => wallpaper.isPackage ? Directory(wallpaper.path) : null;

  /// A screen reader / "remove animations" setting gets one still frame.
  void setAnimationsEnabled(bool enabled) {
    if (_animationsEnabled == enabled) return;
    _animationsEnabled = enabled;
    if (enabled) {
      _start();
      _video?.play();
    } else {
      _ticker.stop();
      _video?.pause();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _start();
        _video?.play();
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _ticker.stop();
        _video?.pause();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _engine?.dispose();
    _disposeImages(_images);
    final video = _video;
    _video = null;
    _videoReady = false;
    _videoPath = null;
    if (video != null) unawaited(video.dispose());
    super.dispose();
  }

  void _start() {
    if (_engine == null || !_animationsEnabled || _ticker.isActive) return;
    _last = 0;
    _accumulated = 0;
    _ticker.start();
  }

  void _tick(Duration elapsed) {
    final engine = _engine;
    if (engine == null) return;
    final now = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    final delta = _last == 0 ? 0.0 : (now - _last).clampDouble(0, 0.1);
    _last = now;
    // 白天 / 黄昏 / 晚上 are picked from the wall clock, not from the ticker.
    final period = ScenePeriod.of(DateTime.now());
    if (period != engine.period) {
      engine.apply(period);
      _syncVideo();
    }
    _accumulated += delta;
    final interval = 1 / engine.document.fpsCap;
    if (_accumulated < interval) return;
    final step = _accumulated;
    _accumulated = 0;
    engine.advance(step);
  }

  Future<void> load() async {
    final generation = ++_generation;
    SceneDocument document;
    try {
      document = SceneDocument.parse(await _readSource());
    } on SceneFormatException catch (error) {
      debugPrint('json wallpaper: ${error.message}');
      _replace(images: const {});
      return;
    } on FileSystemException catch (error) {
      debugPrint('json wallpaper: ${error.message}');
      _replace(images: const {});
      return;
    }
    final images = await _loadImages(document);
    if (_disposed || generation != _generation) {
      _disposeImages(images);
      return;
    }
    final period = ScenePeriod.of(DateTime.now());
    _replace(
      images: images,
      engine: SceneEngine(
        document: document,
        period: period,
        images: images,
        paintBackground: document.videoAt(period) == null,
      ),
    );
  }

  void _replace({required Map<String, ui.Image> images, SceneEngine? engine}) {
    final previous = _images;
    final old = _engine;
    _images = images;
    _engine = engine;
    if (_disposed) {
      engine?.dispose();
      _disposeImages(images);
      return;
    }
    notifyListeners();
    if (old != null) old.dispose();
    _disposeImages(previous);
    _start();
    _syncVideo();
  }

  /// Starts the video the current 时段 asks for, and stops the one it no longer
  /// needs. A period without footage gets the painted background back.
  void _syncVideo() {
    final engine = _engine;
    if (engine == null) return;
    final spec = engine.document.videoAt(engine.period);
    final source = spec == null ? null : _videoSource(spec.src);
    if (source == null) {
      engine.paintBackground = true;
      _closeVideo();
      return;
    }
    if (source == _videoPath && _video != null) {
      engine.paintBackground = !_videoReady;
      return;
    }
    _closeVideo();
    unawaited(_openVideo(source, spec!, engine));
  }

  String? _videoSource(String src) {
    if (src.startsWith(JsonWallpaper.assetPrefix)) return src;
    final package = _package;
    return package == null ? null : '${package.path}/$src';
  }

  Future<void> _openVideo(String source, SceneVideo spec, SceneEngine engine) async {
    _videoPath = source;
    final controller = source.startsWith(JsonWallpaper.assetPrefix)
        ? VideoPlayerController.asset(source.substring(JsonWallpaper.assetPrefix.length))
        : VideoPlayerController.file(File(source));
    try {
      await controller.initialize();
      await controller.setLooping(true);
      await controller.setVolume(0);
      await controller.play();
    } catch (error) {
      // A file the player refuses is not worth taking the wallpaper down for:
      // the layers keep drawing over the painted background.
      debugPrint('json wallpaper video $source: $error');
      await controller.dispose();
      if (_videoPath == source) _videoPath = null;
      engine.paintBackground = true;
      return;
    }
    if (_disposed || _videoPath != source) {
      await controller.dispose();
      return;
    }
    _video = controller;
    _videoSpec = spec;
    _videoReady = true;
    engine.paintBackground = false;
    notifyListeners();
  }

  void _closeVideo() {
    final video = _video;
    _video = null;
    _videoSpec = null;
    _videoReady = false;
    _videoPath = null;
    if (video != null) unawaited(video.dispose());
    if (!_disposed) notifyListeners();
  }

  static void _disposeImages(Map<String, ui.Image> images) {
    for (final image in images.values) {
      image.dispose();
    }
  }

  Future<Map<String, ui.Image>> _loadImages(SceneDocument document) async {
    final images = <String, ui.Image>{};
    for (final src in _imageSources(document)) {
      try {
        images[src] = await _decode(await _readBytes(src));
      } catch (error) {
        // One unreadable image must not take the whole wallpaper down; the
        // layer that wanted it simply has nothing to draw.
        debugPrint('json wallpaper image $src: $error');
      }
    }
    return images;
  }

  static Set<String> _imageSources(SceneDocument document) {
    final sources = <String>{};
    void walk(List<SceneLayer> layers) {
      for (final layer in layers) {
        switch (layer) {
          case SceneImageLayer():
            sources.add(layer.src);
          case SceneGroupLayer():
            walk(layer.children);
          default:
            break;
        }
      }
    }

    walk(document.scene.layers);
    for (final scene in document.periods.values) {
      walk(scene.layers);
    }
    return sources;
  }

  Future<String> _readSource() async {
    final path = wallpaper.path;
    if (path.startsWith(JsonWallpaper.assetPrefix)) {
      return rootBundle.loadString(path.substring(JsonWallpaper.assetPrefix.length));
    }
    final package = _package;
    if (package != null) {
      return File('${package.path}/${JsonWallpaper.manifestName}').readAsString();
    }
    return File(path).readAsString();
  }

  Future<Uint8List> _readBytes(String src) async {
    if (src.startsWith('asset:')) {
      return (await rootBundle.load(src.substring('asset:'.length))).buffer.asUint8List();
    }
    if (src.startsWith('data:')) {
      final comma = src.indexOf(',');
      if (comma < 0) throw const SceneFormatException('data URI 缺少逗号');
      return base64Decode(src.substring(comma + 1));
    }
    final package = _package;
    if (package != null) return File('${package.path}/$src').readAsBytes();
    throw SceneFormatException('无法读取图片：$src');
  }

  /// Decodes with a 2048 px cap on the long side, so a huge PNG in a scene
  /// cannot allocate a 4K texture.
  static Future<ui.Image> _decode(Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final longest = descriptor.width > descriptor.height ? descriptor.width : descriptor.height;
    final ui.Codec codec;
    if (longest > sceneMaxImageSide) {
      codec = descriptor.width >= descriptor.height
          ? await descriptor.instantiateCodec(targetWidth: sceneMaxImageSide)
          : await descriptor.instantiateCodec(targetHeight: sceneMaxImageSide);
    } else {
      codec = await descriptor.instantiateCodec();
    }
    final frame = await codec.getNextFrame();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    return frame.image;
  }
}

/// Paints [handle]'s scene, switching between its 白天 / 黄昏 / 晚上 looks as the
/// system clock crosses 05:00, 07:00, 16:00 and 19:00. When the 时段 names a
/// video, the footage is put behind the painted layers.
class JsonWallpaperView extends StatelessWidget {
  const JsonWallpaperView({super.key, required this.handle});

  final JsonWallpaperHandle handle;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: handle,
      builder: (context, _) {
        final engine = handle.engine;
        if (engine == null) return const SizedBox.expand();
        final video = handle.video;
        final ready = video != null && video.value.isInitialized && !video.value.size.isEmpty;
        return RepaintBoundary(
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (ready)
                ClipRect(
                  child: Opacity(
                    opacity: handle.videoOpacity,
                    child: FittedBox(
                      fit: handle.videoFit,
                      clipBehavior: Clip.hardEdge,
                      child: SizedBox(
                        width: video.value.size.width,
                        height: video.value.size.height,
                        child: VideoPlayer(video),
                      ),
                    ),
                  ),
                ),
              CustomPaint(painter: _ScenePainter(engine)),
            ],
          ),
        );
      },
    );
  }
}

class _ScenePainter extends CustomPainter {
  _ScenePainter(this.engine) : super(repaint: engine);

  final SceneEngine engine;

  @override
  void paint(Canvas canvas, Size size) => engine.paint(canvas, size);

  @override
  bool shouldRepaint(_ScenePainter oldDelegate) => oldDelegate.engine != engine;
}
