// The runtime pet pack (`assets/pets/<id>/pack.json` plus one frame grid per
// animation), shared by the chat page's pet layer, the overlay (Kotlin) and
// the converter (`tool/make_pet_pack.py`). Format: `docs/design/pets.md` §3.
// Event and state names follow Clawd on Desk.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'pet_state.dart';

/// One frame of an animation: cell [i] of the sheet, shown for [ms].
@immutable
class PetFrame {
  const PetFrame(this.i, this.ms);

  final int i;
  final int ms;
}

/// One animation: a grid of cells ([cols] per row) cropped to [box], and
/// the order and time each cell shows.
@immutable
class PetAnimation {
  const PetAnimation({
    required this.name,
    required this.sheet,
    required this.frameWidth,
    required this.frameHeight,
    required this.cols,
    required this.box,
    required this.frames,
    this.loop = true,
  });

  final String name;

  /// File name next to pack.json.
  final String sheet;

  /// One cell, in sheet pixels (= [box] × the pack's scale).
  final int frameWidth;
  final int frameHeight;
  final int cols;

  /// Where a cell sits on the canvas, in art pixels.
  final Rect box;
  final List<PetFrame> frames;
  final bool loop;

  /// One pass, in milliseconds.
  int get durationMs => frames.fold(0, (sum, f) => sum + f.ms);

  /// Where cell [index] sits on the sheet.
  Rect sourceRect(int index) => Rect.fromLTWH(
    ((index % cols) * frameWidth).toDouble(),
    ((index ~/ cols) * frameHeight).toDouble(),
    frameWidth.toDouble(),
    frameHeight.toDouble(),
  );
}

/// A tier of a busy state: from [min] sessions on, play [anim].
@immutable
class PetTier {
  const PetTier(this.min, this.anim);

  final int min;
  final String anim;
}

/// Which way the roam animation looks.
enum PetFacing { left, right, front }

/// Marks a pack whose `poster.png` is still the blank the importer wrote:
/// the chat's stage draws the model and `PetLive2dView` replaces the file
/// with that first frame (docs/pets/README.md §3.5).
const posterPendingName = '.poster-pending';

/// Marks a pack written by the converter, whose `canvas` and `contentBox` are
/// guesses: nobody had seen the model when the zip was built. The first frame
/// the stage draws is at the model's own proportions, and its opaque box is
/// the body (live2d_pet_kit.dart), so the view rewrites both from that frame
/// and deletes this. A hand-written pack has no marker and is left alone.
const contentBoxAutoName = '.content-box-auto';

/// A pet whose art is a Cubism model instead of sprite sheets
/// (docs/pets/README.md §11). The sprites it still carries are one still
/// frame — the poster the floating window shows; the chat draws the model.
@immutable
class PetLive2d {
  const PetLive2d({required this.model, this.states = const {}, this.reactions = const {}, this.fallback});

  /// The model descriptor, relative to the pack's `character/` folder:
  /// `*.model3.json` for Cubism 3/5, or `model.json` + a `.moc` for Cubism 2.
  final String model;

  /// Pet state name → the model's motion group (docs/pets/README.md §5).
  final Map<String, String> states;

  /// Reaction key (`tapLeft`, `tapRight`, `tickle`, `annoyed`, `drag`) → a
  /// motion group, played once and then back to the state's own motion.
  final Map<String, String> reactions;

  /// Played when a state has no motion of its own (a plain idle fallback).
  final String? fallback;

  /// Null when [raw] isn't a map; throws when it is one but malformed.
  static PetLive2d? parse(Object? raw) {
    if (raw == null) return null;
    if (raw is! Map) throw const FormatException('pack.json: live2d');
    final model = raw['model'];
    if (model is! String || model.isEmpty || model.startsWith('/') || model.contains('\\')) {
      throw const FormatException('pack.json: live2d.model');
    }
    if (model.split('/').any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw const FormatException('pack.json: live2d.model');
    }
    final known = {for (final state in PetStateName.values) state.name};
    final states = <String, String>{};
    final statesRaw = raw['states'];
    if (statesRaw is Map) {
      for (final MapEntry(:key, :value) in statesRaw.entries) {
        if (!known.contains('$key')) throw FormatException('pack.json: live2d.states.$key');
        if (value is! String || value.isEmpty) throw FormatException('pack.json: live2d.states.$key');
        states['$key'] = value;
      }
    }
    final reactions = <String, String>{};
    final reactionsRaw = raw['reactions'];
    if (reactionsRaw is Map) {
      for (final MapEntry(:key, :value) in reactionsRaw.entries) {
        if (value is! String || value.isEmpty) throw FormatException('pack.json: live2d.reactions.$key');
        reactions['$key'] = value;
      }
    }
    final fallback = raw['fallback'];
    if (fallback != null && (fallback is! String || fallback.isEmpty)) {
      throw const FormatException('pack.json: live2d.fallback');
    }
    return PetLive2d(
      model: model,
      states: Map.unmodifiable(states),
      reactions: Map.unmodifiable(reactions),
      fallback: fallback as String?,
    );
  }
}

/// A pet: its art and how app states map onto it.
@immutable
class PetPack {
  const PetPack({
    required this.id,
    required this.name,
    required this.canvas,
    required this.anchorX,
    required this.baseline,
    required this.contentBox,
    required this.animations,
    required this.states,
    this.author,
    this.license,
    this.source,
    this.pixelArt = true,
    this.scale = 1,
    this.tiers = const {},
    this.minDisplay = const {},
    this.autoReturn = const {},
    this.playMs = const {},
    this.reactions = const {},
    this.roamAnim,
    this.roamFacing = PetFacing.front,
    this.sleepAfter = const Duration(seconds: 60),
    this.wakeMs,
    this.hitBoxes = const {},
    this.hitBoxByAnim = const {},
    this.idlePool = const [],
    this.idleEvery = const PetEvery(),
    this.bonus = const {},
    this.live2d,
    this.dir,
  });

  /// Folder name under `assets/pets/`, or under the brought pets' folder
  /// (pet_library.dart).
  final String id;

  /// Where a brought pet's sheets are on disk; null for the built-in ones,
  /// which come from the app's assets.
  final String? dir;
  final String name;
  final String? author;
  final String? license;
  final String? source;

  /// Nearest-neighbour, whole-pixel scaling ([FilterQuality.none]).
  final bool pixelArt;

  /// Sheet pixels per art pixel (Deepy keeps its 5× export).
  final int scale;

  /// The art's canvas, in art pixels.
  final Size canvas;

  /// The foot point in art pixels: the body's centre (also the mirror axis)
  /// and the line the pet stands on.
  final double anchorX;
  final double baseline;

  /// The idle body in art pixels: the hit box and where bubbles sit.
  final Rect contentBox;
  final Map<String, PetAnimation> animations;

  /// State name → its animations ([0] is the main one, the rest variants).
  final Map<String, List<String>> states;

  /// State name → tiers, highest [PetTier.min] first.
  final Map<String, List<PetTier>> tiers;

  /// State name → shortest showing time, ms.
  final Map<String, int> minDisplay;

  /// State name → folds back after this long, ms.
  final Map<String, int> autoReturn;

  /// Animation name → how long a one-off play lasts, ms.
  final Map<String, int> playMs;

  /// Reaction name (tapLeft / tapRight / tickle / drag / annoyed / …) → its
  /// animations: one plays as written, several are picked one per play.
  final Map<String, List<String>> reactions;

  final String? roamAnim;

  /// Which way the art looks: walking the other way mirrors it; front-facing
  /// art never mirrors.
  final PetFacing roamFacing;
  final Duration sleepAfter;

  /// How long waking lasts; one pass of its animation when absent.
  final int? wakeMs;

  /// `default` / `wide` / `sleeping` hit boxes, art pixels.
  final Map<String, Rect> hitBoxes;

  /// Animation name → its hit box (from `byAnim`, `wideAnims`, `sleepingAnims`).
  final Map<String, Rect> hitBoxByAnim;

  /// Idle's rotation: each with its play time and weight.
  final List<PetIdle> idlePool;

  /// How often an idle extra plays.
  final PetEvery idleEvery;

  /// State name → an occasional alternative (attention's extras).
  final Map<String, PetBonus> bonus;

  /// Set for a Live2D pet: the chat draws the model, the sprites are its
  /// still poster frame.
  final PetLive2d? live2d;

  static const schema = 1;

  /// Asset path of the pack's folder.
  static String folder(String id) => 'assets/pets/$id';

  /// The animation for [state] at [tier]: its tier, else its first, else idle's.
  PetAnimation animFor(PetStateName state, {int tier = 0}) {
    if (tier > 0) {
      for (final t in tiers[state.name] ?? const <PetTier>[]) {
        if (tier >= t.min) return animations[t.anim]!;
      }
    }
    if (states[state.name]?.firstOrNull case final name?) return animations[name]!;
    return animations[states['idle']?.firstOrNull] ?? animations.values.first;
  }

  /// Idle's extras: [idlePool], else idle's other animations (two passes,
  /// equally likely).
  List<PetIdle> get idles {
    if (idlePool.isNotEmpty) return idlePool;
    return [
      for (final name in (states['idle'] ?? const <String>[]).skip(1))
        PetIdle(name, ms: playMs[name] ?? animations[name]!.durationMs * 2),
    ];
  }

  /// [state]'s occasional alternative: its `bonus`, else its other
  /// animations at one in three.
  PetBonus? bonusOf(PetStateName state) {
    if (bonus[state.name] case final b?) return b;
    if (state == PetStateName.idle) return null;
    final names = (states[state.name] ?? const <String>[]).skip(1).toList();
    return names.isEmpty ? null : PetBonus(names, chance: 1 / 3);
  }

  /// A state's other animations (idle's are played now and then).
  List<PetAnimation> variants(PetStateName state) => [
    for (final name in (states[state.name] ?? const <String>[]).skip(1)) animations[name]!,
  ];

  /// [key]'s fixed animation: the first variant (drag, a lone tap reaction).
  PetAnimation? reaction(String key) => animations[reactions[key]?.firstOrNull];

  /// [key]'s animation for this play: one of its variants, picked with [random].
  PetAnimation? reactionOutOf(String key, math.Random random) {
    final names = reactions[key];
    if (names == null || names.isEmpty) return null;
    return animations[names.length == 1 ? names.first : names[random.nextInt(names.length)]];
  }

  PetAnimation get roam => animations[roamAnim] ?? animFor(PetStateName.idle);

  /// How long a one-off play of [anim] lasts: its playMs, else one pass.
  int playOf(PetAnimation anim) => playMs[anim.name] ?? anim.durationMs;

  /// What a touch hits while [anim] plays, art pixels.
  Rect hitBoxFor(PetAnimation anim) => hitBoxByAnim[anim.name] ?? hitBoxes['default'] ?? contentBox;

  /// Mirror [roam] when walking right ([right]) or left.
  bool mirrorWalking({required bool right}) => switch (roamFacing) {
    PetFacing.left => right,
    PetFacing.right => !right,
    PetFacing.front => false,
  };

  /// Waking's length: wakeMs, else one pass of its animation (1.5 s without one).
  int get wakeDuration {
    if (wakeMs case final ms?) return ms;
    final anim = animations[states['waking']?.firstOrNull];
    final length = anim?.durationMs ?? 0;
    return length > 0 ? length : 1500;
  }

  /// Parses pack.json. A pack that fails its checks throws [FormatException]
  /// (a broken pack is not loaded at all).
  factory PetPack.parse(Map<String, Object?> json, {String? dir}) {
    if (json['schema'] != schema) throw const FormatException('pack.json: schema');
    final id = _string(json['id']);
    if (id == null || id.isEmpty) throw const FormatException('pack.json: id');
    final canvasJson = _map(json['canvas']);
    final w = _num(canvasJson['w']);
    final h = _num(canvasJson['h']);
    if (w == null || h == null || w <= 0 || h <= 0) throw const FormatException('pack.json: canvas');
    final scale = _num(json['scale'])?.round() ?? 1;
    if (scale <= 0) throw const FormatException('pack.json: scale');
    final anchor = _map(json['anchor']);
    final contentBox = _rect(json['contentBox']);
    if (contentBox == null) throw const FormatException('pack.json: contentBox');

    final animations = <String, PetAnimation>{};
    for (final MapEntry(:key, :value) in _map(json['animations']).entries) {
      final a = _map(value);
      final sheet = _string(a['sheet']);
      final fw = _num(a['frameW'])?.round();
      final fh = _num(a['frameH'])?.round();
      final cols = _num(a['cols'])?.round();
      final box = _rect(a['box']);
      final frames = [
        for (final f in _list(a['frames']))
          if (_map(f) case final m when _num(m['i']) != null && _num(m['ms']) != null)
            PetFrame(_num(m['i'])!.round(), _num(m['ms'])!.round()),
      ];
      if (sheet == null || fw == null || fh == null || cols == null || box == null) {
        throw FormatException('pack.json: animation $key');
      }
      if (fw <= 0 || fh <= 0 || cols <= 0 || frames.isEmpty || frames.any((f) => f.i < 0 || f.ms <= 0)) {
        throw FormatException('pack.json: frames of $key');
      }
      animations[key] = PetAnimation(
        name: key,
        sheet: sheet,
        frameWidth: fw,
        frameHeight: fh,
        cols: cols,
        box: box,
        frames: frames,
        loop: a['loop'] != false,
      );
    }
    if (animations.isEmpty) throw const FormatException('pack.json: animations');

    String known(Object? name, String where) {
      if (name is String && animations.containsKey(name)) return name;
      throw FormatException('pack.json: $where → $name');
    }

    /// Reaction name → its animations. `tickle2`, `tickle3`… (a number after
    /// a plain name this map already has) are further alternatives: older apps
    /// read only the plain name and ignore the rest, so a shared pack still
    /// works there while this one picks among all of them.
    Map<String, List<String>> reactionMap(Object? raw) {
      final map = <String, List<String>>{};
      for (final MapEntry(:key, :value) in _map(raw).entries) {
        final names = [
          for (final name in value is List ? value : [value]) known(name, 'reactions.$key'),
        ];
        if (names.isNotEmpty) map[key] = names;
      }
      for (final key in map.keys.toList()) {
        final match = RegExp(r'^(.*?)(\d+)$').firstMatch(key);
        final base = match?.group(1);
        // From 2 on: `tickle` is the first, `tickle2` the second.
        if (base == null || !map.containsKey(base) || int.parse(match!.group(2)!) < 2) continue;
        final extra = map.remove(key)!;
        map.update(base, (names) => [...names, ...extra]);
      }
      return map;
    }

    final states = <String, List<String>>{
      for (final MapEntry(:key, :value) in _map(json['states']).entries)
        key: [for (final name in _list(value)) known(name, 'states.$key')],
    }..removeWhere((_, v) => v.isEmpty);
    if (!states.containsKey('idle')) throw const FormatException('pack.json: states.idle');

    final tiers = <String, List<PetTier>>{
      for (final MapEntry(:key, :value) in _map(json['tiers']).entries)
        key: [
          for (final t in _list(value))
            PetTier((_num(_map(t)['min']) ?? 1).round(), known(_map(t)['anim'], 'tiers.$key')),
        ]..sort((a, b) => b.min.compareTo(a.min)),
    }..removeWhere((_, v) => v.isEmpty);

    final timings = _map(json['timings']);
    Map<String, int> ms(Object? raw) => {
      for (final MapEntry(:key, :value) in _map(raw).entries)
        if (_num(value) case final v? when v > 0) key: v.round(),
    };
    final roam = _map(json['roam']);
    final sleep = _map(json['sleep']);
    final hits = _map(json['hitBoxes']);
    final hitBoxes = <String, Rect>{
      for (final k in const ['default', 'wide', 'sleeping']) k: ?_rect(hits[k]),
    };
    final hitBoxByAnim = <String, Rect>{
      for (final name in _list(hits['wideAnims']).whereType<String>()) name: ?hitBoxes['wide'],
      for (final name in _list(hits['sleepingAnims']).whereType<String>()) name: ?hitBoxes['sleeping'],
      for (final MapEntry(:key, :value) in _map(hits['byAnim']).entries) key: ?_rect(value),
    };
    final pool = json['idlePool'];
    final poolMap = _map(pool);
    final idlePool = [
      for (final item in pool is List ? pool : _list(poolMap['anims']))
        if (_map(item) case final m)
          PetIdle(
            known(m['anim'], 'idlePool'),
            ms: (_num(m['ms']) ?? 0).round(),
            weight: (_num(m['weight']) ?? 1).clamp(0, 1000).toDouble(),
          ),
    ];
    final every = _map(poolMap['everyMs']);
    final bonus = <String, PetBonus>{
      for (final MapEntry(:key, :value) in _map(json['bonus']).entries)
        key: PetBonus([
          for (final name in _list(_map(value)['anims'])) known(name, 'bonus.$key'),
        ], chance: (_num(_map(value)['chance']) ?? 0).clamp(0, 1).toDouble()),
    }..removeWhere((_, b) => b.anims.isEmpty || b.chance <= 0);
    final faces = _string(roam['faces']) ?? _string(roam['facing']);
    final live2d = PetLive2d.parse(json['live2d']);

    return PetPack(
      id: id,
      name: _string(json['name']) ?? id,
      author: _string(json['author']),
      license: _string(json['license']),
      source: _string(json['source']),
      pixelArt: json['pixelArt'] != false,
      scale: scale,
      canvas: Size(w, h),
      anchorX: _num(anchor['x']) ?? w / 2,
      baseline: _num(anchor['baseline']) ?? h,
      contentBox: contentBox,
      animations: animations,
      states: states,
      tiers: tiers,
      minDisplay: ms(timings['minDisplay']),
      autoReturn: ms(timings['autoReturn']),
      playMs: ms(timings['playMs']),
      reactions: reactionMap(json['reactions']),
      roamAnim: roam['anim'] == null ? null : known(roam['anim'], 'roam'),
      // An explicit `flip: false` keeps front-facing art unmirrored.
      roamFacing: roam['flip'] == false ? PetFacing.front : PetFacing.values.asNameMap()[faces] ?? PetFacing.front,
      sleepAfter: Duration(milliseconds: (_num(sleep['afterMs']) ?? 60000).round()),
      wakeMs: _num(timings['wakeMs'])?.round(),
      hitBoxes: hitBoxes,
      hitBoxByAnim: hitBoxByAnim,
      idlePool: idlePool,
      idleEvery: PetEvery(
        mean: (_num(every['mean']) ?? 120000).round(),
        min: (_num(every['min']) ?? 45000).round(),
        max: (_num(every['max']) ?? 300000).round(),
      ),
      bonus: bonus,
      live2d: live2d,
      dir: dir,
    );
  }

  /// Reads `assets/pets/<id>/pack.json` from [bundle].
  static Future<PetPack> load(String id, [AssetBundle? bundle]) async {
    final raw = await (bundle ?? rootBundle).loadString('${folder(id)}/pack.json');
    final json = jsonDecode(raw);
    if (json is! Map<String, Object?>) throw const FormatException('pack.json');
    return PetPack.parse(json);
  }

  static String? _string(Object? v) => v is String ? v : null;
  static double? _num(Object? v) {
    if (v is! num) return null;
    final number = v.toDouble();
    if (!number.isFinite) throw const FormatException('pack.json: non-finite number');
    return number;
  }

  static Map<String, Object?> _map(Object? v) =>
      v is Map ? {for (final MapEntry(:key, :value) in v.entries) '$key': value} : const {};
  static List<Object?> _list(Object? v) => v is List ? v : const [];
  static Rect? _rect(Object? v) {
    final m = _map(v);
    final x = _num(m['x']), y = _num(m['y']), w = _num(m['w']), h = _num(m['h']);
    if (x == null || y == null || w == null || h == null || w <= 0 || h <= 0) return null;
    return Rect.fromLTWH(x, y, w, h);
  }
}

/// One entry of idle's rotation.
@immutable
class PetIdle {
  const PetIdle(this.anim, {required this.ms, this.weight = 1});

  final String anim;

  /// How long it plays when picked, ms (0: one pass).
  final int ms;
  final double weight;
}

/// An occasional alternative for a state (`bonus`): [anims] at [chance].
@immutable
class PetBonus {
  const PetBonus(this.anims, {required this.chance});

  final List<String> anims;
  final double chance;
}

/// A random interval: [min] plus an exponential wait averaging [mean] − [min],
/// capped at [max] (ms).
@immutable
class PetEvery {
  const PetEvery({this.mean = 120000, this.min = 45000, this.max = 300000});

  final int mean;
  final int min;
  final int max;

  /// One draw, from a uniform [u] in [0, 1).
  Duration draw(double u) {
    final extra = -(mean - min) * math.log(1 - u.clamp(0.0, 0.999999));
    return Duration(milliseconds: math.min(max, min + extra.round()));
  }
}
