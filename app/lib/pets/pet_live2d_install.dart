part of 'pet_library.dart';

// A Live2D pet pack (docs/pets/README.md §3.5): the zip carries a Cubism model
// folder (`character/`) and a still `poster.png` instead of sprite sheets. The
// model is kept as it is — the chat draws it in the companion's web stage —
// and the poster becomes the one-frame sprite pack the floating window and
// every sprite-only surface read.
//
// The pack.json the creator ships says `"type": "live2d"` and where the model
// and poster are; what is installed says the same thing plus a `poster`
// animation and all eleven states pointing at it, so anything that does not
// know about Live2D still sees an ordinary one-frame pet.

/// One file of a Cubism model can be a texture or a sound; the room's own
/// pack limits are reused (docs/live2d/README.md §2.1).
const _live2dFileCap = 32 * 1024 * 1024;
const _live2dTotalCap = 200 * 1024 * 1024;
const _live2dFileCountCap = 1000;

/// What a `character/` folder may hold (the room's allow-list, minus the
/// pack-only pieces: a pet has no runtime of its own).
const _live2dExtensions = {
  '.json',
  '.moc3',
  '.moc',
  '.mtn',
  '.png',
  '.jpg',
  '.jpeg',
  '.webp',
  '.wav',
  '.mp3',
  '.txt',
  '.md',
};

/// Read and checked from a zip: the model files, and the pack.json to install.
@immutable
class _Live2dPetFiles {
  const _Live2dPetFiles(this.json, this.files, this.pack, {this.posterPending = false});

  final Map<String, Object?> json;
  final Map<String, Uint8List> files;
  final PetPack pack;

  /// The zip carried no poster: [Poster] is a blank of the canvas's size, and
  /// the chat's stage draws the real one (see [posterPendingName]).
  final bool posterPending;
}

bool _isSafeLive2dPath(String path) =>
    path.isNotEmpty &&
    !path.startsWith('/') &&
    !path.contains('\\') &&
    path.split('/').every((part) => part.isNotEmpty && part != '.' && part != '..');

/// A Cubism 2 descriptor is `model.json` or `*.model.json` (the room's rule).
bool _legacyDescriptor(String path) {
  final name = path.split('/').last.toLowerCase();
  return name == 'model.json' || name.endsWith('.model.json');
}

_Live2dPetFiles _readLive2dPet(PetArchive archive, Map<String, Object?> source, String folder) {
  final spec = source['live2d'];
  if (spec is! Map) throw const PetImportException(PetImportProblem.badPack, 'live2d');
  final model = spec['model'];
  if (model is! String || !_isSafeLive2dPath(model)) {
    throw const PetImportException(PetImportProblem.badPack, 'live2d.model');
  }
  final poster = spec['poster'] is String ? spec['poster'] as String : 'poster.png';
  if (!_isSafeLive2dPath(poster)) throw const PetImportException(PetImportProblem.badPack, 'live2d.poster');

  final canvas = source['canvas'];
  final w = canvas is Map ? canvas['w'] : null;
  final h = canvas is Map ? canvas['h'] : null;
  if (w is! num || h is! num || w <= 0 || h <= 0) {
    throw const PetImportException(PetImportProblem.badPack, 'live2d.canvas');
  }

  final posterPath = '$folder$poster';
  final files = <String, Uint8List>{};
  final posterPending = !archive.fileNames.contains(posterPath);
  if (posterPending) {
    // A creator may ship the model alone: the chat's stage draws it, and the
    // first frame it draws becomes the poster (`PetLive2dView`). Until then
    // every sprite-only surface (the floating window, the grids) gets a blank
    // of the canvas's own size, so nothing has to special-case a pet without
    // a sheet.
    if (w.round() > petSheetSideCap ||
        h.round() > petSheetSideCap ||
        w.round() * h.round() * 4 > petSheetDecodedCap) {
      throw const PetImportException(PetImportProblem.live2dPoster, 'poster-missing');
    }
    files['poster.png'] = _blankPng(w.round(), h.round());
  } else {
    final posterBytes = archive.readFile(posterPath, maxBytes: petSheetByteCap);
    final size = pngSize(posterBytes);
    if (size == null || !pngIntact(posterBytes)) {
      throw const PetImportException(PetImportProblem.live2dPoster, 'poster-png');
    }
    if (size.$1 != w.round() || size.$2 != h.round()) {
      throw const PetImportException(PetImportProblem.live2dPoster, 'poster-size');
    }
    files['poster.png'] = posterBytes;
  }

  final prefix = '${folder}character/';
  var total = files['poster.png']!.length;
  for (final name in archive.fileNames) {
    if (!name.startsWith(prefix)) continue;
    final relative = name.substring(folder.length);
    if (!_isSafeLive2dPath(relative)) throw const PetImportException(PetImportProblem.badPack, 'live2d.path');
    final dot = relative.lastIndexOf('.');
    final extension = dot < 0 ? '' : relative.substring(dot).toLowerCase();
    if (!_live2dExtensions.contains(extension)) {
      throw const PetImportException(PetImportProblem.badPack, 'live2d-file');
    }
    if (files.length > _live2dFileCountCap) throw const PetImportException(PetImportProblem.tooLarge, 'live2d-count');
    if (total > _live2dTotalCap) throw const PetImportException(PetImportProblem.tooLarge, 'live2d-total');
    final bytes = archive.readFile(name, maxBytes: _live2dFileCap);
    total += bytes.length;
    files[relative] = bytes;
  }
  final modelPath = 'character/$model';
  if (!files.containsKey(modelPath)) {
    throw const PetImportException(PetImportProblem.live2dModel, 'model-missing');
  }

  // The descriptor itself is checked far enough that the stage gets a model
  // it can load: a moc and at least one texture all present.
  final descriptor = jsonDecode(utf8.decode(files[modelPath]!));
  if (descriptor is! Map) throw const PetImportException(PetImportProblem.live2dModel, 'model-json');
  final home = modelPath.substring(0, modelPath.length - model.split('/').last.length);
  final legacy = _legacyDescriptor(modelPath);
  if (legacy) {
    final moc = descriptor['model'];
    if (moc is! String || !files.containsKey('$home$moc')) {
      throw const PetImportException(PetImportProblem.live2dModel, 'moc');
    }
    _checkTextures(descriptor['textures'], home, files, legacy: true);
  } else {
    final refs = descriptor['FileReferences'];
    if (refs is! Map) throw const PetImportException(PetImportProblem.live2dModel, 'model-json');
    final moc = refs['Moc'];
    if (moc is! String || !files.containsKey('$home$moc')) {
      throw const PetImportException(PetImportProblem.live2dModel, 'moc');
    }
    _checkTextures(refs['Textures'], home, files, legacy: false);
  }

  final states = <String, String>{};
  final statesRaw = spec['states'];
  if (statesRaw is Map) {
    final known = {for (final state in PetStateName.values) state.name};
    for (final MapEntry(:key, :value) in statesRaw.entries) {
      if (!known.contains('$key') || value is! String || value.isEmpty) {
        throw PetImportException(PetImportProblem.badPack, 'live2d.states.$key');
      }
      states['$key'] = value;
    }
  }
  final reactions = <String, String>{};
  final reactionsRaw = spec['reactions'];
  if (reactionsRaw is Map) {
    for (final MapEntry(:key, :value) in reactionsRaw.entries) {
      if (value is! String || value.isEmpty) {
        throw PetImportException(PetImportProblem.badPack, 'live2d.reactions.$key');
      }
      reactions['$key'] = value;
    }
  }
  if (!states.containsKey(PetStateName.idle.name)) {
    throw const PetImportException(PetImportProblem.badPack, 'live2d.states.idle');
  }

  final id = source['id'];
  if (id is! String || id.isEmpty) throw const PetImportException(PetImportProblem.badPack, 'id');
  final contentBox = source['contentBox'];
  if (contentBox is! Map) throw const PetImportException(PetImportProblem.badPack, 'live2d.contentBox');

  final derived = <String, Object?>{
    if (source['name'] is String) 'name': source['name'],
    if (source['author'] is String) 'author': source['author'],
    if (source['license'] is String) 'license': source['license'],
    if (source['source'] is String) 'source': source['source'],
    'schema': PetPack.schema,
    'id': id,
    'type': 'live2d',
    'canvas': {'w': w, 'h': h},
    if (source['anchor'] is Map) 'anchor': source['anchor'],
    'contentBox': contentBox,
    'scale': 1,
    'pixelArt': false,
    // The one frame the floating window (and any sprite-only surface) shows.
    'animations': {
      'poster': {
        'sheet': 'poster.png',
        'frameW': w.round(),
        'frameH': h.round(),
        'cols': 1,
        'box': {'x': 0, 'y': 0, 'w': w, 'h': h},
        'frames': [
          {'i': 0, 'ms': 1000},
        ],
        'loop': true,
      },
    },
    'states': {
      for (final state in PetStateName.values) state.name: ['poster'],
    },
    'live2d': {
      'model': model,
      'states': states,
      'reactions': reactions,
      if (spec['fallback'] is String) 'fallback': spec['fallback'],
    },
  };
  final pack = PetPack.parse(derived);
  return _Live2dPetFiles(derived, files, pack, posterPending: posterPending);
}

void _checkTextures(Object? raw, String home, Map<String, Uint8List> files, {required bool legacy}) {
  final list = raw is List ? raw : const [];
  if (list.isEmpty || list.length > 64) throw const PetImportException(PetImportProblem.live2dModel, 'textures');
  for (final texture in list) {
    if (texture is! String || !files.containsKey('$home$texture')) {
      throw const PetImportException(PetImportProblem.live2dModel, 'texture');
    }
  }
}

/// Installs a Live2D pack already read from its zip.
Future<({String id, String? backup})> _installLive2d(
  Map<String, Object?> source,
  PetArchive archive,
  String folder, {
  required Directory staging,
  required String rootPath,
  required int stamp,
  String? receiptJson,
  required bool replaceExisting,
}) async {
  final live2d = _readLive2dPet(archive, source, folder);
  if (receiptJson != null) {
    final receipt = WorkshopReceipt.fromJson(jsonDecode(receiptJson));
    if (receipt.kind != 'pet' || receipt.id != live2d.pack.id) {
      throw const PetImportException(PetImportProblem.badPack, 'workshop_identity');
    }
  }
  final id = userPetIdFor(live2d.pack.id);
  await staging.create(recursive: true);
  for (final MapEntry(key: path, value: data) in live2d.files.entries) {
    final file = File('${staging.path}/$path');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data, flush: true);
  }
  final kept = {...live2d.json, 'id': id};
  await File('${staging.path}/pack.json').writeAsString(jsonEncode(kept), flush: true);
  if (live2d.posterPending) {
    await File('${staging.path}/$posterPendingName').writeAsString('1', flush: true);
  }
  if (receiptJson != null) await File('${staging.path}/$workshopReceiptName').writeAsString(receiptJson, flush: true);
  final live = Directory('$rootPath/$id');
  if (receiptJson != null) {
    await workshopCheckReplacement(
      live,
      WorkshopReceipt.fromJson(jsonDecode(receiptJson)),
      replaceExisting: replaceExisting,
    );
  }
  final old = Directory('$rootPath/.old-$stamp-$id');
  final replaced = await live.exists();
  if (replaced) await live.rename(old.path);
  try {
    await staging.rename(live.path);
  } on FileSystemException {
    if (replaced) await old.rename(live.path);
    rethrow;
  }
  return (id: id, backup: replaced ? old.path : null);
}

/// A transparent RGBA PNG of [w]×[h]: the poster a model-only pack gets until
/// the chat's stage draws one. Every scanline is filter 0 + zeroed pixels, so
/// zlib turns the whole canvas into a few kilobytes.
Uint8List _blankPng(int w, int h) {
  final raw = Uint8List((1 + w * 4) * h);
  final compressed = ZLibEncoder().encode(raw, level: 6);
  final header = ByteData(13)
    ..setUint32(0, w)
    ..setUint32(4, h)
    ..setUint8(8, 8) // bits per channel
    ..setUint8(9, 6) // RGBA
    ..setUint8(10, 0)
    ..setUint8(11, 0)
    ..setUint8(12, 0);
  final out = BytesBuilder(copy: false)..add(const [137, 80, 78, 71, 13, 10, 26, 10]);
  _pngChunk(out, 'IHDR', header.buffer.asUint8List());
  _pngChunk(out, 'IDAT', compressed);
  _pngChunk(out, 'IEND', const []);
  return out.takeBytes();
}

void _pngChunk(BytesBuilder out, String kind, List<int> data) {
  final body = Uint8List(4 + data.length)
    ..setRange(0, 4, kind.codeUnits)
    ..setRange(4, 4 + data.length, data);
  final length = ByteData(4)..setUint32(0, data.length);
  final crc = ByteData(4)..setUint32(0, getCrc32(body));
  out
    ..add(length.buffer.asUint8List())
    ..add(body)
    ..add(crc.buffer.asUint8List());
}
