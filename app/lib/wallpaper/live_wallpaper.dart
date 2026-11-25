// 动态壁纸的两种来源：循环视频和一个 .json 场景文件。两者都放进 App 自己的
// `<support>/wallpaper/` 目录（和自定义图片壁纸共用），prefs 里只存元数据。
// 选文件走 file_picker：App 自己加固过的原生选择通道只收 30 MB 以内，装不下视频。
//
// 场景有两种形态：单个 .json 文件（老样子，素材用 data: URI 内嵌），或者一个
// `.jsonwall` / `.zip` 压缩包——包里有 manifest 和它引用的图片、视频，素材按相对
// 路径写就行。压缩包导入时解到 `<support>/wallpaper/scene-<时间戳>/`，prefs 里存
// 目录路径。

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'scene_document.dart';
import 'wallpaper_import.dart' show LaunchImportProblem, WallpaperImport;

/// 视频怎么放进屏幕：填满（裁掉多出来的部分）或完整显示（留边）。
enum VideoFit {
  fill,
  center;

  static VideoFit parse(Object? value) {
    for (final fit in VideoFit.values) {
      if (fit.name == value) return fit;
    }
    return VideoFit.fill;
  }
}

/// 循环播放的视频壁纸。
@immutable
class VideoWallpaper {
  const VideoWallpaper({required this.path, this.fit = VideoFit.fill, this.alignX = 0, this.alignY = 0});

  /// 私有目录里的文件；用户选的原文件不会被引用。
  final String path;
  final VideoFit fit;

  /// -1…1：填满时画面可以往哪边挪（-1 = 左/上，1 = 右/下）。
  final double alignX;
  final double alignY;

  /// 300 MB。再大的视频拷进私有目录没有意义，解码也撑不住。
  static const int maxBytes = 300 * 1024 * 1024;
  static const String prefsKey = 'wallpaper_video';

  VideoWallpaper copyWith({VideoFit? fit, double? alignX, double? alignY}) => VideoWallpaper(
    path: path,
    fit: fit ?? this.fit,
    alignX: sceneClamp(alignX ?? this.alignX, -1, 1),
    alignY: sceneClamp(alignY ?? this.alignY, -1, 1),
  );

  Map<String, Object?> toJson() => {'path': path, 'fit': fit.name, 'alignX': alignX, 'alignY': alignY};

  factory VideoWallpaper.fromJson(Map<Object?, Object?> json) => VideoWallpaper(
    path: json['path'] as String,
    fit: VideoFit.parse(json['fit']),
    alignX: sceneClamp((json['alignX'] as num?)?.toDouble() ?? 0, -1, 1),
    alignY: sceneClamp((json['alignY'] as num?)?.toDouble() ?? 0, -1, 1),
  );

  /// The stored wallpaper, or null when there is none (or its file is gone).
  static Future<VideoWallpaper?> load([SharedPreferences? prefs]) async {
    final store = prefs ?? await SharedPreferences.getInstance();
    final raw = store.getString(prefsKey);
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final wallpaper = VideoWallpaper.fromJson(json);
      return File(wallpaper.path).existsSync() ? wallpaper : null;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  static Future<void> save(VideoWallpaper? wallpaper) async {
    final store = await SharedPreferences.getInstance();
    if (wallpaper == null) {
      await store.remove(prefsKey);
    } else {
      await store.setString(prefsKey, jsonEncode(wallpaper.toJson()));
    }
  }

  @override
  bool operator ==(Object other) =>
      other is VideoWallpaper &&
      other.path == path &&
      other.fit == fit &&
      other.alignX == alignX &&
      other.alignY == alignY;

  @override
  int get hashCode => Object.hash(path, fit, alignX, alignY);
}

/// 一个 .json 场景文件、一个 `.jsonwall` / `.zip` 场景包（目录），或者应用内置的
/// 示例场景（`asset:` 开头）。
@immutable
class JsonWallpaper {
  const JsonWallpaper(this.path);

  /// 单文件场景的 .json，或场景包解压出来的目录。
  final String path;

  /// 内置示例：没选过文件时 .json 壁纸就用它，点一下立刻有画面。
  static const String bundled = 'asset:assets/wallpapers/aurora.json';
  static const String assetPrefix = 'asset:';

  /// 场景包里必须先有这个文件（也接受包内唯一的 .json）。
  static const String manifestName = 'manifest.json';

  /// 单个 .json：20 MB。场景是描述，不是素材；图片素材在文件里用 data URI。
  static const int maxBytes = 20 * 1024 * 1024;

  /// 压缩包：300 MB。包里有视频，和循环视频壁纸的上限一致。
  static const int maxPackageBytes = 300 * 1024 * 1024;

  /// 压缩包里最多 500 个文件、单个 120 MB（解压后）。
  static const int maxPackageFiles = 500;
  static const int maxPackageEntryBytes = 120 * 1024 * 1024;

  static const String prefsKey = 'wallpaper_json';

  bool get isBundled => path.startsWith(assetPrefix);

  /// 场景包（解压后的目录），而不是单个 .json 文件。
  bool get isPackage => !isBundled && FileSystemEntity.isDirectorySync(path);

  /// The stored wallpaper, or null when there is none (or its files are gone).
  static Future<JsonWallpaper?> load([SharedPreferences? prefs]) async {
    final store = prefs ?? await SharedPreferences.getInstance();
    final raw = store.getString(prefsKey);
    if (raw == null) return null;
    final wallpaper = JsonWallpaper(raw);
    if (wallpaper.isBundled) return wallpaper;
    final entity = FileSystemEntity.typeSync(wallpaper.path);
    if (entity == FileSystemEntityType.directory) {
      return File('${wallpaper.path}/$manifestName').existsSync() ? wallpaper : null;
    }
    return entity == FileSystemEntityType.file ? wallpaper : null;
  }

  static Future<void> save(JsonWallpaper? wallpaper) async {
    final store = await SharedPreferences.getInstance();
    if (wallpaper == null) {
      await store.remove(prefsKey);
    } else {
      await store.setString(prefsKey, wallpaper.path);
    }
  }

  @override
  bool operator ==(Object other) => other is JsonWallpaper && other.path == path;

  @override
  int get hashCode => path.hashCode;
}

/// Picks a video or a scene file and keeps it in the app's own directory.
class LiveWallpaperImport {
  LiveWallpaperImport({Future<Directory> Function()? directory, DateTime Function()? now})
    : directory = directory ?? WallpaperImport.wallpaperDirectory,
      now = now ?? DateTime.now;

  final Future<Directory> Function() directory;
  final DateTime Function() now;

  /// 系统选择器（视频）→ 大小/容器检查 → 拷进私有目录。
  Future<(VideoWallpaper?, LaunchImportProblem?)> pickVideo({VideoWallpaper? previous}) async {
    final picked = await FilePicker.pickFile(type: FileType.video);
    if (picked == null) return (null, LaunchImportProblem.cancelled);
    final length = picked.lengthSync() ?? await picked.length();
    if (length != null && length > VideoWallpaper.maxBytes) {
      await _discard(picked.path);
      return (null, LaunchImportProblem.overLimit);
    }
    final dir = await directory();
    final stamp = now().microsecondsSinceEpoch;
    final staged = File('${dir.path}/video-$stamp.part');
    if (!await _copy(picked.readAsByteStream(), staged)) {
      await _delete(staged.path);
      await _discard(picked.path);
      return (null, LaunchImportProblem.unreadable);
    }
    final extension = await _videoExtension(staged.path);
    if (extension == null) {
      await _delete(staged.path);
      await _discard(picked.path);
      return (null, LaunchImportProblem.unsupported);
    }
    final target = '${dir.path}/video-$stamp.$extension';
    await staged.rename(target);
    await _discard(picked.path);
    final wallpaper = VideoWallpaper(
      path: target,
      fit: previous?.fit ?? VideoFit.fill,
      alignX: previous?.alignX ?? 0,
      alignY: previous?.alignY ?? 0,
    );
    if (previous != null && previous.path != target) await WallpaperImport.removeFile(previous.path);
    await VideoWallpaper.save(wallpaper);
    return (wallpaper, null);
  }

  /// 系统选择器（.json / .jsonwall / .zip）→ 大小上限 → 解析一遍确认能用 →
  /// 拷进私有目录（压缩包解压成目录）。解析失败时第三个值是给用户看的失败原因
  /// （带字段名，方便改文件）。
  ///
  /// 选择器不用扩展名过滤：Android 的 MimeTypeMap 没有 `jsonwall`，插件会把这个
  /// 扩展名从 EXTRA_MIME_TYPES 里剔掉，DocumentsUI 便按 `application/octet-stream`
  /// 把 `.jsonwall` 一并灰掉（只有 `application/json`、`application/zip` 可选）。
  /// 所以这里放开成任意文件，靠 [adopt] 读文件头自己认：zip 魔数就是场景包，
  /// 其余按 UTF-8 的 `.json` 解析，扩展名只用来给错误提示分类。
  Future<(JsonWallpaper?, LaunchImportProblem?, String?)> pickJson({JsonWallpaper? previous}) async {
    final picked = await FilePicker.pickFile(type: FileType.any);
    if (picked == null) return (null, LaunchImportProblem.cancelled, null);
    final path = picked.path;
    if (path == null) return (null, LaunchImportProblem.unreadable, null);
    final result = await adopt(File(path), previous: previous);
    await _discard(path);
    return result;
  }

  /// Keeps a private copy of [source]: a plain `.json` as a file, a zip package
  /// unpacked into a directory. Two limits, because the two forms are different
  /// things: 20 MB of description for a single file, 300 MB of footage for a
  /// package. Split out of [pickJson] so tests do not need the system picker.
  @visibleForTesting
  Future<(JsonWallpaper?, LaunchImportProblem?, String?)> adopt(File source, {JsonWallpaper? previous}) async {
    final int length;
    try {
      length = await source.length();
    } on FileSystemException {
      return (null, LaunchImportProblem.unreadable, null);
    }
    if (await _isZip(source)) {
      if (length > JsonWallpaper.maxPackageBytes) return (null, LaunchImportProblem.overLimit, null);
      return _adoptPackage(source, previous: previous);
    }
    if (length > JsonWallpaper.maxBytes) return (null, LaunchImportProblem.tooLarge, null);
    return _adoptJson(source, previous: previous);
  }

  Future<(JsonWallpaper?, LaunchImportProblem?, String?)> _adoptJson(File source, {JsonWallpaper? previous}) async {
    // 选择器不过滤扩展名（见 [pickJson]），这里补一道：不是 zip、也不是 .json 的
    // 文件直接说清楚，别让用户以为壁纸本身坏了。
    if (_extensionOf(source.path) != 'json') {
      return (null, LaunchImportProblem.unsupported, '只支持 .json 文件或场景包（.jsonwall / .zip）');
    }
    final bytes = await source.readAsBytes();
    final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      return (null, LaunchImportProblem.unsupported, '文件不是 UTF-8 文本');
    }
    try {
      SceneDocument.parse(text);
    } on SceneFormatException catch (error) {
      return (null, LaunchImportProblem.unsupported, error.message);
    }
    final dir = await directory();
    final target = '${dir.path}/scene-${now().microsecondsSinceEpoch}.json';
    await File(target).writeAsBytes(bytes, flush: true);
    final wallpaper = JsonWallpaper(target);
    await _replacePrevious(previous, target);
    await JsonWallpaper.save(wallpaper);
    return (wallpaper, null, null);
  }

  /// Unpacks the zip beside the other wallpapers, then checks what the manifest
  /// asks for: every relative path it names has to exist in the package, or the
  /// wallpaper would show a hole the moment it is used.
  Future<(JsonWallpaper?, LaunchImportProblem?, String?)> _adoptPackage(File source, {JsonWallpaper? previous}) async {
    final dir = await directory();
    final target = Directory('${dir.path}/scene-${now().microsecondsSinceEpoch}');
    try {
      final problem = await _extract(source, target);
      if (problem != null) {
        await _deleteTree(target.path);
        return (null, LaunchImportProblem.unsupported, problem);
      }
      final manifest = _manifestOf(target);
      if (manifest == null) {
        await _deleteTree(target.path);
        return (null, LaunchImportProblem.unsupported, '压缩包里没有 ${JsonWallpaper.manifestName}');
      }
      final document = SceneDocument.parse(await manifest.readAsString());
      // The runtime always opens `manifest.json`; a package whose only .json has
      // another name gets a copy under the expected one.
      final canonical = File('${target.path}/${JsonWallpaper.manifestName}');
      if (manifest.path != canonical.path) await manifest.copy(canonical.path);
      final missing = document.sources.where((src) => !File('${target.path}/$src').existsSync()).toList();
      if (missing.isNotEmpty) {
        await _deleteTree(target.path);
        return (null, LaunchImportProblem.unsupported, '压缩包里缺少 ${missing.first}');
      }
    } on SceneFormatException catch (error) {
      await _deleteTree(target.path);
      return (null, LaunchImportProblem.unsupported, error.message);
    } on FileSystemException catch (error) {
      await _deleteTree(target.path);
      return (null, LaunchImportProblem.unreadable, error.message);
    }
    final wallpaper = JsonWallpaper(target.path);
    await _replacePrevious(previous, target.path);
    await JsonWallpaper.save(wallpaper);
    return (wallpaper, null, null);
  }

  static Future<void> _replacePrevious(JsonWallpaper? previous, String target) async {
    if (previous == null || previous.isBundled || previous.path == target) return;
    await _deleteTree(previous.path);
  }

  /// Writes every file of the zip under [target]. Returns a message for the user
  /// when the package is not one we can unpack; the caller removes [target].
  static Future<String?> _extract(File source, Directory target) async {
    final input = InputFileStream(source.path);
    try {
      final Archive archive;
      try {
        archive = ZipDecoder().decodeStream(input);
      } on ArchiveException catch (error) {
        return '压缩包打不开：${error.message}';
      }
      if (archive.files.length > JsonWallpaper.maxPackageFiles) {
        return '压缩包里的文件太多（最多 ${JsonWallpaper.maxPackageFiles} 个）';
      }
      final int compressed;
      try {
        compressed = await source.length();
      } on FileSystemException {
        return '压缩包读不出来';
      }
      var total = 0;
      for (final file in archive) {
        if (!file.isFile) continue;
        final name = _entryName(file.name);
        if (name == null) return '压缩包里有非法路径：${file.name}';
        if (file.size > JsonWallpaper.maxPackageEntryBytes) {
          return '包里的 ${file.name} 超过 ${JsonWallpaper.maxPackageEntryBytes ~/ (1024 * 1024)} MB';
        }
        total += file.size;
        if (total > JsonWallpaper.maxPackageBytes) {
          return '解压后超过 ${JsonWallpaper.maxPackageBytes ~/ (1024 * 1024)} MB';
        }
        if (compressed > 0 && total > compressed * 100) return '压缩比异常，拒绝解压';
        final out = File('${target.path}/$name');
        await out.parent.create(recursive: true);
        final sink = OutputFileStream(out.path);
        try {
          file.writeContent(sink);
        } finally {
          sink.closeSync();
        }
      }
      return null;
    } finally {
      input.closeSync();
    }
  }

  /// A zip entry that is safe to write: forward slashes, no absolute path, no
  /// `..`. Everything else makes the whole package invalid.
  static String? _entryName(String name) {
    final path = name.replaceAll('\\', '/');
    if (path.isEmpty || path.startsWith('/')) return null;
    for (final part in path.split('/')) {
      if (part.isEmpty || part == '.' || part == '..') return null;
    }
    return path;
  }

  /// The manifest: `manifest.json` at the root, or the only `.json` sitting
  /// there (so a hand-made package with `scene.json` still works).
  static File? _manifestOf(Directory package) {
    final named = File('${package.path}/${JsonWallpaper.manifestName}');
    if (named.existsSync()) return named;
    final roots = package
        .listSync()
        .whereType<File>()
        .where((file) => file.path.toLowerCase().endsWith('.json'))
        .toList();
    return roots.length == 1 ? roots.single : null;
  }

  static Future<bool> _isZip(File source) async {
    RandomAccessFile? handle;
    try {
      handle = await source.open();
      final head = await handle.read(4);
      return head.length >= 4 && head[0] == 0x50 && head[1] == 0x4B && head[2] == 0x03 && head[3] == 0x04;
    } on FileSystemException {
      return false;
    } finally {
      await handle?.close();
    }
  }

  static Future<void> _deleteTree(String path) async {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: true);
    } else if (type == FileSystemEntityType.file) {
      await File(path).delete();
    }
  }

  static Future<bool> _copy(Stream<List<int>> source, File target) async {
    final sink = target.openWrite();
    try {
      await for (final chunk in source) {
        sink.add(chunk);
      }
      return true;
    } on FileSystemException {
      return false;
    } finally {
      await sink.close();
    }
  }

  static Future<void> _delete(String path) async {
    final file = File(path);
    if (file.existsSync()) await file.delete();
  }

  /// 小写的扩展名，没有扩展名时是空串（`scene.jsonwall` → `jsonwall`）。
  static String _extensionOf(String path) {
    final slash = path.lastIndexOf(RegExp(r'[/\\]'));
    final name = slash < 0 ? path : path.substring(slash + 1);
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  /// MP4/MOV（`ftyp` box）或 WebM/MKV（EBML 头）；其他容器播放器也放不了，
  /// 所以在留下文件之前就拒掉。
  static Future<String?> _videoExtension(String path) async {
    RandomAccessFile? handle;
    try {
      handle = await File(path).open();
      return videoExtensionOf(await handle.read(12));
    } on FileSystemException {
      return null;
    } finally {
      await handle?.close();
    }
  }

  /// file_picker 会先把选中的文件拷进 App 的缓存目录；自己拷完就删掉那一份，
  /// 免得一个 200 MB 的视频在手机上存两遍。用户自己的原文件不碰。
  static Future<void> _discard(String? path) async {
    if (path == null) return;
    try {
      final cache = await getTemporaryDirectory();
      if (!path.startsWith(cache.path)) return;
      await _delete(path);
    } on FileSystemException {
      // A cache file that won't delete is the system's to clean up.
    }
  }
}

/// 视频文件头（前 12 字节）能认出的容器扩展名；认不出就是 null。
@visibleForTesting
String? videoExtensionOf(Uint8List head) {
  if (head.length >= 8 && ascii.decode(head.sublist(4, 8), allowInvalid: true) == 'ftyp') return 'mp4';
  if (head.length >= 4 && head[0] == 0x1A && head[1] == 0x45 && head[2] == 0xDF && head[3] == 0xA3) return 'webm';
  return null;
}
