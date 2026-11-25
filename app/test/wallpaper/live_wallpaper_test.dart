// 设置 › 主题 › 壁纸 › 循环动态壁纸 / .json 动态壁纸: the second row of phones, the rows each one
// opens, and the two models behind them. The video and the scene keep their own prefs keys, so
// 默认 / 自定义 keep working beside them (the picture stays chosen / turned off on its own).

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/wallpaper_state.dart';
import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/ui/settings/appearance/appearance_page.dart' show PickerGrid;
import 'package:dsh_app/ui/settings/appearance/wallpaper_section.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:dsh_app/wallpaper/custom_wallpaper.dart';
import 'package:dsh_app/wallpaper/live_wallpaper.dart';
import 'package:dsh_app/wallpaper/scene_document.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import 'support.dart';

class _Live extends LiveWallpaperImport {
  _Live() : super(directory: () async => Directory.systemTemp);

  VideoWallpaper? video;
  JsonWallpaper? json;
  int videos = 0;
  int scenes = 0;

  @override
  Future<(VideoWallpaper?, LaunchImportProblem?)> pickVideo({VideoWallpaper? previous}) async {
    videos++;
    return (video, video == null ? LaunchImportProblem.cancelled : null);
  }

  @override
  Future<(JsonWallpaper?, LaunchImportProblem?, String?)> pickJson({JsonWallpaper? previous}) async {
    scenes++;
    return (json, null, null);
  }
}

Widget _page() => Scaffold(
  body: SafeArea(
    child: ListView(
      children: [
        Builder(
          builder: (context) => SettingsSection(
            title: '壁纸',
            footer: Text(context.l10n.wallpaperFooter),
            children: const [WallpaperSection()],
          ),
        ),
      ],
    ),
  ),
);

/// Real I/O (prefs, the picture's bake) lands a frame at a time; a few real-async rounds then a
/// settled clock is enough for the provider state and the reveal.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  late _Live live;
  late Directory folder;

  setUp(() async {
    live = _Live();
    folder = await Directory.systemTemp.createTemp('live-wallpaper-test');
  });

  tearDown(() => folder.delete(recursive: true));

  Future<void> pump(
    WidgetTester tester, {
    CustomWallpaper? stored,
    VideoWallpaper? video,
    JsonWallpaper? json,
    WallpaperKind? kind,
    Brightness brightness = Brightness.light,
  }) async {
    SharedPreferences.setMockInitialValues({
      if (stored != null) CustomWallpaper.prefsKey: jsonOf(stored),
      if (video != null) VideoWallpaper.prefsKey: jsonEncode(video.toJson()),
      if (json != null) JsonWallpaper.prefsKey: json.path,
      if (kind != null) WallpaperKindController.prefsKey: kind.name,
    });
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: _page(),
        brightness: brightness,
        overrides: [liveWallpaperImportProvider.overrideWithValue(live)],
      ),
    );
    await settle(tester);
  }

  Rect screenOf(WidgetTester tester, String key) =>
      tester.getRect(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(ClipRSuperellipse)));

  Rect cardOf(WidgetTester tester, String key) =>
      tester.getRect(find.ancestor(of: find.byKey(ValueKey(key)), matching: find.byType(SheetGroup)));

  bool selected(WidgetTester tester, String key) =>
      tester.getSemantics(find.byKey(ValueKey(key))).getSemanticsData().flagsCollection.isSelected ==
      ui.Tristate.isTrue;

  Finder inTile(String key, String text) => find.descendant(of: find.byKey(ValueKey(key)), matching: find.text(text));

  group('the second row', () {
    testWidgets('循环动态壁纸 and .json 动态壁纸: the same phones, a third of the card, 12 apart', (tester) async {
      await pump(tester);
      final card = cardOf(tester, 'wallpaper-video');
      final a = screenOf(tester, 'wallpaper-video');
      final b = screenOf(tester, 'wallpaper-json');
      final upper = screenOf(tester, 'wallpaper-default');
      expect(a.left - card.left, moreOrLessEquals(card.right - b.right, epsilon: 0.01));
      expect(b.left - a.right, moreOrLessEquals(PickerGrid.gap, epsilon: 0.01));
      expect(a.width, moreOrLessEquals((card.width - 2 * PickerGrid.inset - 2 * PickerGrid.gap) / 3, epsilon: 0.01));
      expect(b.width, moreOrLessEquals(a.width, epsilon: 0.01));
      expect(a.top, b.top);
      expect(a.top, greaterThan(upper.bottom));
      expect(tester.getCenter(find.text('循环动态壁纸').last).dx, moreOrLessEquals(a.center.dx, epsilon: 0.01));
      expect(tester.getCenter(find.text('.json 动态壁纸').last).dx, moreOrLessEquals(b.center.dx, epsilon: 0.01));
      expect(selected(tester, 'wallpaper-default'), isTrue);
      expect(selected(tester, 'wallpaper-video'), isFalse);
      expect(selected(tester, 'wallpaper-json'), isFalse);
    });
  });

  group('the video', () {
    testWidgets('no file yet: it asks for one, then its rows open and the picture stays as it was', (tester) async {
      final picture = File('${folder.path}/p.png')
        ..writeAsBytesSync(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==',
          ),
        );
      live.video = const VideoWallpaper(path: '/tmp/w.mp4');
      await pump(tester, stored: CustomWallpaper(path: picture.path, width: 1, height: 1, edge: 0xff112233));
      await tester.tap(find.byKey(const ValueKey('wallpaper-video')));
      await settle(tester);

      expect(live.videos, 1);
      expect(selected(tester, 'wallpaper-video'), isTrue);
      expect(selected(tester, 'wallpaper-default'), isFalse);
      expect(find.text('显示方式'), findsOneWidget);
      expect(find.text('填满'), findsOneWidget);
      expect(find.text('居中'), findsOneWidget);
      expect(find.text('调整显示位置'), findsOneWidget);
      expect(find.text('更换视频'), findsOneWidget);
      // The picture's own rows are folded away, and it was not turned off by choosing a video.
      expect(find.text('模糊'), findsNothing);
      expect((await CustomWallpaper.load())!.on, isTrue);
      expect((await SharedPreferences.getInstance()).getString(WallpaperKindController.prefsKey), 'video');
    });

    testWidgets('a file already in use: the phone just selects it, 更换视频 picks again', (tester) async {
      final file = File('${folder.path}/w.mp4')
        ..writeAsBytesSync(<int>[0, 0, 0, 0x18, ...'ftypisom'.codeUnits]);
      final video = VideoWallpaper(path: file.path);
      final other = File('${folder.path}/other.mp4')
        ..writeAsBytesSync(<int>[0, 0, 0, 0x18, ...'ftypisom'.codeUnits]);
      live.video = VideoWallpaper(path: other.path);
      await pump(tester, video: video);

      await tester.tap(find.byKey(const ValueKey('wallpaper-video')));
      await settle(tester);
      expect(live.videos, 0);
      expect(selected(tester, 'wallpaper-video'), isTrue);

      await tester.tap(find.byKey(const ValueKey('wallpaper-video-replace')));
      await settle(tester);
      expect(live.videos, 1);
      expect((await VideoWallpaper.load())!.path, live.video!.path);
    });

    testWidgets('填满 / 居中 and where it sits are stored with the video', (tester) async {
      final file = File('${folder.path}/w.mp4')
        ..writeAsBytesSync(<int>[0, 0, 0, 0x18, ...'ftypisom'.codeUnits]);
      await pump(tester, video: VideoWallpaper(path: file.path), kind: WallpaperKind.video);

      await tester.tap(find.text('居中'));
      await settle(tester);
      expect((await VideoWallpaper.load())!.fit, VideoFit.center);
      expect(selected(tester, 'wallpaper-video'), isTrue);
    });
  });

  group('the .json', () {
    testWidgets('choosing it uses the bundled scene; 更换 .json 文件 reads the picked file', (tester) async {
      live.json = JsonWallpaper(
        (File('${folder.path}/night.json')..writeAsStringSync('{"schemaVersion": 1, "id": "night"}')).path,
      );
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('wallpaper-json')));
      await settle(tester);
      expect(live.scenes, 0);
      expect(selected(tester, 'wallpaper-json'), isTrue);
      expect(find.text('跟随系统时间'), findsOneWidget);
      expect(inTile('wallpaper-json-replace', '示例场景'), findsOneWidget);
      // 自定义's picture rows stay closed; the scene is the wallpaper on its own.
      expect(find.text('模糊'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('wallpaper-json-replace')));
      await settle(tester);
      expect(live.scenes, 1);
      expect(inTile('wallpaper-json-replace', 'night.json'), findsOneWidget);
      expect(inTile('wallpaper-json-replace', '示例场景'), findsNothing);
      expect((await JsonWallpaper.load())!.path, live.json!.path);
      expect((await SharedPreferences.getInstance()).getString(WallpaperKindController.prefsKey), 'json');
    });

    testWidgets('跟随系统时间 names the period the clock is in', (tester) async {
      await pump(tester, kind: WallpaperKind.json);
      final period = ScenePeriod.of(DateTime.now());
      final label = switch (period) {
        ScenePeriod.day => '白天',
        ScenePeriod.dusk => '黄昏',
        ScenePeriod.night => '晚上',
      };
      expect(find.text(label), findsOneWidget);
    });
  });

  group('the models', () {
    test('the video keeps its path, how it is scaled and where it sits', () {
      const video = VideoWallpaper(path: '/w/movie.mp4', fit: VideoFit.center, alignX: 0.4, alignY: -0.2);
      final back = VideoWallpaper.fromJson(jsonDecode(jsonEncode(video.toJson())) as Map<String, Object?>);
      expect(back, video);
      expect(VideoFit.parse('center'), VideoFit.center);
      expect(VideoFit.parse(null), VideoFit.fill);
    });

    test('a video whose file is gone reads as none, not as a broken wallpaper', () async {
      SharedPreferences.setMockInitialValues({
        VideoWallpaper.prefsKey: jsonEncode(const VideoWallpaper(path: '/no/such/movie.mp4').toJson()),
      });
      expect(await VideoWallpaper.load(), isNull);
    });

    test('no .json picked yet falls back to the bundled scene', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await JsonWallpaper.load(), isNull);
      expect(const JsonWallpaper(JsonWallpaper.bundled).isBundled, isTrue);
      expect(const JsonWallpaper('/w/night.json').isBundled, isFalse);
    });

    test('saving no video forgets the one before', () async {
      SharedPreferences.setMockInitialValues({
        VideoWallpaper.prefsKey: jsonEncode(const VideoWallpaper(path: '/w/movie.mp4').toJson()),
      });
      await VideoWallpaper.save(null);
      expect((await SharedPreferences.getInstance()).getString(VideoWallpaper.prefsKey), isNull);
    });
  });

  group('the .json package', () {
    const movie = <int>[0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D];

    List<int> zipOf(Map<String, List<int>> entries) {
      final archive = Archive();
      entries.forEach((name, bytes) => archive.addFile(ArchiveFile(name, bytes.length, bytes)));
      return ZipEncoder().encode(archive);
    }

    Future<File> scenePackage(
      String manifest, {
      Map<String, List<int>> assets = const {},
      String name = 'scene.jsonwall',
    }) async {
      final file = File('${folder.path}/$name');
      await file.writeAsBytes(zipOf({JsonWallpaper.manifestName: utf8.encode(manifest), ...assets}));
      return file;
    }

    LiveWallpaperImport importer() => LiveWallpaperImport(directory: () async => folder);

    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('a package with a video of its own is unpacked, checked and kept', () async {
      final source = await scenePackage(
        '{"schemaVersion": 1, "id": "pack", "videos": {"night": "assets/night.mp4"}, "layers": []}',
        assets: {'assets/night.mp4': movie},
      );

      final (wallpaper, problem, detail) = await importer().adopt(source);

      expect(problem, isNull);
      expect(detail, isNull);
      expect(wallpaper!.isPackage, isTrue);
      expect(File('${wallpaper.path}/assets/night.mp4').existsSync(), isTrue);
      expect((await JsonWallpaper.load())!.path, wallpaper.path);

      final document = SceneDocument.parse(File('${wallpaper.path}/manifest.json').readAsStringSync());
      expect(document.videoAt(ScenePeriod.night)!.src, 'assets/night.mp4');
    });

    test('a package that names a file it does not contain is refused, and nothing is left behind', () async {
      final source = await scenePackage(
        '{"schemaVersion": 1, "id": "hole", "videos": {"day": "assets/missing.mp4"}, "layers": []}',
      );

      final (wallpaper, problem, detail) = await importer().adopt(source);

      expect(wallpaper, isNull);
      expect(problem, LaunchImportProblem.unsupported);
      expect(detail, contains('assets/missing.mp4'));
      expect(folder.listSync().whereType<Directory>(), isEmpty);
      expect(await JsonWallpaper.load(), isNull);
    });

    test('a package whose entry climbs out is refused', () async {
      final source = await scenePackage(
        '{"schemaVersion": 1, "id": "slip", "layers": []}',
        assets: {'../evil.mp4': movie},
      );

      final (wallpaper, problem, detail) = await importer().adopt(source);

      expect(wallpaper, isNull);
      expect(problem, LaunchImportProblem.unsupported);
      expect(detail, contains('非法路径'));
    });

    test('a plain .json is still a file, not a package', () async {
      final source = File('${folder.path}/night.json')
        ..writeAsStringSync('{"schemaVersion": 1, "id": "night", "layers": []}');

      final (wallpaper, problem, detail) = await importer().adopt(source);

      expect(problem, isNull);
      expect(detail, isNull);
      expect(wallpaper!.isPackage, isFalse);
      expect(wallpaper.path, endsWith('.json'));
      expect((await JsonWallpaper.load())!.path, wallpaper.path);
    });

    // 选择器不过滤扩展名（Android 没有 jsonwall 的 MIME），所以能不能导入完全
    // 看文件头：同一个包叫 .jsonwall 还是 .zip 都得认。
    test('the same package imports under either name', () async {
      final zipped = await scenePackage(
        '{"schemaVersion": 1, "id": "named", "videos": {"day": "assets/day.mp4"}, "layers": []}',
        assets: {'assets/day.mp4': movie},
        name: 'scene.zip',
      );

      final (wallpaper, problem, detail) = await importer().adopt(zipped);

      expect(problem, isNull);
      expect(detail, isNull);
      expect(wallpaper!.isPackage, isTrue);
      expect(File('${wallpaper.path}/assets/day.mp4').existsSync(), isTrue);
    });

    test('a file that is neither a zip nor a .json says so', () async {
      final source = File('${folder.path}/notes.txt')..writeAsStringSync('{"schemaVersion": 1}');

      final (wallpaper, problem, detail) = await importer().adopt(source);

      expect(wallpaper, isNull);
      expect(problem, LaunchImportProblem.unsupported);
      expect(detail, contains('只支持 .json'));
      expect((await JsonWallpaper.load()), isNull);
    });
  });
}
