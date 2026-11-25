import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/wallpaper/live_wallpaper.dart';
import 'package:dsh_app/wallpaper/scene_document.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('the bundled sample', () {
    final source = File('assets/wallpapers/aurora.json').readAsStringSync();
    final document = SceneDocument.parse(source);

    test('parses with a base scene and the two other periods', () {
      expect(document.id, 'aurora');
      expect(document.scene.layers, isNotEmpty);
      expect(document.periods.keys, containsAll([ScenePeriod.dusk, ScenePeriod.night]));
      expect(document.sceneAt(ScenePeriod.day), same(document.scene));
      expect(document.sceneAt(ScenePeriod.night).layers, isNotEmpty);
      expect(document.fpsCap, 30);
    });
  });

  test('the period follows the system clock', () {
    expect(ScenePeriod.of(DateTime(2026, 11, 16, 4, 59)), ScenePeriod.night);
    expect(ScenePeriod.of(DateTime(2026, 11, 16, 5)), ScenePeriod.dusk, reason: '日出窗口算黄昏');
    expect(ScenePeriod.of(DateTime(2026, 11, 16, 6, 59)), ScenePeriod.dusk);
    expect(ScenePeriod.of(DateTime(2026, 11, 16, 7)), ScenePeriod.day);
    expect(ScenePeriod.of(DateTime(2026, 11, 16, 12)), ScenePeriod.day);
    expect(ScenePeriod.of(DateTime(2026, 11, 16, 15, 59)), ScenePeriod.day);
    expect(ScenePeriod.of(DateTime(2026, 11, 16, 16)), ScenePeriod.dusk);
    expect(ScenePeriod.of(DateTime(2026, 11, 16, 18, 59)), ScenePeriod.dusk);
    expect(ScenePeriod.of(DateTime(2026, 11, 16, 19)), ScenePeriod.night);
    expect(ScenePeriod.of(DateTime(2026, 11, 17, 0)), ScenePeriod.night);
  });

  test('a newer schema is refused instead of half-read', () {
    expect(
      () => SceneDocument.parse('{"schemaVersion": 2}'),
      throwsA(isA<SceneFormatException>().having((e) => e.message, 'message', contains('schemaVersion 2'))),
    );
  });

  test('a broken field names the field', () {
    expect(
      () => SceneDocument.parse('{"schemaVersion": 1, "layers": [{"kind": "image", "id": "sky"}]}'),
      throwsA(isA<SceneFormatException>().having((e) => e.message, 'message', contains('sky.src'))),
    );
    expect(
      () => SceneDocument.parse('{"schemaVersion": 1, "layers": [{"kind": "shader", "id": "x"}]}'),
      throwsA(isA<SceneFormatException>().having((e) => e.message, 'message', contains('shader'))),
    );
  });

  group('timeline', () {
    SceneTrack track(String mode) => SceneDocument.parse(
      '{"schemaVersion": 1, "timeline": [{"target": "x.opacity", "mode": "$mode", "keys": [[0, 0], [4, 1]]}]}',
    ).scene.timeline.single;

    test('loop restarts the span', () {
      final loop = track('loop');
      expect(loop.sample(2), closeTo(0.5, 1e-6));
      expect(loop.sample(6), closeTo(0.5, 1e-6));
    });

    test('clamp holds both ends', () {
      final clamp = track('clamp');
      expect(clamp.sample(-1), 0);
      expect(clamp.sample(9), 1);
    });

    test('pingpong mirrors back', () {
      final pingpong = track('pingpong');
      expect(pingpong.sample(2), closeTo(0.5, 1e-6));
      expect(pingpong.sample(6), closeTo(0.5, 1e-6));
    });
  });

  test('a period only replaces what it names', () {
    final document = SceneDocument.parse('''
      {"schemaVersion": 1,
       "background": "#000000",
       "layers": [{"kind": "glow", "id": "sun", "color": "#FFE7A3"}],
       "periods": {"night": {"background": {"colors": ["#000000", "#101010"]}}}}
    ''');
    expect(document.sceneAt(ScenePeriod.night).layers, same(document.scene.layers));
    expect(document.sceneAt(ScenePeriod.night).background.colors, isNot(document.scene.background.colors));
  });

  test('the video container comes from the file header', () {
    expect(videoExtensionOf(Uint8List.fromList([0, 0, 0, 0x18, ...'ftypisom'.codeUnits])), 'mp4');
    expect(videoExtensionOf(Uint8List.fromList([0x1A, 0x45, 0xDF, 0xA3, 1, 2, 3, 4])), 'webm');
    expect(videoExtensionOf(Uint8List.fromList('GIF89a......'.codeUnits)), isNull);
  });

  test('a video is named by the scene, or by the period, and keeps its fit', () {
    final document = SceneDocument.parse('''
      {"schemaVersion": 1,
       "video": "assets/day.mp4",
       "layers": [],
       "videos": {"dusk": {"src": "assets/dusk.mp4", "fit": "contain", "opacity": 0.5}}}
    ''');
    expect(document.videoAt(ScenePeriod.day)!.src, 'assets/day.mp4');
    expect(document.videoAt(ScenePeriod.day)!.fit, SceneFit.cover);
    expect(document.videoAt(ScenePeriod.dusk)!.fit, SceneFit.contain);
    expect(document.videoAt(ScenePeriod.dusk)!.opacity, 0.5);
    expect(document.videoAt(ScenePeriod.night)!.src, 'assets/day.mp4');
    // The document-level map is the per-period override; the scene video stays the fallback.
    expect(document.sceneAt(ScenePeriod.dusk).video!.src, 'assets/day.mp4');
    expect(document.sources, {'assets/day.mp4', 'assets/dusk.mp4'});
  });

  test('a video cannot be embedded, and no source climbs out of the package', () {
    expect(
      () => SceneDocument.parse('{"schemaVersion": 1, "video": "data:video/mp4;base64,AAAA", "layers": []}'),
      throwsA(isA<SceneFormatException>().having((error) => error.message, 'message', contains('不能内嵌视频'))),
    );
    expect(
      () => SceneDocument.parse('{"schemaVersion": 1, "layers": [{"kind": "image", "id": "sky", "src": "../sky.png"}]}'),
      throwsA(isA<SceneFormatException>().having((error) => error.message, 'message', contains('不能用 ..'))),
    );
    expect(
      () => SceneDocument.parse('{"schemaVersion": 1, "layers": [{"kind": "image", "id": "sky", "src": "/sky.png"}]}'),
      throwsA(isA<SceneFormatException>().having((error) => error.message, 'message', contains('不能是绝对路径'))),
    );
    expect(
      () => SceneDocument.parse('{"schemaVersion": 1, "layers": [{"kind": "image", "id": "sky", "src": "file:///sky.png"}]}'),
      throwsA(isA<SceneFormatException>().having((error) => error.message, 'message', contains('只支持 asset:'))),
    );
  });
}
