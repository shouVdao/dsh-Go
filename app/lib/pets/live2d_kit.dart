/// Turns a third-party Live2D model zip into a DSH-Go pet pack or a
/// companion-room pack, in the app and without Python.
///
/// This is the Dart port of `app/tool/live2d_pet_kit.py`. The rules are copied
/// here rather than imported from the CLI because the converter page has to
/// agree with the installers exactly: a motion key that differs by one
/// underscore plays nothing on the web stage, and a pack this kit calls usable
/// but the import gate refuses has already cost the user a download.
///
/// Nothing here renders the model. Textures are measured, and downscaled only
/// when the caller asks; the poster a pet pack would carry is deliberately not
/// written, because the app captures the first frame the stage draws.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';

import '../companion/companion_adapt_contract.dart';
import 'pet_name_alias.dart';
import 'pet_pack_validator.dart'
    show
        petArchiveByteCap,
        petArchiveEntryCap,
        petArchiveExpandedCap,
        petJsonCap,
        petSheetByteCap,
        petSheetDecodedCap,
        petSheetSideCap,
        pngIntact,
        pngSize;

/// The states every pet has, in the order `pack.json` lists them.
///
/// The mapping gives each one a motion the model already carries, or `null`.
/// `null` is not a failure: it becomes the 「没实现」 list the user is told
/// about, because a pet that stands still for "thinking" looks broken.
const List<String> live2dPetStates = <String>[
  'idle',
  'thinking',
  'working',
  'juggling',
  'sweeping',
  'notification',
  'attention',
  'error',
  'carrying',
  'sleeping',
  'waking',
];

/// The reactions a pet can play on a touch, in the order `pack.json` lists them.
const List<String> live2dPetReactions = <String>['tapLeft', 'tapRight', 'tickle', 'annoyed', 'drag'];

/// What a pack may carry inside its model folder (the room's allow-list).
const Set<String> _dataExtensions = <String>{
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

const Set<String> _soundExtensions = <String>{'.mp3', '.wav'};

/// Limits the companion-room installer applies to a model folder.
const int _live2dFilesCap = 1000;
const int _live2dFileCap = 32 * 1024 * 1024;
const int _live2dTotalCap = 200 * 1024 * 1024;
const int _roomTotalCap = 400 * 1024 * 1024;
const int _roomFilesCap = 4000;

/// Longest side a texture keeps before the builder downscales it.
const int _textureDefaultMax = 2048;

/// How many unregistered `.motion3.json` files the stage offers by file name
/// (`EXTRA_FILES_MAX` in `stage.js`); beyond that the key the pack writes would
/// not exist on the stage.
const int _extraFilesMax = 64;

/// Motions shorter than this read as a twitch, not a gesture.
const double _gestureMinDuration = 0.25;

final RegExp _textureNamePattern = RegExp(r'(texture|tex)', caseSensitive: false);

/// Physics-only curves: a motion that moves nothing else is a prop swaying,
/// not a gesture the person would recognise.
final RegExp _propParams = RegExp(r'^(Param)?(Hair|Tail|Skirt|Ribbon|Breath|Cheek|Physics|4\d+)', caseSensitive: false);

/// A failure the converter page has to show or fix.
///
/// [code] is stable and machine-readable so the page can pick a localized
/// sentence: `json` (a descriptor or motion is not JSON), `zip` (the download
/// is not a safe zip), `model` (no Live2D model inside), `mapping` (the state
/// mapping cannot produce a pack the app accepts), `too-large` (past an
/// installer limit), `archive` (an entry cannot be read), `io` (the path).
///
/// [detail] is the human sentence, usually naming the file to fix.
class Live2dKitException implements Exception {
  const Live2dKitException(this.code, [this.detail]);

  final String code;
  final String? detail;

  @override
  String toString() => detail == null ? 'Live2dKitException($code)' : 'Live2dKitException($code): $detail';
}

/// One motion as the web stage names it, with what the report shows about it.
class Live2dKitMotion {
  const Live2dKitMotion({
    required this.key,
    required this.group,
    required this.index,
    required this.file,
    required this.duration,
    required this.loop,
    required this.gesture,
  });

  /// The value that goes into `pack.json`'s `live2d.states` / `live2d.reactions`.
  ///
  /// A group with one motion keeps the group name, a group with several gets
  /// `<group>_<n>` (1-based), and an unregistered `.motion3.json` is its file
  /// name without the suffix. The stage builds the same strings from the same
  /// descriptor; anything else silently plays nothing.
  final String key;

  /// Motion group name from the descriptor; empty for an unregistered file.
  final String group;

  /// 0-based index inside [group].
  final int index;

  /// `motion3` file path relative to the model root.
  final String file;

  /// Length in seconds from `Meta.Duration`; 0 when the file could not be read.
  final double duration;

  /// `Meta.Loop`: whether the stage keeps the motion running.
  final bool loop;

  /// Whether the motion moves something a person can see.
  ///
  /// A file that only sways hair, a skirt or the breath curve reads as the
  /// model being alive, not as a reaction, so the mapping suggestions prefer
  /// motions that pass this.
  final bool gesture;

  @override
  String toString() => 'Live2dKitMotion($key, ${duration}s${loop ? ', loop' : ''})';
}

/// One expression file the model carries.
class Live2dKitExpression {
  const Live2dKitExpression({required this.name, required this.file});

  /// Display name: `Name` from the descriptor, else the file name.
  final String name;

  /// `.exp3.json` path relative to the model root.
  final String file;

  @override
  String toString() => 'Live2dKitExpression($name)';
}

/// A model as it sits inside the downloaded zip.
///
/// [files] keeps the carried bytes in memory instead of a folder on disk: the
/// kit has no dispose step in its API, so extracting to a temp directory would
/// leak one per inspect, and both builders produce their zip in memory anyway.
class Live2dKitModel {
  Live2dKitModel._({
    required this.descriptor,
    required this.cubism,
    required this.doc,
    required Map<String, Uint8List> files,
  }) : files = Map<String, Uint8List>.unmodifiable(files);

  /// Path of the descriptor (`*.model3.json`, or `model.json` for Cubism 2)
  /// relative to the model root.
  final String descriptor;

  /// 3 for Cubism 3+, 2 for the legacy `model.json` + `.moc` format.
  final int cubism;

  /// The parsed descriptor, with trailing commas already repaired.
  final Map<String, dynamic> doc;

  /// Every carried file, relative to the model root, in zip order.
  final Map<String, Uint8List> files;

  /// The model folder's name: `cat` for `cat.model3.json`.
  String get name => _basename(descriptor).replaceAll('.model3.json', '').replaceAll('.json', '');
}

/// What the model can do, and what a build would carry.
///
/// The page reads this and nothing else: it shows [motions] under the names the
/// stage plays them by, [suggestion] as a first guess at the mapping, and
/// [dropped]/[notes] so the user knows what the pack will lose before they
/// build it.
class Live2dKitReport {
  Live2dKitReport._({
    required this.model,
    required List<Live2dKitMotion> motions,
    required List<Live2dKitExpression> expressions,
    required Map<String, ({int width, int height})> textures,
    required List<String> dropped,
    required this.totalBytes,
    required this.fixedCommas,
    required this.cubism2,
    required List<String> notes,
  }) : motions = List<Live2dKitMotion>.unmodifiable(motions),
       expressions = List<Live2dKitExpression>.unmodifiable(expressions),
       textures = Map<String, ({int width, int height})>.unmodifiable(textures),
       dropped = List<String>.unmodifiable(dropped),
       notes = List<String>.unmodifiable(notes);

  final Live2dKitModel model;

  /// The model's motions under the names the stage plays them by.
  final List<Live2dKitMotion> motions;

  final List<Live2dKitExpression> expressions;

  /// PNG textures and their pixel size, keyed by path relative to the model
  /// root. Measured from the PNG header, never decoded here.
  final Map<String, ({int width, int height})> textures;

  /// Files the pack will not carry because the app does not accept their
  /// extension (a `.psd`, a stray `.7z`, ...).
  final List<String> dropped;

  /// Uncompressed size of every carried file.
  final int totalBytes;

  /// Trailing commas repaired in the descriptor; the app's JSON reader has no
  /// forgiveness, so a descriptor with one would otherwise fail to import.
  final int fixedCommas;

  /// The model is Cubism 2 (`model.json` + `.moc`, motions in the descriptor).
  final bool cubism2;

  /// Short remarks worth showing before a build (repaired commas, missing
  /// textures, motion files the descriptor does not list).
  final List<String> notes;

  Map<String, String?>? _suggestion;

  /// Every state and reaction with the first motion whose name hints at it.
  ///
  /// A hint is never a decision: the page shows these as "maybe" and the user
  /// confirms. `null` means nothing in the model's names looked like that
  /// state, which is exactly the list the user has to be told about.
  Map<String, String?> get suggestion => _suggestion ??= _suggestMotions(motions);
}

/// The converter: inspect a downloaded model, then build a pet or room pack.
///
/// A single pass over the zip is enough for both outputs, so [inspect] is the
/// only read of the download; the builders take its report and never touch the
/// disk again.
abstract final class Live2dKit {
  /// The largest download [inspect] reads, before it is inflated.
  ///
  /// Decoding holds the zip and every entry it carries in memory at once, so a
  /// model past this is refused by its file size alone: the phone would spend
  /// hundreds of megabytes only to be told the model is too big. Anything near
  /// the cap is a model nobody can use as a pet anyway — the pet installer takes
  /// 64 MiB of expanded files (docs/pets/README.md §3.5). The page asks this
  /// before it hands a pick to [inspect], so the answer is advice, not an error
  /// (live2d_convert_page.dart).
  static const int inspectByteCap = 160 * 1024 * 1024;

  /// What the files a pack carries may add up to, read off the zip directory
  /// before a single entry is inflated. The room installer's own limit.
  static const int inspectExpandedCap = _roomTotalCap;

  /// Reads a model zip (a single enclosing folder is stripped) and reports what
  /// the pack could use.
  ///
  /// The zip is the only input: users download `.zip` files, and a shared
  /// folder on Android is not reliably readable as a directory tree.
  /// [byteCap] lowers [inspectByteCap] (tests read small zips).
  static Future<Live2dKitReport> inspect(String zipPath, {int byteCap = inspectByteCap}) async {
    final file = File(zipPath);
    final int length;
    try {
      length = await file.length();
    } on FileSystemException {
      throw Live2dKitException('io', zipPath);
    }
    // Asked before reading: a model this size costs the phone more memory than
    // it has, and the page turns this code into a "make it smaller" answer.
    if (length > byteCap) throw Live2dKitException('too-large', _size(length));

    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } on FileSystemException {
      throw Live2dKitException('io', zipPath);
    }

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes, verify: true);
    } on Object {
      throw Live2dKitException('archive', _basename(zipPath));
    }

    // Collect the entries the pack would see, refusing a zip that could write
    // outside the folder it is unpacked into or that a case-insensitive
    // filesystem (the phone's) would collapse into one file.
    final entries = <String, ArchiveFile>{};
    final aliases = <String, String>{};
    for (final file in archive.files) {
      if (!file.isFile) {
        continue;
      }
      final name = file.name;
      if (name.isEmpty || name.endsWith('/')) {
        continue;
      }
      if (name.startsWith('__MACOSX/') || _basename(name) == '.DS_Store') {
        continue;
      }
      if (!_isSafeRelativeName(name)) {
        throw Live2dKitException('zip', '路径不安全：$name');
      }
      final alias = petNameAlias(name);
      final collision = aliases[alias];
      if (collision != null) {
        throw Live2dKitException('zip', '包里有两个同名条目：$name 和 $collision');
      }
      aliases[alias] = name;
      entries[name] = file;
    }
    if (entries.isEmpty) {
      throw Live2dKitException('zip', '包里没有文件');
    }

    // Summed from the zip directory, before inflating anything: the sizes a
    // pack would carry are known without spending the memory for them.
    var declared = 0;
    for (final MapEntry(:key, :value) in entries.entries) {
      if (!_dataExtensions.contains(_suffix(key))) continue;
      declared += value.size;
      if (declared > inspectExpandedCap) throw Live2dKitException('too-large', _size(declared));
    }

    // Every download of a model folder has that one folder inside the zip;
    // stripping it makes the descriptor path relative to the model itself.
    final entryNames = entries.keys.toList();
    final tops = <String>{for (final name in entryNames) name.split('/').first};
    final strip = tops.length == 1 && entryNames.every((name) => name.contains('/')) ? '${tops.first}/' : '';

    final files = <String, Uint8List>{};
    final relativeNames = <String>[];
    final dropped = <String>[];
    var carriedBytes = 0;
    for (final entry in entries.entries) {
      final name = strip.isEmpty ? entry.key : entry.key.substring(strip.length);
      relativeNames.add(name);
      if (_dataExtensions.contains(_suffix(name))) {
        final data = _readEntry(entry.value, name);
        carriedBytes += data.length;
        if (carriedBytes > _roomTotalCap) {
          throw Live2dKitException('too-large', '模型文件超过 ${_size(_roomTotalCap)}');
        }
        files[name] = data;
      } else {
        dropped.add(name);
      }
    }
    dropped.sort();

    final modern = <String>[];
    final legacy = <String>[];
    var hasMoc = false;
    for (final name in relativeNames) {
      final lower = name.toLowerCase();
      if (lower.endsWith('.model3.json')) {
        modern.add(name);
      } else if (lower.endsWith('model.json')) {
        legacy.add(name);
      }
      if (lower.endsWith('.moc')) {
        hasMoc = true;
      }
    }

    final String descriptor;
    final int cubism;
    if (modern.isNotEmpty) {
      descriptor = _shallowest(modern);
      cubism = 3;
    } else if (legacy.isNotEmpty && hasMoc) {
      descriptor = _shallowest(legacy);
      cubism = 2;
    } else {
      throw Live2dKitException('model', '这里没有 Live2D 模型：缺 *.model3.json（Cubism 3 以上）或 model.json + .moc（Cubism 2）');
    }

    final descriptorBytes = files[descriptor];
    if (descriptorBytes == null) {
      throw Live2dKitException('model', '读不到 $descriptor');
    }
    final parsed = _readJson(descriptorBytes, descriptor);
    final rawDoc = parsed.doc;
    if (rawDoc is! Map<String, dynamic>) {
      throw Live2dKitException('model', '$descriptor 不是一个 JSON 对象');
    }

    final model = Live2dKitModel._(descriptor: descriptor, cubism: cubism, doc: rawDoc, files: files);
    final motions = _motionCatalogue(model);
    final expressions = _expressionCatalogue(model);
    final textures = <String, ({int width, int height})>{};
    for (final entry in files.entries) {
      if (_suffix(entry.key) != '.png' || !_textureNamePattern.hasMatch(entry.key)) {
        continue;
      }
      final measured = pngSize(entry.value);
      if (measured == null) {
        continue;
      }
      textures[entry.key] = (width: measured.$1, height: measured.$2);
    }

    var totalBytes = 0;
    for (final data in files.values) {
      totalBytes += data.length;
    }

    final notes = <String>[];
    if (parsed.commas > 0) {
      notes.add('$descriptor 末尾有 ${parsed.commas} 处多余的逗号（App 会读不进去），已修好');
    }
    final extraMotions = motions.where((motion) => motion.group.isEmpty).length;
    if (extraMotions > 0) {
      notes.add('$extraMotions 个 .motion3.json 没有登记在 $descriptor 里，按文件名提供');
    }
    final missing = <String>[];
    for (final texture in _referenceTextures(rawDoc, cubism)) {
      if (!files.containsKey(texture)) {
        missing.add(texture);
      }
    }
    if (missing.isNotEmpty) {
      notes.add('贴图缺失：${_shortList(missing)}');
    }

    return Live2dKitReport._(
      model: model,
      motions: motions,
      expressions: expressions,
      textures: textures,
      dropped: dropped,
      totalBytes: totalBytes,
      fixedCommas: parsed.commas,
      cubism2: cubism == 2,
      notes: notes,
    );
  }

  /// A mapping with every state and reaction present and `null`.
  ///
  /// The page starts from this and fills in what the user picked; a missing key
  /// would build a pack the app refuses, so the skeleton is the only starting
  /// point the UI offers.
  static Map<String, String?> skeleton(Live2dKitReport report) {
    return <String, String?>{
      for (final state in live2dPetStates) state: null,
      for (final reaction in live2dPetReactions) reaction: null,
    };
  }

  /// Why [mapping] cannot be built; empty means usable.
  ///
  /// Every problem starts with a stable token (`states-missing`,
  /// `reactions-missing`, `key-unknown`, `motion-unknown`, `idle-missing`,
  /// `motions-ignored`) so the page can attach an action or a translation
  /// without parsing the sentence after it.
  static List<String> mappingProblems(Live2dKitReport report, Map<String, String?> mapping) {
    final problems = <String>[];
    final keys = <String>{for (final motion in report.motions) motion.key};

    final missingStates = <String>[
      for (final state in live2dPetStates)
        if (!mapping.containsKey(state)) state,
    ];
    if (missingStates.isNotEmpty) {
      problems.add('states-missing: mapping.states 少了：${missingStates.join('、')}（做不到就写 null，但不能不写）');
    }
    final missingReactions = <String>[
      for (final reaction in live2dPetReactions)
        if (!mapping.containsKey(reaction)) reaction,
    ];
    if (missingReactions.isNotEmpty) {
      problems.add('reactions-missing: mapping.reactions 少了：${missingReactions.join('、')}（做不到就写 null）');
    }

    final known = <String>{...live2dPetStates, ...live2dPetReactions};
    final available = keys.toList()..sort();
    for (final entry in mapping.entries) {
      if (!known.contains(entry.key)) {
        problems.add('key-unknown: mapping 里有 App 不认识的名字：${entry.key}');
        continue;
      }
      final value = entry.value;
      if (value == null) {
        continue;
      }
      if (!keys.contains(value)) {
        final role = live2dPetStates.contains(entry.key) ? '状态' : '事件';
        final choices = available.isEmpty ? '（没有）' : available.join('、');
        problems.add('motion-unknown: $role ${entry.key} 填的动作 "$value" 不在模型里。可用的动作：$choices');
      }
    }

    final idle = mapping['idle'];
    if (idle == null || idle.isEmpty) {
      problems.add('idle-missing: 状态 idle 必须有动作（App 第一次显示和空闲时都要放它）');
    }

    var played = 0;
    for (final value in mapping.values) {
      if (value != null && value.isNotEmpty) {
        played++;
      }
    }
    if (report.motions.isNotEmpty && played == 0) {
      problems.add('motions-ignored: 模型里有 ${report.motions.length} 个动作，你一个都没用上。要么映射上，要么告诉用户为什么全不用');
    }
    return problems;
  }

  /// The 「没实现」 list: states, reactions and motions the pack will not use.
  ///
  /// These are sentences rather than codes because the only thing that can be
  /// done with them is telling the user, verbatim, what their pet cannot do.
  static List<String> unimplemented(Live2dKitReport report, Map<String, String?> mapping) {
    final states = <String>[];
    for (final state in live2dPetStates) {
      final value = mapping[state];
      if (value == null || value.isEmpty) {
        states.add(state);
      }
    }
    final reactions = <String>[];
    for (final reaction in live2dPetReactions) {
      final value = mapping[reaction];
      if (value == null || value.isEmpty) {
        reactions.add(reaction);
      }
    }
    final used = <String>{};
    for (final value in mapping.values) {
      if (value != null && value.isNotEmpty) {
        used.add(value);
      }
    }
    final unused = <String>{
      for (final motion in report.motions)
        if (!used.contains(motion.key)) motion.key,
    };
    final unusedList = unused.toList()..sort();
    return <String>[
      '没实现的状态：${states.isEmpty ? '无' : states.join('、')}',
      '没实现的事件：${reactions.isEmpty ? '无' : reactions.join('、')}',
      '没用上的动作：${unusedList.isEmpty ? '无' : unusedList.join('、')}',
    ];
  }

  /// Builds a pet pack: `pack.json` plus `character/<model>`.
  ///
  /// [textureMax] is the longest texture side kept; textures larger than that
  /// on either side are downscaled, because a 4096² texture is a 64 MB PNG the
  /// phone has to decode for every model switch. `0` keeps them as they are.
  ///
  /// Sounds are always dropped: a Live2D pet's stage never plays them, and they
  /// are the largest files in the download. No poster is written either — the
  /// app renders the model on first display and keeps that frame.
  static Future<Uint8List> buildPet(
    Live2dKitReport report,
    Map<String, String?> mapping, {
    int textureMax = _textureDefaultMax,
    String? name,
    String? id,
  }) async {
    final problems = mappingProblems(report, mapping);
    if (problems.isNotEmpty) {
      throw Live2dKitException('mapping', problems.join('\n'));
    }

    // Fixed by the pet pack schema: the floating window and the chat stage lay
    // out the speech bubble and the anchor against these numbers.
    const int width = 1024;
    const int height = 1024;
    final model = report.model;
    final modelName = model.name;
    final packId = id == null || id.isEmpty ? _slug(modelName) : id;
    final packName = name == null || name.isEmpty ? modelName : name;

    final character = <String, Uint8List>{};
    var copied = 0;
    var copiedBytes = 0;
    for (final entry in model.files.entries) {
      final rel = entry.key;
      final suffix = _suffix(rel);
      if (_soundExtensions.contains(suffix)) {
        continue;
      }
      var bytes = entry.value;
      if (textureMax > 0 && suffix == '.png' && _textureNamePattern.hasMatch(rel)) {
        bytes = await _shrinkPng(bytes, textureMax) ?? bytes;
      }
      if (bytes.length > _live2dFileCap) {
        throw Live2dKitException('too-large', '$rel 有 ${_size(bytes.length)}，超过单个文件 32 MB 的上限');
      }
      copied++;
      copiedBytes += bytes.length;
      character[rel] = bytes;
    }
    if (copied > _live2dFilesCap) {
      throw Live2dKitException('too-large', '角色有 $copied 个文件，超过 $_live2dFilesCap 个的上限');
    }
    if (copiedBytes > _live2dTotalCap) {
      throw Live2dKitException('too-large', '角色文件共 ${_size(copiedBytes)}，超过 200 MB 的上限');
    }
    // The descriptor the app reads is ours, not the exporter's: `Sound` entries
    // point at files the pack no longer carries, and a dangling reference makes
    // the stage log a 404 for every tap.
    character[model.descriptor] = _encodeJson(_petDescriptor(model, keepSound: false));

    final states = <String, String>{};
    for (final state in live2dPetStates) {
      final value = mapping[state];
      if (value != null && value.isNotEmpty) {
        states[state] = value;
      }
    }
    final reactions = <String, String>{};
    for (final reaction in live2dPetReactions) {
      final value = mapping[reaction];
      if (value != null && value.isNotEmpty) {
        reactions[reaction] = value;
      }
    }

    final pack = <String, Object?>{
      'schema': 1,
      'id': packId,
      'name': packName,
      'type': 'live2d',
      'scale': 1,
      'pixelArt': false,
      'canvas': <String, Object?>{'w': width, 'h': height},
      'anchor': <String, Object?>{'x': width ~/ 2, 'baseline': height},
      'contentBox': <String, Object?>{'x': 0, 'y': 0, 'w': width, 'h': height},
      'live2d': <String, Object?>{
        'model': model.descriptor,
        'poster': 'poster.png',
        'states': states,
        'reactions': reactions,
        // `idle` is guaranteed non-null by [mappingProblems]; writing it as the
        // fallback means a state the pack forgot still plays something.
        'fallback': mapping['idle'],
      },
    };

    final entries = <(String, Uint8List)>[('pack.json', _encodeJson(pack))];
    final rels = character.keys.toList()..sort();
    for (final rel in rels) {
      final data = character[rel];
      if (data != null) {
        entries.add(('character/$rel', data));
      }
    }
    return _writeZip(entries);
  }

  /// Builds a companion-room pack: `character/` holds the model and the room's
  /// `character.json`, sounds kept, and — when the caller has it — `runtime/`
  /// carries the stage so the pack installs on a phone that has none.
  ///
  /// [emotions] maps a feeling of hers (`companionAdaptEmotions`) to one of the
  /// model's own expressions, by name; [actions] maps a gesture
  /// (`companionAdaptActions`) to one of its motion groups. Nothing is invented:
  /// a model without expressions gets no `emotions` block, and the room's
  /// defaults keep working.
  ///
  /// [framing] is the room's camera — `zoom`, `x` and `y`, the keys the stage
  /// reads from `character.json` (docs/design/companion.md). Omitted, the room
  /// keeps its own 1.2× framing.
  static Future<Uint8List> buildRoom(
    Live2dKitReport report, {
    String? name,
    Map<String, String?> emotions = const {},
    Map<String, String?> actions = const {},
    Map<String, double>? framing,
    Map<String, Uint8List> runtime = const {},
  }) async {
    final model = report.model;
    final character = <String, Uint8List>{...model.files};
    var total = 0;
    for (final data in model.files.values) {
      total += data.length;
    }
    var runtimeBytes = 0;
    for (final data in runtime.values) {
      runtimeBytes += data.length;
    }
    if (character.length + runtime.length > _roomFilesCap) {
      throw Live2dKitException('too-large', '角色有 ${character.length + runtime.length} 个文件，超过 $_roomFilesCap 个的上限');
    }
    if (total + runtimeBytes > _roomTotalCap) {
      throw Live2dKitException('too-large', '角色文件共 ${_size(total + runtimeBytes)}，超过 400 MB 的上限');
    }
    // Rewritten only so the file the room installs has no trailing commas; the
    // sounds stay, because the room's stage plays them.
    character[model.descriptor] = _encodeJson(_petDescriptor(model, keepSound: true));

    final feelings = <String, Object?>{};
    for (final MapEntry(:key, :value) in emotions.entries) {
      if (value == null || value.isEmpty) continue;
      feelings[key] = <String, Object?>{'expression': value};
    }
    final gestures = <String, Object?>{};
    for (final MapEntry(:key, :value) in actions.entries) {
      if (value == null || value.isEmpty) continue;
      gestures[key] = <String, Object?>{'motion': value};
    }
    character['character.json'] = _encodeJson(<String, Object?>{
      'schema': 1,
      'name': name == null || name.isEmpty ? model.name : name,
      'model': model.descriptor,
      if (framing != null && framing.isNotEmpty) 'framing': framing,
      if (feelings.isNotEmpty) 'emotions': feelings,
      if (gestures.isNotEmpty) 'actions': gestures,
    });
    // What the installer rewrites anyway; written here so the zip reads as a
    // pack before it is installed, and so `checkPack` can see the file list.
    final index = character.keys.where((rel) => rel != 'index.json').toList()..sort();
    character['index.json'] = _encodeJson(index);

    final entries = <(String, Uint8List)>[];
    final names = character.keys.toList()..sort();
    for (final rel in names) {
      final data = character[rel];
      if (data != null) {
        entries.add(('character/$rel', data));
      }
    }
    final runtimeNames = runtime.keys.toList()..sort();
    for (final rel in runtimeNames) {
      final data = runtime[rel];
      if (data != null) {
        entries.add(('runtime/$rel', data));
      }
    }
    return _writeZip(entries);
  }

  /// The first of the model's expressions whose name reads like each feeling;
  /// null where nothing matches. What the page starts from, not a decision.
  static Map<String, String?> suggestRoomEmotions(Live2dKitReport report) {
    final result = <String, String?>{for (final key in companionAdaptEmotions) key: null};
    final expressions = <Live2dKitExpression>[...report.expressions]..sort((a, b) => a.name.compareTo(b.name));
    for (final expression in expressions) {
      final label = '${expression.name} ${_basename(expression.file)}';
      for (final hint in _emotionHints) {
        if (result[hint.target] != null) continue;
        if (hint.pattern.hasMatch(label)) result[hint.target] = expression.name;
      }
    }
    return result;
  }

  /// The first motion whose name reads like each gesture of hers.
  static Map<String, String?> suggestRoomActions(Live2dKitReport report) {
    final result = <String, String?>{for (final key in companionAdaptActions) key: null};
    for (final motion in report.motions) {
      final label = '${motion.group} ${_basename(motion.file)}';
      for (final hint in _gestureHints) {
        if (result[hint.target] != null) continue;
        if (hint.pattern.hasMatch(label)) result[hint.target] = motion.key;
      }
    }
    return result;
  }

  /// The stage's runtime, as `runtime/`-relative name → bytes, from an installed
  /// companion pack. Null when this phone has none: a room pack without one
  /// only installs where a runtime already is.
  static Future<Map<String, Uint8List>?> readRuntime(Directory dir) async {
    if (!await dir.exists()) return null;
    final files = <String, Uint8List>{};
    var count = 0;
    var bytes = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      count++;
      final data = await entity.readAsBytes();
      bytes += data.length;
      if (bytes > _live2dTotalCap || count > _live2dFilesCap) {
        throw const Live2dKitException('too-large', '运行库太大，不能一起打包');
      }
      files[entity.path.substring(dir.path.length + 1).replaceAll('\\', '/')] = data;
    }
    return files.isEmpty ? null : files;
  }

  /// The install gates, as problem sentences; empty means the pack imports.
  ///
  /// [pet] selects the pet rules (256 entries, 64 MB, `pack.json`) or the room
  /// rules (4000 entries, 400 MB, a descriptor at the root). Both are checked
  /// here rather than trusted from the builder, because the builder and the
  /// installer agree only as long as someone keeps testing that they do.
  static Future<List<String>> checkPack(Uint8List zip, {required bool pet}) async {
    final problems = <String>[];
    final cap = pet ? petArchiveByteCap : _roomTotalCap;
    if (zip.length > cap) {
      problems.add(pet ? '包 ${_size(zip.length)}，超过 64 MB' : '包 ${_size(zip.length)}，超过 400 MB');
    }

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zip, verify: true);
    } on Object {
      return <String>[...problems, '不是有效的 zip'];
    }
    final infos = <ArchiveFile>[
      for (final file in archive.files)
        if (file.isFile) file,
    ];
    final names = <String>[for (final info in infos) info.name];

    var expanded = 0;
    for (final info in infos) {
      expanded += info.size;
    }
    if (expanded > (pet ? petArchiveExpandedCap : _roomTotalCap)) {
      problems.add(pet ? '解压后 ${_size(expanded)}，超过 64 MB' : '解压后 ${_size(expanded)}，超过 400 MB');
    }
    final entryCap = pet ? petArchiveEntryCap : _roomFilesCap;
    if (infos.length > entryCap) {
      problems.add(pet ? '${infos.length} 个条目，超过 256' : '${infos.length} 个文件，超过 4000');
    }
    final unsafe = <String>[
      for (final name in names)
        if (!_isSafeRelativeName(name)) name,
    ];
    if (unsafe.isNotEmpty) {
      problems.add('路径不安全：${unsafe.first}');
    }

    var characterBytes = 0;
    for (final info in infos) {
      final suffix = _suffix(info.name);
      final runtime = info.name.startsWith('runtime/');
      if (runtime) {
        // The room's stage travels with the pack; a pet never carries one.
        if (pet) problems.add('宠物包不能带 ${info.name}');
        continue;
      }
      if (!_dataExtensions.contains(suffix)) {
        problems.add('不能带 ${info.name}');
        continue;
      }
      if (pet && info.name.startsWith('character/')) {
        characterBytes += info.size;
        if (info.size > _live2dFileCap) {
          problems.add('${info.name} 有 ${_size(info.size)}，单个文件上限 32 MB');
        }
      }
    }
    if (pet && characterBytes > _live2dTotalCap) {
      problems.add('character/ 共 ${_size(characterBytes)}，超过 200 MB');
    }

    if (pet) {
      final packInfo = _firstEntry(infos, 'pack.json');
      if (packInfo == null) {
        problems.add('缺 pack.json');
      } else {
        final raw = _tryRead(packInfo);
        if (raw == null) {
          problems.add('pack.json 读不出来');
        } else {
          if (raw.length > petJsonCap) {
            problems.add('pack.json 超过 256 KB');
          }
          Object? decoded;
          try {
            decoded = jsonDecode(utf8.decode(raw));
          } on Object {
            problems.add('pack.json 读不出来');
          }
          if (decoded is Map<String, dynamic>) {
            problems.addAll(_checkPetJson(decoded, infos, names));
          } else if (decoded != null) {
            problems.add('pack.json 要是一个对象');
          }
        }
      }
    } else {
      final descriptors = <String>[
        for (final name in names)
          if (name.toLowerCase().endsWith('.model3.json') || name.toLowerCase().endsWith('model.json')) name,
      ];
      if (descriptors.isEmpty) {
        problems.add('包里没有模型描述文件');
      }
    }
    return problems;
  }
}

/// One motion3 file's metadata, zeros when the file could not be read.
class _MotionMeta {
  const _MotionMeta({this.duration = 0, this.loop = false, this.curves = 0, this.params = const [], this.parts = 0});

  final double duration;
  final bool loop;
  final int curves;
  final List<String> params;
  final int parts;
}

/// The pet-pack gates for `pack.json`, mirroring `pet_pack.dart` and the
/// installer in `pet_live2d_install.dart`.
List<String> _checkPetJson(Map<String, dynamic> pack, List<ArchiveFile> infos, List<String> names) {
  final problems = <String>[];
  if (pack['schema'] != 1) {
    problems.add('schema 要写 1');
  }
  final id = pack['id'];
  if (id is! String || id.trim().isEmpty) {
    problems.add('缺 id');
  }
  if (pack['type'] != 'live2d') {
    problems.add('type 要写 live2d');
  }

  final canvas = _mapOf(pack['canvas']);
  final width = canvas['w'];
  final height = canvas['h'];
  final canvasOk = width is int && height is int && width > 0 && height > 0;
  final canvasWidth = width is int ? width : 0;
  final canvasHeight = height is int ? height : 0;
  if (!canvasOk) {
    problems.add('canvas 要写 {w, h}');
  }

  final box = _mapOf(pack['contentBox']);
  final boxX = box['x'];
  final boxY = box['y'];
  final boxWidth = box['w'];
  final boxHeight = box['h'];
  if (boxX is! int || boxY is! int || boxWidth is! int || boxHeight is! int) {
    problems.add('contentBox 要写 {x, y, w, h}');
  } else if (boxX < 0 ||
      boxY < 0 ||
      boxWidth <= 0 ||
      boxHeight <= 0 ||
      (canvasOk && (boxX + boxWidth > canvasWidth || boxY + boxHeight > canvasHeight))) {
    problems.add('contentBox 超出了 canvas');
  }

  final anchor = _mapOf(pack['anchor']);
  final anchorX = anchor['x'];
  final baseline = anchor['baseline'];
  if (anchorX is! int || baseline is! int) {
    problems.add('anchor 要写 {x, baseline}');
  } else if (anchorX < 0 || baseline < 0 || (canvasOk && (anchorX > canvasWidth || baseline > canvasHeight))) {
    problems.add('anchor 超出了 canvas');
  }

  final live2d = _mapOf(pack['live2d']);
  final model = live2d['model'];
  if (model is! String || model.isEmpty) {
    problems.add('live2d.model 缺');
  } else if (!_isSafeRelativeName(model)) {
    problems.add('live2d.model 不是安全的相对路径：$model');
  } else if (!names.contains('character/$model')) {
    problems.add('live2d.model 指向的 $model 不在包里');
  } else {
    problems.addAll(_descriptorProblems('character/$model', infos, names));
  }

  final states = live2d['states'];
  if (states is! Map<String, dynamic>) {
    problems.add('states 里必须有 idle');
  } else {
    if (!states.containsKey('idle')) {
      problems.add('states 里必须有 idle');
    }
    for (final entry in states.entries) {
      if (!live2dPetStates.contains(entry.key)) {
        problems.add('states 里有 App 不认识的状态 ${entry.key}');
      }
      final value = entry.value;
      if (value is! String || value.isEmpty) {
        problems.add('states.${entry.key} 要是动作名');
      }
    }
  }

  final reactions = live2d['reactions'];
  if (reactions is Map<String, dynamic>) {
    for (final entry in reactions.entries) {
      if (!live2dPetReactions.contains(entry.key)) {
        problems.add('reactions 里有 App 不认识的 ${entry.key}');
      }
      final value = entry.value;
      if (value is! String || value.isEmpty) {
        problems.add('reactions.${entry.key} 要是动作名');
      }
    }
  }

  final posterValue = live2d['poster'];
  final poster = posterValue is String && posterValue.isNotEmpty ? posterValue : 'poster.png';
  if (posterValue != null && posterValue is! String) {
    problems.add('live2d.poster 要是一个路径');
  }
  if (!_isSafeRelativeName(poster)) {
    problems.add('live2d.poster 不是安全的相对路径：$poster');
  } else {
    final posterInfo = _firstEntry(infos, poster);
    if (posterInfo != null) {
      final data = _tryRead(posterInfo);
      if (data == null) {
        problems.add('封面读不出来');
      } else {
        if (data.length > petSheetByteCap) {
          problems.add('封面超过 8 MB');
        }
        final size = pngSize(data);
        if (size == null || !pngIntact(data)) {
          problems.add('封面不是完整的 PNG');
        } else {
          if (canvasOk && (size.$1 != canvasWidth || size.$2 != canvasHeight)) {
            problems.add('封面 ${size.$1}×${size.$2} 和画布 $canvasWidth×$canvasHeight 不一致');
          }
          if (size.$1 > petSheetSideCap || size.$2 > petSheetSideCap) {
            problems.add('封面边长超过 4096');
          } else if (size.$1 * size.$2 * 4 > petSheetDecodedCap) {
            problems.add('封面解压后超过 16 MB');
          }
        }
      }
    }
  }
  return problems;
}

/// Whether every file the descriptor points at is inside the pack, so the
/// stage gets a model it can actually load instead of a 404 per reference.
List<String> _descriptorProblems(String modelPath, List<ArchiveFile> infos, List<String> names) {
  final problems = <String>[];
  final info = _firstEntry(infos, modelPath);
  if (info == null) {
    return problems;
  }
  final data = _tryRead(info);
  if (data == null) {
    problems.add('$modelPath 读不出来');
    return problems;
  }
  Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(data));
  } on Object {
    problems.add('$modelPath 不是合法 JSON');
    return problems;
  }
  if (decoded is! Map<String, dynamic>) {
    problems.add('$modelPath 要是一个对象');
    return problems;
  }

  final home = _dirname(modelPath);
  final descriptorName = _basename(modelPath).toLowerCase();
  final legacy = descriptorName == 'model.json' || descriptorName.endsWith('.model.json');
  void requireFile(Object? raw, String role) {
    if (raw is! String || raw.isEmpty) {
      problems.add('$modelPath 缺 $role');
      return;
    }
    if (!_isSafeRelativeName(raw)) {
      problems.add('$modelPath 的 $role 路径不安全：$raw');
      return;
    }
    final path = _childPath(home, raw);
    if (!names.contains(path)) {
      problems.add('$modelPath 的 $role 指向的 $path 不在包里');
    }
  }

  if (legacy) {
    requireFile(decoded['model'], 'model');
    final textures = decoded['textures'];
    if (textures is List && textures.isNotEmpty) {
      for (final texture in textures) {
        requireFile(texture, 'textures');
      }
    } else {
      problems.add('$modelPath 缺 textures');
    }
    for (final role in const <String>['physics', 'pose']) {
      if (decoded.containsKey(role)) {
        requireFile(decoded[role], role);
      }
    }
    final expressions = decoded['expressions'];
    if (expressions is Map<String, dynamic>) {
      for (final entry in expressions.entries) {
        requireFile(entry.value, 'expressions.${entry.key}');
      }
    }
    final motions = decoded['motions'];
    if (motions is Map<String, dynamic>) {
      for (final group in motions.entries) {
        final entries = group.value;
        if (entries is! List) {
          continue;
        }
        for (var index = 0; index < entries.length; index++) {
          final entry = entries[index];
          if (entry is Map<String, dynamic>) {
            requireFile(entry['file'] ?? entry['File'], 'motions.${group.key}[${index + 1}]');
          }
        }
      }
    }
    return problems;
  }

  final references = decoded['FileReferences'];
  if (references is! Map<String, dynamic>) {
    problems.add('$modelPath 缺 FileReferences');
    return problems;
  }
  requireFile(references['Moc'] ?? references['MocFile'], 'Moc');
  final textures = references['Textures'];
  if (textures is List && textures.isNotEmpty) {
    for (final texture in textures) {
      requireFile(texture, 'Textures');
    }
  } else {
    problems.add('$modelPath 缺 Textures');
  }
  for (final role in const <String>['Physics', 'Pose', 'DisplayInfo']) {
    if (references.containsKey(role)) {
      requireFile(references[role], role);
    }
  }
  final expressions = references['Expressions'];
  if (expressions is List) {
    for (var index = 0; index < expressions.length; index++) {
      final entry = expressions[index];
      if (entry is Map<String, dynamic>) {
        requireFile(entry['File'], 'Expressions[${index + 1}]');
      }
    }
  }
  final motions = references['Motions'];
  if (motions is Map<String, dynamic>) {
    for (final group in motions.entries) {
      final entries = group.value;
      if (entries is! List) {
        continue;
      }
      for (var index = 0; index < entries.length; index++) {
        final entry = entries[index];
        if (entry is Map<String, dynamic>) {
          requireFile(entry['File'], 'Motions.${group.key}[${index + 1}]');
        }
      }
    }
  }
  return problems;
}

/// The model's motions under the names the stage plays them by.
List<Live2dKitMotion> _motionCatalogue(Live2dKitModel model) {
  final out = <Live2dKitMotion>[];
  if (model.cubism == 2) {
    final groups = _mapOf(model.doc['motions']);
    for (final group in groups.entries) {
      final entries = group.value;
      if (entries is! List) {
        continue;
      }
      var seen = 0;
      for (final raw in entries) {
        if (raw is! Map<String, dynamic>) {
          continue;
        }
        final file = raw['file'] ?? raw['File'];
        if (file is! String || file.isEmpty) {
          continue;
        }
        seen++;
        out.add(
          Live2dKitMotion(
            key: entries.length == 1 ? group.key : '${group.key}_$seen',
            group: group.key,
            index: seen - 1,
            file: file,
            duration: 0,
            loop: false,
            gesture: false,
          ),
        );
      }
    }
    return out;
  }

  final references = _mapOf(model.doc['FileReferences']);
  final groups = _mapOf(references['Motions']);
  final listed = <String>{};
  for (final group in groups.entries) {
    final entries = group.value;
    if (entries is! List || entries.isEmpty) {
      continue;
    }
    for (var index = 0; index < entries.length; index++) {
      final raw = entries[index];
      if (raw is! Map<String, dynamic>) {
        continue;
      }
      final file = raw['File'];
      if (file is! String || file.isEmpty) {
        continue;
      }
      listed.add(file.replaceAll('\\', '/'));
      final meta = _motionMeta(model.files, file);
      out.add(
        Live2dKitMotion(
          key: entries.length == 1 ? group.key : '${group.key}_${index + 1}',
          group: group.key,
          index: index,
          file: file,
          duration: meta.duration,
          loop: meta.loop,
          gesture: _gesture(meta),
        ),
      );
    }
  }

  // Motions the descriptor forgot: the stage offers them by file name, so the
  // pack can use them too, up to the stage's own EXTRA_FILES_MAX.
  final extras = <String>[];
  for (final rel in model.files.keys) {
    if (!rel.toLowerCase().endsWith('.motion3.json') || listed.contains(rel)) {
      continue;
    }
    extras.add(rel);
  }
  extras.sort();
  for (final rel in extras.take(_extraFilesMax)) {
    final meta = _motionMeta(model.files, rel);
    final base = _basename(rel);
    out.add(
      Live2dKitMotion(
        key: base.substring(0, base.length - '.motion3.json'.length),
        group: '',
        index: 0,
        file: rel,
        duration: meta.duration,
        loop: meta.loop,
        gesture: _gesture(meta),
      ),
    );
  }
  return out;
}

/// The model's expressions: listed by the descriptor, then extra `.exp3.json`.
List<Live2dKitExpression> _expressionCatalogue(Live2dKitModel model) {
  final out = <Live2dKitExpression>[];
  if (model.cubism == 2) {
    final groups = _mapOf(model.doc['expressions']);
    for (final group in groups.entries) {
      final file = group.value;
      if (file is String && file.isNotEmpty) {
        out.add(Live2dKitExpression(name: group.key, file: file));
      }
    }
    return out;
  }

  final references = _mapOf(model.doc['FileReferences']);
  final listed = <String>{};
  final entries = references['Expressions'];
  if (entries is List) {
    for (final raw in entries) {
      if (raw is! Map<String, dynamic>) {
        continue;
      }
      final file = raw['File'];
      if (file is! String || file.isEmpty) {
        continue;
      }
      listed.add(file.replaceAll('\\', '/'));
      final name = raw['Name'];
      out.add(Live2dKitExpression(name: name is String && name.isNotEmpty ? name : _basename(file), file: file));
    }
  }
  final extras = <String>[];
  for (final rel in model.files.keys) {
    if (!rel.toLowerCase().endsWith('.exp3.json') || listed.contains(rel)) {
      continue;
    }
    extras.add(rel);
  }
  extras.sort();
  for (final rel in extras.take(_extraFilesMax)) {
    final base = _basename(rel);
    out.add(Live2dKitExpression(name: base.substring(0, base.length - '.exp3.json'.length), file: rel));
  }
  return out;
}

/// Duration, loop and the parameters a motion3 moves; zeros when unreadable.
///
/// An exporter that wrote a motion the app cannot read is not an error here:
/// the report still lists the motion (the stage may play its first frame), and
/// only the gesture hint is lost.
_MotionMeta _motionMeta(Map<String, Uint8List> files, String rel) {
  final bytes = files[rel.replaceAll('\\', '/')];
  if (bytes == null) {
    return const _MotionMeta();
  }
  Object? doc;
  try {
    doc = _readJson(bytes, rel).doc;
  } on Live2dKitException {
    return const _MotionMeta();
  }
  if (doc is! Map<String, dynamic>) {
    return const _MotionMeta();
  }
  final head = _mapOf(doc['Meta']);
  var curves = 0;
  var parts = 0;
  final params = <String>[];
  final rawCurves = doc['Curves'];
  if (rawCurves is List) {
    for (final curve in rawCurves) {
      if (curve is! Map<String, dynamic>) {
        continue;
      }
      curves++;
      final target = curve['Target'];
      final id = curve['Id'];
      if (target == 'Parameter' && id is String && id.isNotEmpty) {
        params.add(id);
      } else if (target == 'Part') {
        parts++;
      }
    }
  }
  return _MotionMeta(
    duration: _number(head['Duration']),
    loop: _truthy(head['Loop']),
    curves: curves,
    params: List<String>.unmodifiable(params),
    parts: parts,
  );
}

/// Whether a motion reads as a gesture rather than a prop swaying.
bool _gesture(_MotionMeta meta) {
  if (meta.curves == 0) {
    return false;
  }
  final moved = <String>[];
  for (final parameter in meta.params) {
    if (!_propParams.hasMatch(parameter)) {
      moved.add(parameter);
    }
  }
  if (meta.params.isEmpty && meta.parts == 0) {
    return false;
  }
  if (moved.isEmpty && meta.parts == 0) {
    return false;
  }
  return meta.duration >= _gestureMinDuration;
}

/// The descriptor a pack carries: references kept, sounds optional.
Map<String, dynamic> _petDescriptor(Live2dKitModel model, {required bool keepSound}) {
  final copy = jsonDecode(jsonEncode(model.doc));
  if (copy is! Map<String, dynamic>) {
    throw Live2dKitException('model', '${model.descriptor} 不是一个 JSON 对象');
  }
  final doc = copy;
  if (model.cubism == 2) {
    if (!keepSound) {
      final motions = doc['motions'];
      if (motions is Map<String, dynamic>) {
        for (final group in motions.values) {
          if (group is! List) {
            continue;
          }
          for (final entry in group) {
            if (entry is Map<String, dynamic>) {
              entry.remove('sound');
              entry.remove('Sound');
            }
          }
        }
      }
    }
    return doc;
  }

  final rawReferences = doc['FileReferences'];
  final Map<String, dynamic> references;
  if (rawReferences is Map<String, dynamic>) {
    references = rawReferences;
  } else {
    references = <String, dynamic>{};
    doc['FileReferences'] = references;
  }
  final motions = references['Motions'];
  if (motions is Map<String, dynamic>) {
    for (final group in motions.values) {
      if (group is! List) {
        continue;
      }
      for (final entry in group) {
        if (entry is Map<String, dynamic> && !keepSound) {
          entry.remove('Sound');
        }
      }
    }
  }
  return doc;
}

/// The states and reactions with the first motion whose name hints at them.
Map<String, String?> _suggestMotions(List<Live2dKitMotion> motions) {
  final result = <String, String?>{};
  for (final target in <String>[...live2dPetStates, ...live2dPetReactions]) {
    result[target] = null;
  }
  for (final motion in motions) {
    final label = '${motion.group} ${_basename(motion.file)}';
    for (final hint in _hints) {
      if (result[hint.target] != null) {
        continue;
      }
      if (hint.pattern.hasMatch(label)) {
        result[hint.target] = motion.key;
      }
    }
  }
  return result;
}

/// A motion whose name reads like a state, by what the model's author called
/// it. The page shows these as guesses; the user confirms them.
final List<({String target, RegExp pattern})> _hints = <({String target, RegExp pattern})>[
  (target: 'idle', pattern: RegExp(r'idle|待机|呼吸|stand|loop', caseSensitive: false)),
  (target: 'thinking', pattern: RegExp(r'think|思考|想|hmm|\bplan', caseSensitive: false)),
  (target: 'working', pattern: RegExp(r'work|工作|打字|type|write|busy|study|学习', caseSensitive: false)),
  (target: 'juggling', pattern: RegExp(r'juggl|杂耍|ball|抛', caseSensitive: false)),
  (target: 'sweeping', pattern: RegExp(r'sweep|扫|clean|dust', caseSensitive: false)),
  (target: 'notification', pattern: RegExp(r'note|通知|消息|message|bell|ring', caseSensitive: false)),
  (target: 'attention', pattern: RegExp(r'hello|hi|你好|wave|挥手|greet|打招呼|attention|敬礼', caseSensitive: false)),
  (target: 'error', pattern: RegExp(r'error|错|fail|拒绝|sad|难过|cry|哭', caseSensitive: false)),
  (target: 'carrying', pattern: RegExp(r'carry|拿|hold|抱|grab', caseSensitive: false)),
  (target: 'sleeping', pattern: RegExp(r'sleep|睡|nap|doze|zzz', caseSensitive: false)),
  (target: 'waking', pattern: RegExp(r'wake|醒|stretch|伸懒腰|yawn|哈欠', caseSensitive: false)),
  (target: 'tapLeft', pattern: RegExp(r'tap.?body|taphead|touch|摸|碰|poke|戳', caseSensitive: false)),
  (target: 'tapRight', pattern: RegExp(r'tap.?body|taphead|touch|摸|碰|poke|戳', caseSensitive: false)),
  (target: 'tickle', pattern: RegExp(r'tickle|挠|痒|laugh|笑', caseSensitive: false)),
  (target: 'annoyed', pattern: RegExp(r'angry|生气|annoy|怒|pout|鼓脸|shy|害羞', caseSensitive: false)),
  (target: 'drag', pattern: RegExp(r'drag|拖|fly|飞|float|飘|swing', caseSensitive: false)),
];

/// An expression whose name reads like one of her feelings. The room's ten
/// feelings are fixed (`companionAdaptEmotions`); a model's expression names are
/// not, so the page offers these as guesses.
final List<({String target, RegExp pattern})> _emotionHints = <({String target, RegExp pattern})>[
  (target: 'calm', pattern: RegExp(r'calm|平静|neutral|normal|default|普通|默认|平淡', caseSensitive: false)),
  (target: 'happy', pattern: RegExp(r'happ|smil|joy|fun|laugh|笑|开心|高兴|喜', caseSensitive: false)),
  (target: 'shy', pattern: RegExp(r'shy|blush|embarrass|fluster|害羞|脸红|羞|腼腆', caseSensitive: false)),
  (target: 'sad', pattern: RegExp(r'sad|sorrow|cry|tear|down|难过|伤心|哭|悲|委屈', caseSensitive: false)),
  (target: 'angry', pattern: RegExp(r'ang|mad|annoy|irritat|rage|怒|生气|恼|不爽', caseSensitive: false)),
  (target: 'surprised', pattern: RegExp(r'surpris|shock|star(e|ed)|gasp|惊讶|吃惊|震惊|愣', caseSensitive: false)),
  (target: 'confused', pattern: RegExp(r'confus|puzzl|frown|question|疑惑|困惑|不解|茫然', caseSensitive: false)),
  (target: 'smug', pattern: RegExp(r'smug|proud|confiden|smirk|得意|自信|傲', caseSensitive: false)),
  (target: 'sleepy', pattern: RegExp(r'sleep|sleepy|tired|drow|doz|zzz|困|睡|乏|倦', caseSensitive: false)),
  (target: 'worried', pattern: RegExp(r'worr|nervous|anxious|uneasy|担心|不安|紧张|忧虑', caseSensitive: false)),
];

/// A motion whose name reads like one of her gestures (`companionAdaptActions`).
final List<({String target, RegExp pattern})> _gestureHints = <({String target, RegExp pattern})>[
  (target: 'nod', pattern: RegExp(r'nod|点头|点头|肯', caseSensitive: false)),
  (target: 'nodSmall', pattern: RegExp(r'nod|点头|small', caseSensitive: false)),
  (target: 'shake', pattern: RegExp(r'shak|deny|摇头|不', caseSensitive: false)),
  (target: 'tilt', pattern: RegExp(r'tilt|歪头|倾|歪', caseSensitive: false)),
  (target: 'tiltLeft', pattern: RegExp(r'tilt|歪头|倾', caseSensitive: false)),
  (target: 'lookUp', pattern: RegExp(r'look.?up|抬头|仰|up', caseSensitive: false)),
  (target: 'recoil', pattern: RegExp(r'recoil|lean.?back|退|闪|缩', caseSensitive: false)),
  (target: 'duck', pattern: RegExp(r'duck|bow|低头|俯|低', caseSensitive: false)),
  (target: 'sway', pattern: RegExp(r'sway|swing|摇|摆|晃', caseSensitive: false)),
  (target: 'stretch', pattern: RegExp(r'stretch|伸|伸展|懒腰', caseSensitive: false)),
  (target: 'yawn', pattern: RegExp(r'yawn|哈欠|awake|醒', caseSensitive: false)),
  (target: 'wave', pattern: RegExp(r'wave|挥手|hi\b|hello|greet|打招呼', caseSensitive: false)),
];

/// Downscales a texture to [limit] on its longest side; `null` means "copy the
/// original" (already small enough, or a PNG the engine cannot decode — one
/// unreadable prop texture must not abort the whole pack).
Future<Uint8List?> _shrinkPng(Uint8List source, int limit) async {
  final measured = pngSize(source);
  if (measured == null) {
    return null;
  }
  final (width, height) = measured;
  final longest = math.max(width, height);
  if (longest <= limit) {
    return null;
  }
  final scale = limit / longest;
  final targetWidth = math.max(1, (width * scale).round());
  final targetHeight = math.max(1, (height * scale).round());
  ui.Codec? codec;
  ui.Image? image;
  try {
    codec = await ui.instantiateImageCodec(source, targetWidth: targetWidth, targetHeight: targetHeight);
    final frame = await codec.getNextFrame();
    image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) {
      return null;
    }
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } on Object {
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}

/// Repairs the two things exporters get slightly wrong: a UTF-8 BOM and the
/// trailing comma a hand-edited descriptor usually has.
///
/// Returns the parsed value and how many commas were repaired, because the
/// report has to tell the user their descriptor was broken (and that the pack's
/// copy no longer is).
({Object? doc, int commas}) _readJson(Uint8List data, String name) {
  final body = data.length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF
      ? Uint8List.sublistView(data, 3)
      : data;
  final text = utf8.decode(body, allowMalformed: true);
  final trailing = RegExp(r',(?=\s*[}\]])');
  final commas = trailing.allMatches(text).length;
  final fixed = commas == 0 ? text : text.replaceAll(trailing, '');
  try {
    return (doc: jsonDecode(fixed), commas: commas);
  } on FormatException {
    throw Live2dKitException('json', name);
  }
}

/// The pack's JSON layout: UTF-8, LF, two-space indent, no BOM, no trailing
/// comma — everything the exporters got wrong once already.
Uint8List _encodeJson(Object? data) {
  final text = const JsonEncoder.withIndent('  ').convert(data);
  return Uint8List.fromList(utf8.encode('$text\n'));
}

Uint8List _writeZip(List<(String, Uint8List)> entries) {
  final archive = Archive();
  for (final entry in entries) {
    archive.add(ArchiveFile.bytes(entry.$1, entry.$2));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Uint8List _readEntry(ArchiveFile file, String name) {
  try {
    return file.readBytes() ?? Uint8List(0);
  } on Object {
    throw Live2dKitException('archive', name);
  }
}

Uint8List? _tryRead(ArchiveFile file) {
  try {
    return file.readBytes() ?? Uint8List(0);
  } on Object {
    return null;
  }
}

ArchiveFile? _firstEntry(List<ArchiveFile> infos, String name) {
  for (final info in infos) {
    if (info.name == name) {
      return info;
    }
  }
  return null;
}

/// The textures the descriptor lists, for the missing-texture note.
List<String> _referenceTextures(Map<String, dynamic> doc, int cubism) {
  final Object? raw;
  if (cubism == 2) {
    raw = doc['textures'];
  } else {
    raw = _mapOf(doc['FileReferences'])['Textures'];
  }
  if (raw is! List) {
    return const <String>[];
  }
  final out = <String>[];
  for (final texture in raw) {
    if (texture is String && texture.isNotEmpty) {
      out.add(texture.replaceAll('\\', '/'));
    }
  }
  return out;
}

Map<String, dynamic> _mapOf(Object? value) => value is Map<String, dynamic> ? value : const <String, dynamic>{};

/// A name that can be joined under a folder without escaping it.
///
/// This is the installers' check plus the drive-letter case (`C:/x`), because
/// the inspect step is the one place a hostile zip gets in.
bool _isSafeRelativeName(String path) {
  if (path.isEmpty || path.startsWith('/') || path.contains('\\')) {
    return false;
  }
  final segments = path.split('/');
  for (final segment in segments) {
    if (segment.isEmpty || segment == '.' || segment == '..') {
      return false;
    }
  }
  return !RegExp(r'^[A-Za-z]:$').hasMatch(segments.first);
}

/// Shallowest of [names], then alphabetical: the descriptor rule the installers
/// use, so a zip with both `cat.model3.json` and `extra/twin.model3.json` picks
/// the one the room would pick.
String _shallowest(List<String> names) {
  final sorted = names.toList()
    ..sort((a, b) {
      final depth = '/'.allMatches(a).length - '/'.allMatches(b).length;
      return depth != 0 ? depth : a.compareTo(b);
    });
  return sorted.first;
}

String _basename(String path) {
  final slash = path.lastIndexOf('/');
  return slash < 0 ? path : path.substring(slash + 1);
}

String _dirname(String path) {
  final slash = path.lastIndexOf('/');
  return slash < 0 ? '' : path.substring(0, slash);
}

String _childPath(String home, String name) => home.isEmpty ? name : '$home/$name';

/// Lowercase extension with the dot, `''` when there is none.
String _suffix(String path) {
  final name = _basename(path);
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? '' : name.substring(dot).toLowerCase();
}

/// `Test Pet` -> `test-pet`; the pack id the app's URLs and folders use.
String _slug(String name) {
  final slug = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  return slug.isEmpty ? 'live2d-pet' : slug;
}

/// Sizes the way the report prints them: `820 B`, `1.5 KB`, `64.0 MB`.
String _size(int bytes) {
  if (bytes < 1024) {
    return '${bytes.toStringAsFixed(0)} B';
  }
  var value = bytes / 1024;
  if (value < 1024) {
    return '${value.toStringAsFixed(1)} KB';
  }
  value /= 1024;
  if (value < 1024) {
    return '${value.toStringAsFixed(1)} MB';
  }
  value /= 1024;
  return '${value.toStringAsFixed(1)} GB';
}

/// `a、b、c…`: the first few names, so a long list does not fill the page.
String _shortList(List<String> items) {
  if (items.length <= 6) {
    return items.join('、');
  }
  return '${items.take(6).join('、')}…';
}

double _number(Object? value) => value is num ? value.toDouble() : 0;

bool _truthy(Object? value) {
  if (value is bool) {
    return value;
  }
  if (value is num) {
    return value != 0;
  }
  if (value is String) {
    return value.isNotEmpty;
  }
  return false;
}
