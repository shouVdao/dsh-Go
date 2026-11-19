import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dsh_app/pets/pet_library.dart';
import 'package:dsh_app/pets/pet_pack.dart';
import 'package:dsh_app/pets/pet_state.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pet_library_test.dart' show png;

/// A Live2D pet as a creator ships it: no sprite sheets, the poster still is
/// what the floating window draws (`docs/pets/README.md` §3.5).
Map<String, Object?> live2dJson({
  String id = 'miku',
  String model = 'miku.model3.json',
  String poster = 'poster.png',
  Map<String, Object?> states = const {'idle': 'Idle'},
  Map<String, Object?> reactions = const {'tickle': 'Tap'},
  String? fallback,
}) => {
  'schema': 1,
  'id': id,
  'name': 'Miku',
  'author': 'someone',
  'license': 'CC0',
  'type': 'live2d',
  'canvas': {'w': 32, 'h': 16},
  'contentBox': {'x': 0, 'y': 0, 'w': 32, 'h': 16},
  'live2d': {
    'model': model,
    'poster': poster,
    'states': states,
    'reactions': reactions,
    'fallback': ?fallback,
  },
};

void main() {
  late Directory temp;
  late PetLibrary library;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('pet-live2d');
    library = PetLibrary(() async => Directory('${temp.path}/pets'));
  });
  tearDown(() => temp.deleteSync(recursive: true));

  File zip(Map<String, List<int>> files) {
    final archive = Archive();
    files.forEach((name, data) => archive.add(ArchiveFile.bytes(name, data)));
    final file = File('${temp.path}/in-${DateTime.now().microsecondsSinceEpoch}.zip');
    file.writeAsBytesSync(ZipEncoder().encode(archive));
    return file;
  }

  Matcher problem(PetImportProblem expected) =>
      throwsA(isA<PetImportException>().having((e) => e.problem, 'problem', expected));

  Map<String, List<int>> modern() => {
    'pack.json': utf8.encode(jsonEncode(live2dJson())),
    'poster.png': png(32, 16),
    'character/miku.model3.json': utf8.encode(
      jsonEncode({
        'Version': 3,
        'FileReferences': {
          'Moc': 'miku.moc3',
          'Textures': ['textures/t.png'],
        },
      }),
    ),
    'character/miku.moc3': utf8.encode('MOC3'),
    'character/textures/t.png': png(8, 8),
  };

  test('a live2d object is read, and only valid state and safe model names pass', () {
    final base = {
      'schema': 1,
      'id': 'miku',
      'canvas': {'w': 32, 'h': 16},
      'contentBox': {'x': 0, 'y': 0, 'w': 32, 'h': 16},
      'animations': {
        'poster': {
          'sheet': 'poster.png',
          'frameW': 32,
          'frameH': 16,
          'cols': 1,
          'box': {'x': 0, 'y': 0, 'w': 32, 'h': 16},
          'frames': [
            {'i': 0, 'ms': 1000},
          ],
        },
      },
      'states': {
        'idle': ['poster'],
      },
      'live2d': {
        'model': 'miku.model3.json',
        'states': {'idle': 'Idle', 'working': 'Work'},
        'reactions': {'tickle': 'Tap'},
        'fallback': 'Idle',
      },
    };
    final pack = PetPack.parse(base);
    expect(pack.live2d, isNotNull);
    expect(pack.live2d!.model, 'miku.model3.json');
    expect(pack.live2d!.states, {'idle': 'Idle', 'working': 'Work'});
    expect(pack.live2d!.reactions, {'tickle': 'Tap'});
    expect(pack.live2d!.fallback, 'Idle');

    expect(
      () => PetPack.parse({
        ...base,
        'live2d': {'model': '../outside.model3.json'},
      }),
      throwsFormatException,
      reason: 'a model path cannot leave character/',
    );
    expect(
      () => PetPack.parse({
        ...base,
        'live2d': {'model': 'miku.model3.json', 'states': {'dancing': 'Dance'}},
      }),
      throwsFormatException,
      reason: 'states are the eleven pet states',
    );
    expect(
      PetPack.parse({...base, 'live2d': null}).live2d,
      isNull,
      reason: 'sprite packs keep working',
    );
  });

  test('installing a live2d pet keeps the model and writes a poster pack', () async {
    final installed = await library.install(zip(modern()));
    final pack = await library.load(installed.id);

    expect(pack.live2d, isNotNull);
    expect(pack.live2d!.model, 'miku.model3.json');
    expect(pack.live2d!.states, {'idle': 'Idle'});
    expect(pack.live2d!.reactions, {'tickle': 'Tap'});
    expect(pack.animations.keys.toList(), ['poster'], reason: 'the only sprite is the poster');
    expect(pack.animFor(PetStateName.working).name, 'poster');
    expect(pack.animFor(PetStateName.sleeping).name, 'poster');

    final root = Directory('${temp.path}/pets/${installed.id}');
    expect(File('${root.path}/poster.png').existsSync(), isTrue);
    expect(File('${root.path}/character/miku.model3.json').existsSync(), isTrue);
    expect(File('${root.path}/character/miku.moc3').existsSync(), isTrue);
    expect(File('${root.path}/character/textures/t.png').existsSync(), isTrue);
  });

  test('a Cubism 2 model (model.json + .moc) installs the same way', () async {
    final files = modern();
    files.remove('character/miku.model3.json');
    files.remove('character/miku.moc3');
    files['pack.json'] = utf8.encode(
      jsonEncode(live2dJson(model: 'model.json')),
    );
    files['character/model.json'] = utf8.encode(
      jsonEncode({
        'model': 'miku.moc',
        'textures': ['textures/t.png'],
      }),
    );
    files['character/miku.moc'] = utf8.encode('moc2');

    final installed = await library.install(zip(files));
    final pack = await library.load(installed.id);
    expect(pack.live2d!.model, 'model.json');
    expect(File('${temp.path}/pets/${installed.id}/character/miku.moc').existsSync(), isTrue);
  });

  test('a pack without a poster installs with a blank one, marked pending', () async {
    final installed = await library.install(zip(modern()..remove('poster.png')));
    final root = Directory('${temp.path}/pets/${installed.id}');
    final poster = File('${root.path}/poster.png');
    expect(poster.existsSync(), isTrue, reason: 'every sprite surface still needs a sheet');
    final bytes = poster.readAsBytesSync();
    expect(pngSize(bytes), (32, 16));
    expect(pngIntact(bytes), isTrue);
    expect(
      File('${root.path}/.poster-pending').existsSync(),
      isTrue,
      reason: 'the chat stage draws the real one',
    );
    final pack = await library.load(installed.id);
    expect(pack.live2d, isNotNull);
    expect(pack.animations.keys.toList(), ['poster']);
  });

  test('a poster that is not a PNG exactly the canvas size still fails', () async {
    final wrongSize = modern()..['poster.png'] = png(16, 16);
    await expectLater(library.install(zip(wrongSize)), problem(PetImportProblem.live2dPoster));

    final wrongFormat = modern()..['poster.png'] = utf8.encode('not a png');
    await expectLater(library.install(zip(wrongFormat)), problem(PetImportProblem.live2dPoster));
  });

  test('a pack without its model descriptor says so', () async {
    final files = modern()..remove('character/miku.model3.json');
    await expectLater(library.install(zip(files)), problem(PetImportProblem.live2dModel));

    final bad = modern();
    bad['character/miku.model3.json'] = utf8.encode('{"FileReferences":{}}');
    await expectLater(library.install(zip(bad)), problem(PetImportProblem.live2dModel));
  });
}
