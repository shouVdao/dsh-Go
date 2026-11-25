// 互动启动画面（Android）：内置的“两次确认”演出，浅色、深色两套外观。用户能改的只有
// 声明式的配置：外观、强调色、文字、各幕背景（图片或视频，存在 `<support>/launch/`，和
// 自定义启动画面同一套导入）、等待方式、速度、转场和频率。存在 shared_preferences 的
// `launch_interactive`（一条带版本号的 JSON）；“每天首次”的日期另存在
// `launch_interactive_day`，只在真正的冷启动里写（预览不写）。
//
// 选它不会删掉已存的自定义图片或视频：两者各自保留，只是 `on` 一个开一个关。

import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:shared_preferences/shared_preferences.dart';

import 'custom_launch.dart';

/// Light or dark: the two built-in looks.
enum InteractiveLook {
  /// The system's mode at launch.
  auto,
  light,
  dark;

  bool darkFor({required bool systemDark}) => switch (this) {
    auto => systemDark,
    light => false,
    dark => true,
  };
}

/// What a waiting scene's clip does once it has played through.
enum InteractiveWait {
  /// Starts again.
  loop,

  /// Stays on its last frame.
  hold,
}

/// How the show hands over to the app.
enum InteractiveTransition {
  /// The welcome line, then a plain fade.
  fade,

  /// Plus a light that blooms from the centre and a white streak.
  bloom,

  /// Plus a slight red / blue split on the welcome text.
  chroma,
}

/// How often it plays.
enum InteractiveFrequency {
  /// Every cold start of the app.
  always,

  /// The first cold start of each day; the default launch screen on the others.
  daily,
}

/// The scenes a background can be set for.
enum InteractiveScene {
  /// 第一幕：开始。
  start,

  /// 第二幕：确认资料。
  confirm,

  /// 扫描演出 and the welcome after it.
  scan,
}

T _byName<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

/// The words on the screen. Null fields read the language's default.
class InteractiveTexts {
  const InteractiveTexts({
    this.title,
    this.subtitle,
    this.nickname,
    this.number,
    this.start,
    this.confirm,
    this.welcome,
  });

  final String? title;
  final String? subtitle;
  final String? nickname;

  /// A decorative number on the profile card (nothing is checked against it).
  final String? number;

  /// The first button.
  final String? start;

  /// The second button.
  final String? confirm;

  /// The line under WELCOME TO.
  final String? welcome;

  /// Characters each field keeps (a longer paste is cut).
  static const limits = {
    'title': 20,
    'subtitle': 32,
    'nickname': 24,
    'number': 12,
    'start': 12,
    'confirm': 12,
    'welcome': 24,
  };

  /// One line, trimmed, at most [max] characters; empty reads null (the default).
  static String? clean(Object? raw, int max) {
    if (raw is! String) return null;
    final line = raw.replaceAll(RegExp(r'[\u0000-\u001F\u007F\u2028\u2029]'), ' ').trim();
    if (line.isEmpty) return null;
    final runes = line.runes.toList();
    return runes.length <= max ? line : String.fromCharCodes(runes.take(max)).trimRight();
  }

  String? operator [](String field) => switch (field) {
    'title' => title,
    'subtitle' => subtitle,
    'nickname' => nickname,
    'number' => number,
    'start' => start,
    'confirm' => confirm,
    'welcome' => welcome,
    _ => throw ArgumentError.value(field, 'field'),
  };

  /// [field] set to [value] (cleaned; empty: back to the default).
  InteractiveTexts withField(String field, String? value) {
    final v = clean(value, limits[field]!);
    String? pick(String name) => name == field ? v : this[name];
    return InteractiveTexts(
      title: pick('title'),
      subtitle: pick('subtitle'),
      nickname: pick('nickname'),
      number: pick('number'),
      start: pick('start'),
      confirm: pick('confirm'),
      welcome: pick('welcome'),
    );
  }

  Map<String, Object?> toJson() => {for (final f in limits.keys) f: ?this[f]};

  static InteractiveTexts fromJson(Object? raw) {
    if (raw is! Map) return const InteractiveTexts();
    String? read(String f) => clean(raw[f], limits[f]!);
    return InteractiveTexts(
      title: read('title'),
      subtitle: read('subtitle'),
      nickname: read('nickname'),
      number: read('number'),
      start: read('start'),
      confirm: read('confirm'),
      welcome: read('welcome'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is InteractiveTexts && limits.keys.every((f) => other[f] == this[f]);

  @override
  int get hashCode => Object.hashAll([for (final f in limits.keys) this[f]]);
}

/// The interactive launch screen's settings.
class InteractiveLaunch {
  const InteractiveLaunch({
    this.on = false,
    this.look = InteractiveLook.auto,
    this.accent = defaultAccent,
    this.texts = const InteractiveTexts(),
    this.backgrounds = const {},
    this.wait = InteractiveWait.loop,
    this.videoSpeed = 1,
    this.effectSpeed = 1,
    this.transition = InteractiveTransition.chroma,
    this.frequency = InteractiveFrequency.always,
  });

  /// The format's version; a newer one than this app reads is ignored.
  static const version = 1;

  static const prefsKey = 'launch_interactive';
  static const dayKey = 'launch_interactive_day';

  static const defaultAccent = 0xFFFF7500;

  /// The accents offered.
  static const accents = [0xFFFF7500, 0xFF2F80ED, 0xFF1FA971, 0xFFE5484D, 0xFF8E5CF7];

  static const minSpeed = 0.5;
  static const maxSpeed = 2.0;

  final bool on;
  final InteractiveLook look;

  /// ARGB.
  final int accent;
  final InteractiveTexts texts;

  /// A picture or clip per scene (an image or a video, never an animation); a scene without one
  /// shows the built-in plate.
  final Map<InteractiveScene, CustomLaunch> backgrounds;
  final InteractiveWait wait;

  /// The clips' playback speed.
  final double videoSpeed;

  /// The reticle, scanline and data stream's speed (the steps keep their own pace).
  final double effectSpeed;
  final InteractiveTransition transition;
  final InteractiveFrequency frequency;

  Color get accentColor => Color(accent);

  static double _speed(Object? v) =>
      v is num && v.isFinite ? v.toDouble().clamp(minSpeed, maxSpeed) : 1;

  InteractiveLaunch copyWith({
    bool? on,
    InteractiveLook? look,
    int? accent,
    InteractiveTexts? texts,
    Map<InteractiveScene, CustomLaunch>? backgrounds,
    InteractiveWait? wait,
    double? videoSpeed,
    double? effectSpeed,
    InteractiveTransition? transition,
    InteractiveFrequency? frequency,
  }) => InteractiveLaunch(
    on: on ?? this.on,
    look: look ?? this.look,
    accent: accent ?? this.accent,
    texts: texts ?? this.texts,
    backgrounds: backgrounds ?? this.backgrounds,
    wait: wait ?? this.wait,
    videoSpeed: _speed(videoSpeed ?? this.videoSpeed),
    effectSpeed: _speed(effectSpeed ?? this.effectSpeed),
    transition: transition ?? this.transition,
    frequency: frequency ?? this.frequency,
  );

  /// [scene]'s background replaced ([media] null: back to the plate).
  InteractiveLaunch withBackground(InteractiveScene scene, CustomLaunch? media) {
    final next = Map.of(backgrounds);
    if (media == null) {
      next.remove(scene);
    } else {
      next[scene] = media;
    }
    return copyWith(backgrounds: next);
  }

  Map<String, Object?> toJson() => {
    'version': version,
    'on': on,
    'look': look.name,
    'accent': accent,
    'texts': texts.toJson(),
    'backgrounds': {for (final e in backgrounds.entries) e.key.name: e.value.toJson()},
    'wait': wait.name,
    'videoSpeed': videoSpeed,
    'effectSpeed': effectSpeed,
    'transition': transition.name,
    'frequency': frequency.name,
  };

  /// Null when [raw] isn't this format, or is a newer version of it.
  static InteractiveLaunch? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final v = raw['version'];
    if (v is! int || v < 1 || v > version) return null;
    final accent = raw['accent'];
    final scenes = raw['backgrounds'];
    final backgrounds = <InteractiveScene, CustomLaunch>{};
    if (scenes is Map) {
      for (final scene in InteractiveScene.values) {
        final media = CustomLaunch.fromJson(scenes[scene.name]);
        if (media != null && media.kind != LaunchMediaKind.animation) backgrounds[scene] = media;
      }
    }
    return InteractiveLaunch(
      on: raw['on'] == true,
      look: _byName(InteractiveLook.values, raw['look'], InteractiveLook.auto),
      accent: accent is int ? accent | 0xFF000000 : defaultAccent,
      texts: InteractiveTexts.fromJson(raw['texts']),
      backgrounds: backgrounds,
      wait: _byName(InteractiveWait.values, raw['wait'], InteractiveWait.loop),
      videoSpeed: _speed(raw['videoSpeed']),
      effectSpeed: _speed(raw['effectSpeed']),
      transition: _byName(InteractiveTransition.values, raw['transition'], InteractiveTransition.chroma),
      frequency: _byName(InteractiveFrequency.values, raw['frequency'], InteractiveFrequency.always),
    );
  }

  /// The stored settings, or null (none, unreadable). A background whose file is gone is dropped:
  /// that scene shows the plate.
  static Future<InteractiveLaunch?> load([SharedPreferences? prefs]) async {
    try {
      final store = prefs ?? await SharedPreferences.getInstance();
      final raw = store.getString(prefsKey);
      if (raw == null) return null;
      final config = fromJson(jsonDecode(raw));
      if (config == null) return null;
      final kept = {
        for (final e in config.backgrounds.entries)
          if (File(e.value.path).existsSync() && (e.value.poster == null || File(e.value.poster!).existsSync()))
            e.key: e.value,
      };
      return kept.length == config.backgrounds.length ? config : config.copyWith(backgrounds: kept);
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(InteractiveLaunch config, [SharedPreferences? prefs]) async {
    final store = prefs ?? await SharedPreferences.getInstance();
    await store.setString(prefsKey, jsonEncode(config.toJson()));
  }

  static String _day(DateTime now) =>
      '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

  /// Whether this cold start plays it, and if so records the day ([InteractiveFrequency.daily]).
  /// Only a real cold start calls this; the preview never does.
  Future<bool> takeTurn(SharedPreferences prefs, DateTime now) async {
    if (!on) return false;
    if (frequency == InteractiveFrequency.always) return true;
    final today = _day(now);
    if (prefs.getString(dayKey) == today) return false;
    try {
      await prefs.setString(dayKey, today);
    } catch (_) {
      // Unwritten: it plays again on the next cold start today, which is the lesser fault.
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is InteractiveLaunch &&
      other.on == on &&
      other.look == look &&
      other.accent == accent &&
      other.texts == texts &&
      _sameBackgrounds(other.backgrounds) &&
      other.wait == wait &&
      other.videoSpeed == videoSpeed &&
      other.effectSpeed == effectSpeed &&
      other.transition == transition &&
      other.frequency == frequency;

  bool _sameBackgrounds(Map<InteractiveScene, CustomLaunch> other) =>
      other.length == backgrounds.length && backgrounds.entries.every((e) => other[e.key] == e.value);

  @override
  int get hashCode => Object.hash(
    on,
    look,
    accent,
    texts,
    Object.hashAll([for (final s in InteractiveScene.values) backgrounds[s]]),
    wait,
    videoSpeed,
    effectSpeed,
    transition,
    frequency,
  );
}
