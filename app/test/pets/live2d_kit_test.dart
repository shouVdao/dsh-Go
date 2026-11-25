// Tests for the Dart port of `app/tool/live2d_pet_kit.py`.
//
// The fixture mirrors the Python tool's own test: a two-group model3.json with
// a trailing comma, one unregistered .motion3.json, one sound, one expression
// and a 1x1 texture — the shape a community rip actually has. No real model art
// is used, so the suite measures the rules and not one particular download.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_app/pets/live2d_kit.dart';
import 'package:dsh_app/pets/pet_pack_validator.dart' show pngSize;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('live2d-kit-');
  });
  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  // ── Report ──────────────────────────────────────────────────────────────

  group('report', () {
    test('trailing comma is reported and repaired', () async {
      final report = await inspectFixture(temp);
      expect(report.cubism2, isFalse);
      expect(report.fixedCommas, 1);
      expect(report.notes.any((note) => note.contains('逗号')), isTrue);

      // What the kit writes back is clean: re-reading it repairs nothing.
      final room = await Live2dKit.buildRoom(report);
      final descriptor = utf8.decode(entryBytes(room, 'character/cat.model3.json'));
      expect(RegExp(r',\s*[}\]]').hasMatch(descriptor), isFalse);
      expect(() => jsonDecode(descriptor), returnsNormally);

      final written = File('${temp.path}/room.zip')..writeAsBytesSync(room);
      final again = await Live2dKit.inspect(written.path);
      expect(again.fixedCommas, 0);
      expect(again.notes.any((note) => note.contains('逗号')), isFalse);
    });

    test('motions are named the way the stage plays them', () async {
      final report = await inspectFixture(temp);
      // One motion keeps its group name; several get _1/_2; a loose file its own name.
      expect(report.motions.map((motion) => motion.key).toList(), <String>['Idle', 'Wave_1', 'Wave_2', 'loose_extra']);
    });

    test('motion metadata is read', () async {
      final report = await inspectFixture(temp);
      final entries = <String, Live2dKitMotion>{for (final motion in report.motions) motion.key: motion};
      expect(entries['Idle']?.duration, 2.0);
      expect(entries['Idle']?.loop, isTrue);
      expect(entries['Wave_1']?.loop, isFalse);
      expect(entries['Idle']?.index, 0);
      expect(entries['Wave_2']?.index, 1);
      // ParamAngleX is not a physics-only parameter, so these read as gestures.
      expect(entries['Idle']?.gesture, isTrue);
      expect(entries['Wave_1']?.gesture, isTrue);
    });

    test('physics-only and too-short motions are not gestures', () async {
      final report = await inspectFixture(
        temp,
        extra: <String, List<int>>{
          'physics_only.motion3.json': utf8.encode(
            jsonEncode(motion(duration: 2.0, params: <String>['ParamHairFront'])),
          ),
          'twitch.motion3.json': utf8.encode(jsonEncode(motion(duration: 0.1))),
        },
      );
      final byKey = <String, Live2dKitMotion>{for (final motion in report.motions) motion.key: motion};
      expect(byKey['physics_only']?.gesture, isFalse);
      expect(byKey['twitch']?.gesture, isFalse);
      expect(byKey['Idle']?.gesture, isTrue);
    });

    test('textures and moc are references', () async {
      final report = await inspectFixture(temp);
      // The report exposes the descriptor itself rather than a `references()`
      // helper: these are the same fields the kit's checks read.
      final references = report.model.doc['FileReferences'];
      expect(references, isA<Map<String, dynamic>>());
      if (references is Map<String, dynamic>) {
        expect(references['Moc'], 'cat.moc3');
      }
      expect(report.textures.keys.toList(), <String>['textures/tex_00.png']);
      final size = report.textures['textures/tex_00.png'];
      expect(size?.width, 1);
      expect(size?.height, 1);
    });

    test('sound is carried and unknown files are dropped', () async {
      final plain = await inspectFixture(temp, name: 'plain.zip');
      expect(plain.model.files.containsKey('bgm.mp3'), isTrue);
      expect(plain.dropped, isEmpty);

      final withPsd = await inspectFixture(
        temp,
        name: 'with-psd.zip',
        extra: <String, List<int>>{
          'notes.psd': <int>[1, 2, 3],
        },
      );
      expect(withPsd.dropped, <String>['notes.psd']);
      expect(withPsd.model.files.containsKey('notes.psd'), isFalse);
      expect(withPsd.totalBytes, greaterThan(0));
    });

    test('a single top folder is stripped', () async {
      final report = await inspectFixture(temp, top: 'cat');
      expect(report.model.descriptor, 'cat.model3.json');
      expect(report.model.files.keys, contains('textures/tex_00.png'));
    });

    test('unregistered motion files are listed as extras', () async {
      final report = await inspectFixture(temp);
      final extras = report.motions.where((motion) => motion.group.isEmpty).toList();
      expect(extras.map((motion) => motion.key), <String>['loose_extra']);
      expect(extras.single.file, 'loose_extra.motion3.json');
      expect(report.notes.any((note) => note.contains('.motion3.json')), isTrue);
      expect(report.expressions.map((expression) => expression.name), <String>['Smile']);
    });

    test('at most 64 unregistered motion files are offered', () async {
      final extra = <String, List<int>>{
        for (var index = 0; index < 70; index++)
          'extra_${index.toString().padLeft(2, '0')}.motion3.json': utf8.encode(jsonEncode(motion(duration: 1))),
      };
      final report = await inspectFixture(temp, extra: extra);
      final loose = report.motions.where((motion) => motion.group.isEmpty).length;
      // 70 synthetic files plus loose_extra; the stage only names 64 of them.
      expect(loose, 64);
    });

    test('suggestions follow the name hints', () async {
      final report = await inspectFixture(temp);
      final suggestion = report.suggestion;
      expect(suggestion.keys.toSet(), <String>{...live2dPetStates, ...live2dPetReactions});
      expect(suggestion['idle'], 'Idle');
      // "Wave" reads as a greeting, which is the first Wave motion.
      expect(suggestion['attention'], 'Wave_1');
      expect(suggestion['sleeping'], isNull);
      expect(suggestion['drag'], isNull);
    });

    test('invalid descriptor json raises the json code', () async {
      final files = fixtureFiles()..['cat.model3.json'] = utf8.encode('{"Version": 3,');
      final zip = writeRawZip(temp, files);
      try {
        await Live2dKit.inspect(zip.path);
        fail('inspect should have thrown');
      } on Live2dKitException catch (error) {
        expect(error.code, 'json');
        expect(error.detail, 'cat.model3.json');
      }
    });

    test('a utf-8 bom is tolerated and never written back', () async {
      final files = fixtureFiles(trailingComma: false);
      final descriptor = files['cat.model3.json'];
      if (descriptor == null) {
        throw StateError('fixture lost its descriptor');
      }
      files['cat.model3.json'] = <int>[0xEF, 0xBB, 0xBF, ...descriptor];
      final report = await Live2dKit.inspect(writeRawZip(temp, files).path);
      expect(report.model.doc['Version'], 3);
      expect(report.fixedCommas, 0);

      final room = await Live2dKit.buildRoom(report);
      final written = entryBytes(room, 'character/cat.model3.json');
      final hasBom = written.length >= 3 && written[0] == 0xEF && written[1] == 0xBB && written[2] == 0xBF;
      expect(hasBom, isFalse);
    });

    test('unsafe entries are refused', () async {
      final files = fixtureFiles()..['../escape.txt'] = <int>[1];
      final zip = writeRawZip(temp, files);
      await expectLater(
        Live2dKit.inspect(zip.path),
        throwsA(isA<Live2dKitException>().having((error) => error.code, 'code', 'zip')),
      );
    });

    test('duplicate entries after normalisation are refused', () async {
      final files = fixtureFiles()..['CAT.model3.json'] = utf8.encode('{"Version": 3}');
      final zip = writeRawZip(temp, files);
      await expectLater(
        Live2dKit.inspect(zip.path),
        throwsA(isA<Live2dKitException>().having((error) => error.code, 'code', 'zip')),
      );
    });

    test('a zip past the read cap is refused by its size alone', () async {
      final file = File('${temp.path}/huge.zip');
      final raf = await file.open(mode: FileMode.write);
      await raf.truncate(64 * 1024);
      await raf.close();

      // The cap is the only thing that differs: read at all, these bytes are
      // not a zip — which is exactly what the phone would pay for first.
      await expectLater(
        Live2dKit.inspect(file.path, byteCap: 32 * 1024),
        throwsA(isA<Live2dKitException>().having((error) => error.code, 'code', 'too-large')),
      );
      await expectLater(
        Live2dKit.inspect(file.path),
        throwsA(isA<Live2dKitException>().having((error) => error.code, 'code', 'archive')),
      );
    });
  });

  // ── Mapping ─────────────────────────────────────────────────────────────

  group('mapping', () {
    test('skeleton lists every state and reaction', () async {
      final report = await inspectFixture(temp);
      final mapping = Live2dKit.skeleton(report);
      expect(mapping.keys.toSet(), <String>{...live2dPetStates, ...live2dPetReactions});
      expect(mapping.length, live2dPetStates.length + live2dPetReactions.length);
      expect(mapping.values.every((value) => value == null), isTrue);
    });

    test('unknown motion is refused', () async {
      final report = await inspectFixture(temp);
      final mapping = withMapped(Live2dKit.skeleton(report), <String, String?>{'idle': 'Idle', 'thinking': 'Nope'});
      final problems = Live2dKit.mappingProblems(report, mapping);
      expect(problems, hasLength(1));
      expect(problems.single, startsWith('motion-unknown:'));
      expect(problems.single, contains('Nope'));
    });

    test('missing state key is refused', () async {
      final report = await inspectFixture(temp);
      final mapping = Map<String, String?>.of(Live2dKit.skeleton(report))
        ..remove('thinking')
        ..['idle'] = 'Idle';
      final problems = Live2dKit.mappingProblems(report, mapping);
      expect(problems, hasLength(1));
      expect(problems.single, startsWith('states-missing:'));
      expect(problems.single, contains('thinking'));
    });

    test('missing reaction key is refused', () async {
      final report = await inspectFixture(temp);
      final mapping = Map<String, String?>.of(Live2dKit.skeleton(report))
        ..remove('tickle')
        ..['idle'] = 'Idle';
      final problems = Live2dKit.mappingProblems(report, mapping);
      expect(problems, hasLength(1));
      expect(problems.single, startsWith('reactions-missing:'));
      expect(problems.single, contains('tickle'));
    });

    test('leaving every motion out is refused', () async {
      final report = await inspectFixture(temp);
      final skeleton = Live2dKit.skeleton(report);
      final problems = Live2dKit.mappingProblems(report, skeleton);
      expect(problems.any((problem) => problem.startsWith('idle-missing:')), isTrue);
      expect(problems.any((problem) => problem.startsWith('motions-ignored:')), isTrue);
      expect(problems.any((problem) => problem.contains('${report.motions.length} 个动作')), isTrue);

      // The builder refuses it too: a pet that never moves is not a pet.
      await expectLater(
        Live2dKit.buildPet(report, skeleton),
        throwsA(isA<Live2dKitException>().having((error) => error.code, 'code', 'mapping')),
      );

      // One idle motion is enough to make the mapping usable.
      final partial = withMapped(skeleton, <String, String?>{'idle': 'Idle'});
      expect(Live2dKit.mappingProblems(report, partial), isEmpty);
    });

    test('unmade report names what is missing', () async {
      final report = await inspectFixture(temp);
      final mapping = withMapped(Live2dKit.skeleton(report), <String, String?>{'idle': 'Idle'});
      final lines = Live2dKit.unimplemented(report, mapping);
      expect(lines, hasLength(3));
      expect(lines[0], startsWith('没实现的状态：'));
      expect(lines[0], isNot(contains('idle')));
      expect(lines[0], contains('thinking'));
      expect(lines[1], contains('tapLeft'));
      expect(lines[2], '没用上的动作：Wave_1、Wave_2、loose_extra');
    });

    test('unknown mapping keys are refused', () async {
      final report = await inspectFixture(temp);
      final mapping = withMapped(Live2dKit.skeleton(report), <String, String?>{'idle': 'Idle', 'fallback': 'Idle'});
      final problems = Live2dKit.mappingProblems(report, mapping);
      expect(problems, hasLength(1));
      expect(problems.single, startsWith('key-unknown:'));
      expect(problems.single, contains('fallback'));
    });
  });

  // ── Build ───────────────────────────────────────────────────────────────

  group('build', () {
    test('pet pack passes the gates', () async {
      final report = await inspectFixture(temp);
      final mapping = petMapping(report);
      final pet = await Live2dKit.buildPet(report, mapping, name: 'Test Pet', id: 'test-pet');
      expect(await Live2dKit.checkPack(pet, pet: true), isEmpty);

      final files = unzip(pet);
      expect(files.keys, contains('pack.json'));
      expect(files.keys, contains('character/cat.model3.json'));
      expect(files.keys.any((name) => name.endsWith('.mp3')), isFalse);
      expect(files.keys, isNot(contains('poster.png')));

      final pack = objectOf(jsonEntry(pet, 'pack.json'));
      final live2d = objectOf(pack['live2d']);
      expect(live2d['states'], <String, String>{'idle': 'Idle', 'working': 'Wave_1'});
      expect(live2d['reactions'], <String, String>{'tapLeft': 'Wave_2'});
      expect(live2d['fallback'], 'Idle');
      expect(live2d['model'], 'cat.model3.json');
      expect(live2d['poster'], 'poster.png');
      expect(pack['schema'], 1);
      expect(pack['id'], 'test-pet');
      expect(pack['name'], 'Test Pet');
      expect(pack['type'], 'live2d');
      expect(pack['scale'], 1);
      expect(pack['pixelArt'], isFalse);
      expect(pack['canvas'], <String, Object?>{'w': 1024, 'h': 1024});
      expect(pack['contentBox'], <String, Object?>{'x': 0, 'y': 0, 'w': 1024, 'h': 1024});
      expect(pack['anchor'], <String, Object?>{'x': 512, 'baseline': 1024});

      // Every Sound reference is gone: the pack does not carry the files.
      final descriptor = objectOf(jsonEntry(pet, 'character/cat.model3.json'));
      final motions = objectOf(objectOf(descriptor['FileReferences'])['Motions']);
      for (final group in motions.values) {
        if (group is! List) {
          continue;
        }
        for (final entry in group) {
          if (entry is Map<String, dynamic>) {
            expect(entry.containsKey('Sound'), isFalse);
          }
        }
      }
      // Idle, Wave_1 and Wave_2 are used; the unregistered file is the one that is not.
      expect(Live2dKit.unimplemented(report, mapping).last, '没用上的动作：loose_extra');
    });

    test('poster must match the canvas', () async {
      final report = await inspectFixture(temp);
      final pet = await Live2dKit.buildPet(report, petMapping(report));

      final good = withEntry(pet, 'poster.png', png(1024, 1024));
      expect(await Live2dKit.checkPack(good, pet: true), isEmpty);

      final bad = withEntry(pet, 'poster.png', png(8, 8));
      final problems = await Live2dKit.checkPack(bad, pet: true);
      expect(problems, contains(contains('封面')));
      expect(problems.any((problem) => problem.contains('不一致')), isTrue);
    });

    test('content box outside the canvas is refused', () async {
      final report = await inspectFixture(temp);
      final pet = await Live2dKit.buildPet(report, petMapping(report));
      final pack = objectOf(jsonEntry(pet, 'pack.json'));
      objectOf(pack['contentBox'])['w'] = 2048;
      final broken = replaceEntry(pet, 'pack.json', utf8.encode(jsonEncode(pack)));
      final problems = await Live2dKit.checkPack(broken, pet: true);
      expect(problems.any((problem) => problem.contains('contentBox')), isTrue);
    });

    test('malformed pack json is refused', () async {
      final report = await inspectFixture(temp);
      final pet = await Live2dKit.buildPet(report, petMapping(report));
      // The kit's reader repairs a trailing comma, but checkPack has to judge
      // what the app's strict reader will see — so it must not repair it.
      final broken = replaceEntry(pet, 'pack.json', utf8.encode('{"schema": 1,}'));
      final problems = await Live2dKit.checkPack(broken, pet: true);
      expect(problems.any((problem) => problem.contains('pack.json 读不出来')), isTrue);
    });

    test('room pack puts the model under character/', () async {
      final report = await inspectFixture(temp);
      final room = await Live2dKit.buildRoom(report, name: 'Test Pet');
      expect(await Live2dKit.checkPack(room, pet: false), isEmpty);

      final files = unzip(room);
      expect(files.keys, contains('character/cat.model3.json'));
      expect(files.keys, contains('character/character.json'));
      expect(files.keys, contains('character/bgm.mp3'));
      expect(files.keys, contains('character/index.json'));
      expect(files.keys, isNot(contains('cat.model3.json')));
      expect(files.keys, isNot(contains('pack.json')));
      expect(files.length, 11);
      expect(objectOf(jsonEntry(room, 'character/character.json')), <String, Object?>{
        'schema': 1,
        'name': 'Test Pet',
        'model': 'cat.model3.json',
      });
      expect(jsonEntry(room, 'character/index.json'), isNotEmpty);
    });

    test('room pack carries emotions and actions', () async {
      final report = await inspectFixture(temp);
      final expression = report.expressions.first.name;
      final room = await Live2dKit.buildRoom(
        report,
        name: 'Room',
        emotions: <String, String?>{'happy': expression, 'sad': null},
        actions: const <String, String?>{'wave': 'Wave_1', 'nod': null},
      );
      expect(await Live2dKit.checkPack(room, pet: false), isEmpty);
      final character = objectOf(jsonEntry(room, 'character/character.json'));
      // An unmapped emotion or action is left out rather than written as null.
      expect(objectOf(character['emotions']), <String, Object?>{
        'happy': <String, Object?>{'expression': expression},
      });
      expect(objectOf(character['actions']), <String, Object?>{
        'wave': <String, Object?>{'motion': 'Wave_1'},
      });
    });

    test('room pack carries the framing the converter chose', () async {
      final report = await inspectFixture(temp);
      final framed = await Live2dKit.buildRoom(
        report,
        framing: const <String, double>{'zoom': 1.35, 'x': -0.2, 'y': 0.15},
      );
      expect(await Live2dKit.checkPack(framed, pet: false), isEmpty);
      final character = objectOf(jsonEntry(framed, 'character/character.json'));
      expect(objectOf(character['framing']), <String, Object?>{'zoom': 1.35, 'x': -0.2, 'y': 0.15});

      // A pack without framing leaves the room's own 1.2× camera alone.
      final plain = await Live2dKit.buildRoom(report);
      expect(objectOf(jsonEntry(plain, 'character/character.json')).containsKey('framing'), isFalse);
    });

    test('room pack carries a runtime folder, a pet pack may not', () async {
      final report = await inspectFixture(temp);
      final room = await Live2dKit.buildRoom(
        report,
        runtime: <String, Uint8List>{
          'live2dcubismcore.min.js': Uint8List.fromList(<int>[1, 2, 3]),
          'sub/x.js': Uint8List.fromList(<int>[4]),
        },
      );
      expect(await Live2dKit.checkPack(room, pet: false), isEmpty);
      final files = unzip(room);
      expect(files.keys, contains('runtime/live2dcubismcore.min.js'));
      expect(files.keys, contains('runtime/sub/x.js'));

      final pet = await Live2dKit.buildPet(report, petMapping(report));
      final withRuntime = withEntry(pet, 'runtime/x.js', <int>[1]);
      expect(await Live2dKit.checkPack(withRuntime, pet: true), isNotEmpty);
    });

    test('runtime folder is read with forward slashes', () async {
      final dir = Directory('${temp.path}/runtime')..createSync();
      File('${dir.path}/sub/a.js')
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[1]);
      final read = await Live2dKit.readRuntime(dir);
      expect(read?.keys.toList(), <String>['sub/a.js']);
      expect(await Live2dKit.readRuntime(Directory('${temp.path}/none')), isNull);
    });

    test('textures are downscaled to the cap', () async {
      final report = await inspectFixture(temp, extra: <String, List<int>>{'textures/tex_big.png': png(8, 8)});
      final pet = await Live2dKit.buildPet(report, petMapping(report), textureMax: 4);
      final big = pngSize(entryBytes(pet, 'character/textures/tex_big.png'));
      expect(big, isNotNull);
      if (big != null) {
        expect(big.$1, 4);
        expect(big.$2, 4);
      }
      // A texture already inside the cap is copied through untouched.
      final small = pngSize(entryBytes(pet, 'character/textures/tex_00.png'));
      expect(small?.$1, 1);
      expect(small?.$2, 1);
    });

    test('legacy model is detected and packed', () async {
      final report = await inspectFixture(temp, cubism: 2);
      expect(report.cubism2, isTrue);
      expect(report.model.cubism, 2);
      expect(report.motions.map((motion) => motion.key).toList(), <String>['Idle', 'Wave_1', 'Wave_2', 'Loose']);

      final room = await Live2dKit.buildRoom(report, name: 'Legacy');
      expect(await Live2dKit.checkPack(room, pet: false), isEmpty);
      final descriptor = objectOf(jsonEntry(room, 'character/model.json'));
      final idle = objectOf(descriptor['motions'])['Idle'];
      expect(idle, isA<List>());
      if (idle is List && idle.isNotEmpty) {
        expect(objectOf(idle.first)['sound'], 'bgm.mp3');
      }

      // A pet pack rewrites the same descriptor and drops the sound files.
      final mapping = withMapped(Live2dKit.skeleton(report), <String, String?>{'idle': 'Idle'});
      final pet = await Live2dKit.buildPet(report, mapping);
      expect(await Live2dKit.checkPack(pet, pet: true), isEmpty);
      final petDescriptor = objectOf(jsonEntry(pet, 'character/model.json'));
      final petIdle = objectOf(petDescriptor['motions'])['Idle'];
      if (petIdle is List && petIdle.isNotEmpty) {
        expect(objectOf(petIdle.first).containsKey('sound'), isFalse);
      }
    });
  });
}

// ── Fixtures ──────────────────────────────────────────────────────────────

/// A model folder, as the paths the zip would carry.
Map<String, List<int>> fixtureFiles({int cubism = 3, bool trailingComma = true}) {
  final files = <String, List<int>>{};
  files['textures/tex_00.png'] = png(1, 1);
  files['bgm.mp3'] = <int>[0x49, 0x44, 0x33, 0x03, 0, 0, 0, 0, 0, 0];
  files['idle.motion3.json'] = utf8.encode(jsonEncode(motion(duration: 2.0, loop: true)));
  files['wave_a.motion3.json'] = utf8.encode(jsonEncode(motion(duration: 0.8, loop: false)));
  files['wave_b.motion3.json'] = utf8.encode(jsonEncode(motion(duration: 1.1, loop: false)));
  files['loose_extra.motion3.json'] = utf8.encode(jsonEncode(motion(duration: 0.5, loop: false)));
  files['smile.exp3.json'] = utf8.encode(jsonEncode(<String, Object?>{'Version': 3, 'Parameters': <Object?>[]}));

  if (cubism == 2) {
    files['cat.moc'] = <int>[0x4D, 0x4F, 0x43, 0];
    final doc = <String, Object?>{
      'version': 'Sample 1.0',
      'model': 'cat.moc',
      'textures': <String>['textures/tex_00.png'],
      'motions': <String, Object?>{
        'Idle': <Object?>[
          <String, Object?>{'file': 'idle.motion3.json', 'sound': 'bgm.mp3'},
        ],
        'Wave': <Object?>[
          <String, Object?>{'file': 'wave_a.motion3.json'},
          <String, Object?>{'file': 'wave_b.motion3.json'},
        ],
        'Loose': <Object?>[
          <String, Object?>{'file': 'loose_extra.motion3.json'},
        ],
      },
    };
    files['model.json'] = utf8.encode(jsonEncode(doc));
    return files;
  }

  files['cat.moc3'] = <int>[0x4D, 0x4F, 0x43, 0x33, 0x03, 0, 0, 0];
  final doc = <String, Object?>{
    'Version': 3,
    'FileReferences': <String, Object?>{
      'Moc': 'cat.moc3',
      'Textures': <String>['textures/tex_00.png'],
      'Expressions': <Object?>[
        <String, Object?>{'Name': 'Smile', 'File': 'smile.exp3.json'},
      ],
      'Motions': <String, Object?>{
        'Idle': <Object?>[
          <String, Object?>{'File': 'idle.motion3.json', 'Sound': 'bgm.mp3', 'FadeInTime': 0.2},
        ],
        'Wave': <Object?>[
          <String, Object?>{'File': 'wave_a.motion3.json', 'FadeInTime': 0.1},
          <String, Object?>{'File': 'wave_b.motion3.json', 'FadeInTime': 0.1},
        ],
      },
    },
  };
  var text = const JsonEncoder.withIndent('  ').convert(doc);
  if (trailingComma) {
    // The comma a hand-edited descriptor usually has: after the last motion of
    // a group, which is the one thing json.dumps cannot have produced.
    final marker = text.indexOf('"FadeInTime": 0.2');
    final brace = text.indexOf('}', marker);
    if (marker < 0 || brace < 0) {
      throw StateError('fixture lost its FadeInTime marker');
    }
    text = text.replaceRange(brace + 1, brace + 1, ',');
  }
  files['cat.model3.json'] = utf8.encode(text);
  return files;
}

Map<String, Object?> motion({
  double duration = 1.5,
  bool loop = true,
  List<String> params = const <String>['ParamAngleX'],
}) {
  return <String, Object?>{
    'Version': 3,
    'Meta': <String, Object?>{'Duration': duration, 'Fps': 30, 'Loop': loop},
    'Curves': <Object?>[
      for (final param in params)
        <String, Object?>{
          'Target': 'Parameter',
          'Id': param,
          'Segments': <Object?>[0, 0, 1, duration, 10],
        },
    ],
  };
}

/// A [width]x[height] PNG of one colour, as bytes (the Python test's `png`).
Uint8List png(int width, int height, {List<int> rgba = const <int>[255, 0, 0, 255]}) {
  final raw = Uint8List((width * 4 + 1) * height);
  var offset = 0;
  for (var y = 0; y < height; y++) {
    raw[offset++] = 0;
    for (var x = 0; x < width; x++) {
      raw[offset++] = rgba[0];
      raw[offset++] = rgba[1];
      raw[offset++] = rgba[2];
      raw[offset++] = rgba[3];
    }
  }
  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8)
    ..setUint8(9, 6);
  final builder = BytesBuilder()
    ..add(const <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    ..add(_pngChunk('IHDR', header.buffer.asUint8List(0, 13)))
    ..add(_pngChunk('IDAT', ZLibEncoder().encode(raw, level: 9)))
    ..add(_pngChunk('IEND', const <int>[]));
  return builder.toBytes();
}

Uint8List _pngChunk(String kind, List<int> data) {
  final kindBytes = ascii.encode(kind);
  final builder = BytesBuilder()
    ..add(_uint32(data.length))
    ..add(kindBytes)
    ..add(data)
    ..add(_uint32(getCrc32(<int>[...kindBytes, ...data])));
  return builder.toBytes();
}

List<int> _uint32(int value) {
  final data = ByteData(4)..setUint32(0, value & 0xFFFFFFFF);
  return data.buffer.asUint8List(0, 4);
}

/// A model zip, optionally wrapped in one top folder.
File writeRawZip(Directory temp, Map<String, List<int>> files, {String? top, String name = 'model.zip'}) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.add(ArchiveFile.bytes(top == null ? entry.key : '$top/${entry.key}', entry.value));
  }
  return File('${temp.path}/$name')..writeAsBytesSync(ZipEncoder().encode(archive));
}

Future<Live2dKitReport> inspectFixture(
  Directory temp, {
  int cubism = 3,
  bool trailingComma = true,
  String? top,
  Map<String, List<int>> extra = const <String, List<int>>{},
  String name = 'model.zip',
}) async {
  final files = fixtureFiles(cubism: cubism, trailingComma: trailingComma);
  files.addAll(extra);
  final zip = writeRawZip(temp, files, top: top, name: name);
  return Live2dKit.inspect(zip.path);
}

Map<String, String?> petMapping(Live2dKitReport report) {
  return withMapped(Live2dKit.skeleton(report), <String, String?>{
    'idle': 'Idle',
    'working': 'Wave_1',
    'tapLeft': 'Wave_2',
  });
}

Map<String, String?> withMapped(Map<String, String?> mapping, Map<String, String?> values) {
  return Map<String, String?>.of(mapping)..addAll(values);
}

// ── Zip helpers ───────────────────────────────────────────────────────────

Map<String, Uint8List> unzip(Uint8List zip) {
  final archive = ZipDecoder().decodeBytes(zip, verify: true);
  final files = <String, Uint8List>{};
  for (final file in archive.files) {
    if (!file.isFile) {
      continue;
    }
    files[file.name] = file.readBytes() ?? Uint8List(0);
  }
  return files;
}

Uint8List entryBytes(Uint8List zip, String name) {
  final bytes = unzip(zip)[name];
  if (bytes == null) {
    throw StateError('zip has no $name');
  }
  return bytes;
}

Object? jsonEntry(Uint8List zip, String name) => jsonDecode(utf8.decode(entryBytes(zip, name)));

Map<String, dynamic> objectOf(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  throw StateError('not a JSON object: $value');
}

/// Adds [name] to the zip, replacing it when it is already there.
Uint8List withEntry(Uint8List zip, String name, List<int> bytes) => _rebuildZip(zip, name, bytes, replace: false);

Uint8List replaceEntry(Uint8List zip, String name, List<int> bytes) => _rebuildZip(zip, name, bytes, replace: true);

Uint8List _rebuildZip(Uint8List zip, String name, List<int> bytes, {required bool replace}) {
  final archive = ZipDecoder().decodeBytes(zip, verify: true);
  final out = Archive();
  var written = false;
  for (final file in archive.files) {
    if (!file.isFile) {
      continue;
    }
    if (file.name == name) {
      if (replace) {
        out.add(ArchiveFile.bytes(name, bytes));
        written = true;
      }
      continue;
    }
    out.add(ArchiveFile.bytes(file.name, file.readBytes() ?? Uint8List(0)));
  }
  if (!written) {
    out.add(ArchiveFile.bytes(name, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(out));
}
