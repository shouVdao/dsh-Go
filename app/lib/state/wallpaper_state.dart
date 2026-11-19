// 设置 › 主题 › 壁纸: the user's own wallpaper (lib/wallpaper/custom_wallpaper.dart), whether it's
// the one in use, and the picture baked for the screen it's on. Also the two live sources:
// a looping video and a .json scene (lib/wallpaper/live_wallpaper.dart).

import 'dart:ui' as ui;
import 'dart:ui' show Brightness;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../performance/performance_state.dart';
import '../wallpaper/custom_wallpaper.dart';
import '../wallpaper/live_wallpaper.dart';
import '../wallpaper/wallpaper_import.dart';
import '../wallpaper/wallpaper_render.dart';

export '../wallpaper/wallpaper_import.dart' show LaunchImportProblem;

final wallpaperImportProvider = Provider<WallpaperImport>((ref) => WallpaperImport());

final liveWallpaperImportProvider = Provider<LiveWallpaperImport>((ref) => LiveWallpaperImport());

/// 四种壁纸:默认渐变、自定义图片、循环视频、.json 场景。后两项来自
/// [videoWallpaperProvider] / [jsonWallpaperProvider],并各自记住自己的文件。
enum WallpaperKind {
  gradient,
  image,
  video,
  json;

  static WallpaperKind? parse(Object? value) {
    for (final kind in WallpaperKind.values) {
      if (kind.name == value) return kind;
    }
    return null;
  }
}

/// 现在用的是哪种壁纸。「自定义」之外的两种动态壁纸不改自定义图片的开关,
/// 切回来时那张图还在。
final wallpaperKindProvider = AsyncNotifierProvider<WallpaperKindController, WallpaperKind>(
  WallpaperKindController.new,
);

class WallpaperKindController extends AsyncNotifier<WallpaperKind> {
  static const String prefsKey = 'wallpaper_kind';

  @override
  Future<WallpaperKind> build() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = WallpaperKind.parse(prefs.getString(prefsKey));
    if (stored != null) return stored;
    // 旧版本只记了「用不用自定义图片」,升级后照旧。
    final picture = await CustomWallpaper.load(prefs);
    return picture != null && picture.on ? WallpaperKind.image : WallpaperKind.gradient;
  }

  Future<void> use(WallpaperKind kind) async {
    if (state.value == kind) return;
    state = AsyncData(kind);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, kind.name);
  }
}

/// Bakes for the backdrop and the settings' small phones; keeps the last decoded picture.
final wallpaperRendererProvider = Provider<WallpaperRenderer>((ref) {
  final renderer = WallpaperRenderer();
  ref.onDispose(renderer.release);
  return renderer;
});

/// The stored wallpaper (null: none chosen yet, or its file is gone).
final customWallpaperProvider = AsyncNotifierProvider<CustomWallpaperController, CustomWallpaper?>(
  CustomWallpaperController.new,
);

class CustomWallpaperController extends AsyncNotifier<CustomWallpaper?> {
  @override
  Future<CustomWallpaper?> build() => CustomWallpaper.load();

  /// The system picker; the pick becomes the wallpaper in use. Null when it did, else why not
  /// ([LaunchImportProblem.cancelled] included).
  Future<LaunchImportProblem?> choose() async {
    final previous = await _current;
    final (wallpaper, problem) = await ref.read(wallpaperImportProvider).pick(previous: previous);
    if (wallpaper == null) return problem ?? LaunchImportProblem.unreadable;
    await _store(wallpaper);
    // Only now: until the new one is saved, the old file is the one the next launch reads.
    if (previous != null && previous.path != wallpaper.path) await WallpaperImport.removeFile(previous.path);
    return null;
  }

  /// The stored wallpaper, once it's read.
  Future<CustomWallpaper?> get _current async {
    if (state.hasValue) return state.value;
    try {
      return await future;
    } catch (_) {
      return null;
    }
  }

  /// The custom one in use (true) or the default backdrop (false); the picture stays either way.
  Future<void> use(bool custom) async {
    final current = await _current;
    if (current == null || current.on == custom) return;
    await _store(current.copyWith(on: custom));
  }

  /// Where the screen sits in the picture.
  Future<void> frame({required double zoom, required double alignX, required double alignY}) async {
    final current = await _current;
    if (current == null) return;
    await _store(
      current.copyWith(
        zoom: zoom.clamp(1.0, CustomWallpaper.maxZoom),
        alignX: alignX.clamp(-1.0, 1.0),
        alignY: alignY.clamp(-1.0, 1.0),
      ),
    );
  }

  Future<void> setBlur(double blur) async {
    final current = await _current;
    if (current == null || current.blur == blur) return;
    await _store(current.copyWith(blur: blur.clamp(0.0, 1.0)));
  }

  /// 提亮 (light mode) or 压暗 (dark mode).
  Future<void> setTone(Brightness brightness, double tone) async {
    final current = await _current;
    if (current == null || current.toneFor(brightness) == tone) return;
    await _store(current.withTone(brightness, tone.clamp(0.0, 1.0)));
  }

  Future<void> _store(CustomWallpaper wallpaper) async {
    state = AsyncData(wallpaper);
    await CustomWallpaper.save(wallpaper);
  }
}

/// 循环视频壁纸:私有目录里的那一份,以及「填满 / 居中」和画面位置。
final videoWallpaperProvider = AsyncNotifierProvider<VideoWallpaperController, VideoWallpaper?>(
  VideoWallpaperController.new,
);

class VideoWallpaperController extends AsyncNotifier<VideoWallpaper?> {
  @override
  Future<VideoWallpaper?> build() => VideoWallpaper.load();

  /// 系统选择器选了新视频;null 表示换好了,否则是原因([LaunchImportProblem.cancelled] 也在内)。
  Future<LaunchImportProblem?> choose() async {
    final previous = await _current;
    final (wallpaper, problem) = await ref.read(liveWallpaperImportProvider).pickVideo(previous: previous);
    if (wallpaper == null) return problem ?? LaunchImportProblem.unreadable;
    await _store(wallpaper);
    return null;
  }

  Future<VideoWallpaper?> get _current async {
    if (state.hasValue) return state.value;
    try {
      return await future;
    } catch (_) {
      return null;
    }
  }

  Future<void> setFit(VideoFit fit) async {
    final current = await _current;
    if (current == null || current.fit == fit) return;
    await _store(current.copyWith(fit: fit));
  }

  /// 填满时画面往哪边挪(±1)。
  Future<void> frame({required double alignX, required double alignY}) async {
    final current = await _current;
    if (current == null) return;
    await _store(current.copyWith(alignX: alignX, alignY: alignY));
  }

  Future<void> _store(VideoWallpaper wallpaper) async {
    state = AsyncData(wallpaper);
    await VideoWallpaper.save(wallpaper);
  }
}

/// .json 场景壁纸;没选过文件时用内置示例。
final jsonWallpaperProvider = AsyncNotifierProvider<JsonWallpaperController, JsonWallpaper?>(
  JsonWallpaperController.new,
);

class JsonWallpaperController extends AsyncNotifier<JsonWallpaper?> {
  @override
  Future<JsonWallpaper?> build() async => await JsonWallpaper.load() ?? const JsonWallpaper(JsonWallpaper.bundled);

  /// 换一个 .json 文件。失败原因(带字段名,方便改文件)在第二个返回值里。
  Future<(LaunchImportProblem?, String?)> choose() async {
    final previous = state.value;
    final (wallpaper, problem, detail) = await ref.read(liveWallpaperImportProvider).pickJson(previous: previous);
    if (wallpaper == null) return (problem ?? LaunchImportProblem.unreadable, detail);
    state = AsyncData(wallpaper);
    await JsonWallpaper.save(wallpaper);
    return (null, null);
  }
}

/// The wallpaper baked for [WallpaperFrame]; null: the default backdrop (none chosen, switched
/// off, or the picture can't be read — the page never breaks over it).
final wallpaperImageProvider = FutureProvider.autoDispose.family<ui.Image?, WallpaperFrame>((ref, frame) async {
  final CustomWallpaper? wallpaper;
  try {
    wallpaper = await ref.watch(customWallpaperProvider.future);
  } catch (_) {
    return null;
  }
  if (wallpaper == null || !wallpaper.on) return null;
  final lightweight = ref.watch(performanceDefaultsProvider.select((p) => p.lightweight));
  final image = await ref.read(wallpaperRendererProvider).bake(wallpaper, frame.copyWith(lightweight: lightweight));
  if (!ref.mounted) {
    image?.dispose();
    return null;
  }
  if (image != null) ref.onDispose(image.dispose);
  return image;
});

/// Bakes a page's own picture ([sceneImageProvider]); apart from [wallpaperRendererProvider], so
/// the app's wallpaper stays decoded meanwhile.
final _sceneRendererProvider = Provider.autoDispose<WallpaperRenderer>((ref) {
  final renderer = WallpaperRenderer();
  ref.onDispose(renderer.release);
  return renderer;
});

/// A page's own picture (a tavern chat's background, `WallpaperBackdrop.scene`) baked for its
/// frame the way the wallpaper is; null when it can't be read.
final sceneImageProvider = FutureProvider.autoDispose.family<ui.Image?, (CustomWallpaper, WallpaperFrame)>((
  ref,
  key,
) async {
  final (picture, frame) = key;
  final lightweight = ref.watch(performanceDefaultsProvider.select((p) => p.lightweight));
  final image = await ref.watch(_sceneRendererProvider).bake(picture, frame.copyWith(lightweight: lightweight));
  if (!ref.mounted) {
    image?.dispose();
    return null;
  }
  if (image != null) ref.onDispose(image.dispose);
  return image;
});
