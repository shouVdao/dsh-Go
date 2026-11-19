// The declarative scene format behind the .json wallpaper: a background, a
// stack of layers, keyframe tracks that animate their properties, and up to
// three time-of-day variants the runtime picks from the system clock.
//
// Wallpaper authors get the format documented in docs/json-wallpaper.md; this
// file is only the model plus its validation. Painting lives in
// scene_engine.dart.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// The newest format this build understands. A higher `schemaVersion` is
/// refused instead of being half-read.
const int sceneSchemaVersion = 1;

/// Hard caps: a wallpaper is drawn every frame, so a file that asks for
/// thousands of layers or particles is a mistake, not an effect.
const int sceneMaxLayers = 200;
const int sceneMaxParticles = 2000;
const int sceneMaxTimelineTracks = 400;

/// Thrown for anything a wallpaper file gets wrong. The message is shown to
/// the user (and to the author fixing the file), so it names the field.
class SceneFormatException implements Exception {
  const SceneFormatException(this.message);

  final String message;

  @override
  String toString() => 'SceneFormatException: $message';
}

/// Which of the three time-of-day scenes is on screen.
///
/// 白天 07:00–16:00, 黄昏 05:00–07:00 与 16:00–19:00, 晚上 19:00–05:00.
/// 黄昏 covers both ends of the day on purpose: 05:00–07:00 is the sunrise
/// window and shares the dusk scene. A file that leaves `periods` out looks the
/// same all day.
enum ScenePeriod {
  day,
  dusk,
  night;

  static ScenePeriod of(DateTime time) {
    final hour = time.hour + time.minute / 60 + time.second / 3600;
    if (hour >= 19 || hour < 5) return ScenePeriod.night;
    if (hour >= 16) return ScenePeriod.dusk;
    if (hour < 7) return ScenePeriod.dusk;
    return ScenePeriod.day;
  }
}

/// A layer property a timeline track may drive.
enum SceneProperty {
  opacity,
  scale,
  x,
  y,
  rotation,
  visible,
  speed,
  count;

  static SceneProperty? tryParse(String name) {
    for (final property in SceneProperty.values) {
      if (property.name == name) return property;
    }
    return null;
  }
}

enum SceneTrackMode {
  clamp,
  loop,
  pingpong;

  static SceneTrackMode parse(Object? value) {
    switch (value) {
      case null:
        return SceneTrackMode.loop;
      case 'clamp':
        return SceneTrackMode.clamp;
      case 'loop':
        return SceneTrackMode.loop;
      case 'pingpong':
        return SceneTrackMode.pingpong;
      default:
        throw SceneFormatException('timeline mode 只能是 clamp / loop / pingpong，收到 $value');
    }
  }
}

/// How an image layer fills its area.
enum SceneFit {
  cover,
  contain,
  fill;

  static SceneFit parse(Object? value) {
    switch (value) {
      case null:
        return SceneFit.cover;
      case 'cover':
        return SceneFit.cover;
      case 'contain':
        return SceneFit.contain;
      case 'fill':
        return SceneFit.fill;
      default:
        throw SceneFormatException('fit 只能是 cover / contain / fill，收到 $value');
    }
  }
}

/// A video played behind the painted layers, one per 时段.
///
/// The file lives in the wallpaper package next to the manifest (`assets/night.mp4`),
/// so the same `.jsonwall` carries its own footage; a scene may instead point at
/// an app asset with `asset:` like the bundled sample does.
final class SceneVideo {
  const SceneVideo({required this.src, this.fit = SceneFit.cover, this.loop = true, this.opacity = 1});

  final String src;
  final SceneFit fit;
  final bool loop;
  final double opacity;

  static SceneVideo parse(Object? value, {String field = 'video'}) {
    if (value is String) {
      return SceneVideo(src: sceneSource(value, field, video: true));
    }
    if (value is! Map) throw SceneFormatException('$field 必须是文件路径或对象');
    final src = sceneSource(value['src'], '$field.src', video: true);
    return SceneVideo(
      src: src,
      fit: SceneFit.parse(value['fit']),
      loop: value['loop'] is bool ? value['loop'] as bool : true,
      opacity: _double(value['opacity'], '$field.opacity', 1).clampDouble(0, 1),
    );
  }
}

const List<String> _imageExtensions = ['png', 'jpg', 'jpeg', 'webp'];
const List<String> _videoExtensions = ['mp4', 'webm', 'mov', 'm4v'];

/// Checks a source a wallpaper file may point at.
///
/// Three forms are accepted: an app asset (`asset:assets/wallpapers/x.json`),
/// an inline picture (`data:image/png;base64,…`) and a path relative to the
/// package (`assets/sky.png`). Anything else — absolute paths, `..`, other
/// schemes — is refused: a wallpaper is data from somewhere else, not a way to
/// read the device. Relative paths also have to end in a format we can paint or
/// play, so a broken package fails while it is imported instead of at runtime.
String sceneSource(Object? value, String field, {bool video = false}) {
  if (value is! String || value.isEmpty) throw SceneFormatException('$field 缺失');
  if (value.startsWith('data:')) {
    if (video) throw SceneFormatException('$field 不能内嵌视频，请把视频放进压缩包');
    return value;
  }
  if (value.startsWith('asset:')) {
    _checkExtension(value, field, video: video);
    return value;
  }
  if (value.contains(':')) {
    throw SceneFormatException('$field 只支持 asset: 或压缩包内的相对路径，收到 $value');
  }
  final path = value.replaceAll('\\', '/');
  if (path.startsWith('/')) throw SceneFormatException('$field 不能是绝对路径：$value');
  for (final part in path.split('/')) {
    if (part.isEmpty || part == '.' || part == '..') {
      throw SceneFormatException('$field 不能用 .. 或空目录：$value');
    }
  }
  _checkExtension(path, field, video: video);
  return path;
}

void _checkExtension(String path, String field, {required bool video}) {
  final dot = path.lastIndexOf('.');
  final extension = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
  final allowed = video ? _videoExtensions : _imageExtensions;
  if (!allowed.contains(extension)) {
    throw SceneFormatException('$field 只支持 ${allowed.map((e) => '.$e').join(' / ')}，收到 $path');
  }
}

/// The easing of one keyframe segment. `null` means linear.
Curve sceneCurve(Object? value) {
  switch (value) {
    case null:
    case 'linear':
      return Curves.linear;
    case 'easeIn':
      return Curves.easeIn;
    case 'easeOut':
      return Curves.easeOut;
    case 'easeInOut':
      return Curves.easeInOut;
    case 'easeInCubic':
      return Curves.easeInCubic;
    case 'easeOutCubic':
      return Curves.easeOutCubic;
    case 'easeInOutCubic':
      return Curves.easeInOutCubic;
    case 'easeOutBack':
      return Curves.easeOutBack;
    case List<Object?> points when points.length == 4:
      return Cubic(
        _double(points[0], 'cubicBezier[0]', 0),
        _double(points[1], 'cubicBezier[1]', 0),
        _double(points[2], 'cubicBezier[2]', 0),
        _double(points[3], 'cubicBezier[3]', 0),
      );
    default:
      throw SceneFormatException('ease 无法识别：$value');
  }
}

/// A gradient shared by the background and gradient layers.
class SceneGradient {
  SceneGradient({
    required this.colors,
    required this.stops,
    this.angle = 90,
    this.radial = false,
    this.center = const Offset(0.5, 0.5),
  }) : assert(colors.length >= 2 && stops.length == colors.length);

  final List<Color> colors;

  /// 0…1, ascending.
  final List<double> stops;

  /// Degrees: 0 = left→right, 90 = top→bottom, 180 = right→left.
  final double angle;
  final bool radial;

  /// Radial centre, relative to the painted box.
  final Offset center;

  Gradient gradient() {
    if (radial) {
      return RadialGradient(colors: colors, stops: stops, center: Alignment(center.dx * 2 - 1, center.dy * 2 - 1));
    }
    final radians = angle * math.pi / 180;
    final dx = math.cos(radians);
    final dy = math.sin(radians);
    return LinearGradient(colors: colors, stops: stops, begin: Alignment(-dx, -dy), end: Alignment(dx, dy));
  }

  /// `"#RRGGBB"`, `"#AARRGGBB"`, or `{"from", "to", "colors", "stops", "angle", "type"}`.
  static SceneGradient parse(Object? value, {String field = 'background'}) {
    if (value is String) {
      final color = sceneColor(value, field);
      return SceneGradient(colors: [color, color], stops: const [0, 1]);
    }
    if (value is! Map) throw SceneFormatException('$field 必须是颜色字符串或渐变对象');
    final colors = <Color>[];
    final rawColors = value['colors'];
    if (rawColors is List && rawColors.length >= 2) {
      for (var i = 0; i < rawColors.length; i++) {
        colors.add(sceneColor(rawColors[i], '$field.colors[$i]'));
      }
    } else {
      final from = sceneColor(value['from'] ?? value['color'], '$field.from');
      final to = value['to'] == null ? from : sceneColor(value['to'], '$field.to');
      colors
        ..add(from)
        ..add(to);
    }
    final rawStops = value['stops'];
    final stops = <double>[];
    if (rawStops is List && rawStops.length == colors.length) {
      for (var i = 0; i < rawStops.length; i++) {
        stops.add(_double(rawStops[i], '$field.stops[$i]', 0).clampDouble(0, 1));
      }
    } else {
      for (var i = 0; i < colors.length; i++) {
        stops.add(i / (colors.length - 1));
      }
    }
    final type = value['type'];
    if (type != null && type != 'radial' && type != 'linear') {
      throw SceneFormatException('$field.type 只能是 linear / radial，收到 $type');
    }
    return SceneGradient(
      colors: colors,
      stops: stops,
      angle: _double(value['angle'], '$field.angle', 90),
      radial: type == 'radial',
      center: _point(value['center'], '$field.center', const Offset(0.5, 0.5)),
    );
  }
}

/// One keyframe: the value it reaches at [time], and the easing of the segment
/// that arrives at it (the first key's easing is unused).
class SceneKey {
  const SceneKey(this.time, this.value, this.curve);

  final double time;
  final double value;
  final Curve curve;
}

/// One animated property of one layer.
class SceneTrack {
  SceneTrack({required this.layer, required this.property, required this.mode, required this.keys})
    : assert(keys.isNotEmpty);

  final String layer;
  final SceneProperty property;
  final SceneTrackMode mode;
  final List<SceneKey> keys;

  int _cursor = 0;

  double sample(double time) {
    final first = keys.first;
    if (keys.length == 1) return first.value;
    final start = first.time;
    final end = keys.last.time;
    final span = end - start;
    if (span <= 0) return keys.last.value;
    var t = time;
    switch (mode) {
      case SceneTrackMode.clamp:
        t = t.clampDouble(start, end);
      case SceneTrackMode.loop:
        t = start + (t - start) % span;
        if (t < start) t += span;
      case SceneTrackMode.pingpong:
        final period = span * 2;
        t = start + (t - start) % period;
        if (t < start) t += period;
        if (t > end) t = end - (t - end);
    }
    var i = _cursor.clampInt(0, keys.length - 2);
    while (i > 0 && t < keys[i].time) {
      i--;
    }
    while (i < keys.length - 2 && t > keys[i + 1].time) {
      i++;
    }
    _cursor = i;
    final a = keys[i];
    final b = keys[i + 1];
    final segment = b.time - a.time;
    if (segment <= 0) return b.value;
    final u = ((t - a.time) / segment).clampDouble(0, 1);
    return a.value + (b.value - a.value) * b.curve.transform(u);
  }

  static SceneTrack parse(Object? value) {
    if (value is! Map) throw SceneFormatException('timeline 的每一项必须是对象');
    final target = value['target'];
    if (target is! String) throw SceneFormatException('timeline.target 必须是 "图层id.属性"');
    final dot = target.lastIndexOf('.');
    if (dot <= 0) throw SceneFormatException('timeline.target 必须是 "图层id.属性"，收到 $target');
    final property = SceneProperty.tryParse(target.substring(dot + 1));
    if (property == null) {
      final names = SceneProperty.values.map((p) => p.name).join(' / ');
      throw SceneFormatException('timeline.target 的属性无法识别：$target（可用 $names）');
    }
    final rawKeys = value['keys'];
    if (rawKeys is! List || rawKeys.isEmpty) throw SceneFormatException('$target 缺少 keys');
    final keys = <SceneKey>[];
    for (var i = 0; i < rawKeys.length; i++) {
      final raw = rawKeys[i];
      if (raw is! List || raw.length < 2) throw SceneFormatException('$target.keys[$i] 必须是 [时间, 数值, 缓动?]');
      keys.add(
        SceneKey(
          _double(raw[0], '$target.keys[$i][0]', 0),
          _double(raw[1], '$target.keys[$i][1]', 0),
          sceneCurve(raw.length > 2 ? raw[2] : null),
        ),
      );
    }
    for (var i = 1; i < keys.length; i++) {
      if (keys[i].time < keys[i - 1].time) throw SceneFormatException('$target 的关键帧时间必须递增');
    }
    return SceneTrack(
      layer: target.substring(0, dot),
      property: property,
      mode: SceneTrackMode.parse(value['mode']),
      keys: keys,
    );
  }
}

/// A painted layer. Subclasses carry the per-kind fields; the base carries the
/// ones every layer understands.
sealed class SceneLayer {
  SceneLayer({
    required this.id,
    required this.depth,
    required this.opacity,
    required this.visible,
    required this.x,
    required this.y,
    required this.scale,
    required this.rotation,
  });

  final String id;

  /// 0 = far, 1 = near. Layers are painted in ascending depth.
  final double depth;
  final double opacity;
  final bool visible;

  /// Static offset in logical pixels; timeline tracks add to these.
  final double x;
  final double y;
  final double scale;

  /// Degrees, clockwise.
  final double rotation;

  /// The layer's area in canvas coordinates.
  Rect areaIn(Size size) => Rect.fromLTRB(
    _area.left * size.width,
    _area.top * size.height,
    _area.right * size.width,
    _area.bottom * size.height,
  );

  /// Relative area of the layer, `[left, top, right, bottom]` in 0…1.
  Rect get _area;

  static SceneLayer parse(Object? value, {required Set<String> ids, required int depth, required SceneBudget budget}) {
    if (value is! Map) throw SceneFormatException('layers 的每一项必须是对象');
    final kind = value['kind'];
    if (kind is! String) throw SceneFormatException('layer.kind 缺失');
    final id = value['id'];
    if (id is! String || id.isEmpty) throw SceneFormatException('layer.id 缺失');
    if (!ids.add(id)) throw SceneFormatException('layer.id 重复：$id');
    if (depth > 4) throw SceneFormatException('group 嵌套太深（最多 4 层）');
    final layerDepth = _double(value['depth'], '$id.depth', 0.5).clampDouble(0, 1.2);
    final area = _rect(value['area'], '$id.area', const Rect.fromLTRB(0, 0, 1, 1));
    return switch (kind) {
      'gradient' => _gradient(id, layerDepth, value, area),
      'glow' => _glow(id, layerDepth, value, area),
      'image' => _image(id, layerDepth, value, area),
      'particles' => _particles(id, layerDepth, value, area, budget),
      'group' => _group(id, layerDepth, value, ids, depth, budget),
      _ => throw SceneFormatException('layer.kind 无法识别：$kind（可用 gradient / glow / image / particles / group）'),
    };
  }

  static SceneLayer _gradient(String id, double depth, Map value, Rect area) {
    final colors = <Color>[];
    final rawColors = value['colors'];
    if (rawColors is List && rawColors.length >= 2) {
      for (var i = 0; i < rawColors.length; i++) {
        colors.add(sceneColor(rawColors[i], '$id.colors[$i]'));
      }
    } else {
      final from = sceneColor(value['from'] ?? value['color'], '$id.from');
      final to = value['to'] == null ? from : sceneColor(value['to'], '$id.to');
      colors
        ..add(from)
        ..add(to);
    }
    final rawStops = value['stops'];
    final stops = <double>[];
    if (rawStops is List && rawStops.length == colors.length) {
      for (var i = 0; i < rawStops.length; i++) {
        stops.add(_double(rawStops[i], '$id.stops[$i]', 0).clampDouble(0, 1));
      }
    } else {
      for (var i = 0; i < colors.length; i++) {
        stops.add(i / (colors.length - 1));
      }
    }
    return SceneGradientLayer(
      id: id,
      depth: depth,
      opacity: _opacity(value, id),
      visible: _visible(value, id),
      x: _double(value['x'], '$id.x', 0),
      y: _double(value['y'], '$id.y', 0),
      scale: _scale(value, id),
      rotation: _double(value['rotation'], '$id.rotation', 0),
      gradient: SceneGradient(
        colors: colors,
        stops: stops,
        angle: _double(value['angle'], '$id.angle', 90),
        radial: value['type'] == 'radial',
        center: _point(value['center'], '$id.center', const Offset(0.5, 0.5)),
      ),
      area: area,
    );
  }

  static SceneLayer _glow(String id, double depth, Map value, Rect area) {
    final color = sceneColor(value['color'] ?? value['from'], '$id.color');
    final falloff = _double(value['falloff'], '$id.falloff', 0.55).clampDouble(0.05, 1.0);
    return SceneGlowLayer(
      id: id,
      depth: depth,
      opacity: _opacity(value, id),
      visible: _visible(value, id),
      x: _double(value['x'], '$id.x', 0),
      y: _double(value['y'], '$id.y', 0),
      scale: _scale(value, id),
      rotation: _double(value['rotation'], '$id.rotation', 0),
      color: color,
      falloff: falloff,
      area: area,
    );
  }

  static SceneLayer _image(String id, double depth, Map value, Rect area) {
    final src = sceneSource(value['src'], '$id.src');
    final tint = value['tint'] == null ? null : sceneColor(value['tint'], '$id.tint');
    return SceneImageLayer(
      id: id,
      depth: depth,
      opacity: _opacity(value, id),
      visible: _visible(value, id),
      x: _double(value['x'], '$id.x', 0),
      y: _double(value['y'], '$id.y', 0),
      scale: _scale(value, id),
      rotation: _double(value['rotation'], '$id.rotation', 0),
      src: src,
      fit: SceneFit.parse(value['fit']),
      tint: tint,
      area: area,
    );
  }

  static SceneLayer _particles(String id, double depth, Map value, Rect area, SceneBudget budget) {
    final count = _int(value['count'], '$id.count', 120).clampInt(1, 800);
    budget.particles += count;
    if (budget.particles > sceneMaxParticles) {
      throw SceneFormatException('粒子总数超过 $sceneMaxParticles');
    }
    final colors = <Color>[];
    final rawColors = value['colors'];
    if (rawColors is List && rawColors.isNotEmpty) {
      for (var i = 0; i < rawColors.length; i++) {
        colors.add(sceneColor(rawColors[i], '$id.colors[$i]'));
      }
    } else {
      colors.add(sceneColor(value['color'] ?? '#FFFFFF', '$id.color'));
    }
    final size = _pair(value['size'], '$id.size', 1.2, 2.6);
    final speed = _pair(value['speed'], '$id.speed', 4, 16);
    final lifetime = _pair(value['lifetime'], '$id.lifetime', 6, 14);
    final angle = _pair(value['angle'], '$id.angle', 0, 360);
    final fade = _pair(value['fade'], '$id.fade', 0.15, 0.45);
    return SceneParticleLayer(
      id: id,
      depth: depth,
      opacity: _opacity(value, id),
      visible: _visible(value, id),
      x: _double(value['x'], '$id.x', 0),
      y: _double(value['y'], '$id.y', 0),
      scale: _scale(value, id),
      rotation: _double(value['rotation'], '$id.rotation', 0),
      count: count,
      colors: colors,
      minSize: size.$1,
      maxSize: size.$2,
      minSpeed: speed.$1,
      maxSpeed: speed.$2,
      minLife: lifetime.$1,
      maxLife: lifetime.$2,
      minAngle: angle.$1,
      maxAngle: angle.$2,
      gravity: _double(value['gravity'], '$id.gravity', 0),
      drag: _double(value['drag'], '$id.drag', 0).clampDouble(0, 4),
      fadeIn: fade.$1.clampDouble(0, 1),
      fadeOut: fade.$2.clampDouble(0, 1),
      area: area,
    );
  }

  static SceneLayer _group(String id, double depth, Map value, Set<String> ids, int depthLevel, SceneBudget budget) {
    final rawChildren = value['children'];
    final children = <SceneLayer>[];
    if (rawChildren is List) {
      for (final child in rawChildren) {
        budget.layers++;
        if (budget.layers > sceneMaxLayers) throw SceneFormatException('图层总数超过 $sceneMaxLayers');
        children.add(parse(child, ids: ids, depth: depthLevel + 1, budget: budget));
      }
    }
    return SceneGroupLayer(
      id: id,
      depth: depth,
      opacity: _opacity(value, id),
      visible: _visible(value, id),
      x: _double(value['x'], '$id.x', 0),
      y: _double(value['y'], '$id.y', 0),
      scale: _scale(value, id),
      rotation: _double(value['rotation'], '$id.rotation', 0),
      children: children,
      area: _rect(value['area'], '$id.area', const Rect.fromLTRB(0, 0, 1, 1)),
    );
  }
}

final class SceneGradientLayer extends SceneLayer {
  SceneGradientLayer({
    required super.id,
    required super.depth,
    required super.opacity,
    required super.visible,
    required super.x,
    required super.y,
    required super.scale,
    required super.rotation,
    required this.gradient,
    required this.area,
  });

  final SceneGradient gradient;
  final Rect area;

  @override
  Rect get _area => area;
}

final class SceneGlowLayer extends SceneLayer {
  SceneGlowLayer({
    required super.id,
    required super.depth,
    required super.opacity,
    required super.visible,
    required super.x,
    required super.y,
    required super.scale,
    required super.rotation,
    required this.color,
    required this.falloff,
    required this.area,
  });

  final Color color;

  /// Where the glow starts to fade out, as a fraction of its radius.
  final double falloff;
  final Rect area;

  @override
  Rect get _area => area;
}

final class SceneImageLayer extends SceneLayer {
  SceneImageLayer({
    required super.id,
    required super.depth,
    required super.opacity,
    required super.visible,
    required super.x,
    required super.y,
    required super.scale,
    required super.rotation,
    required this.src,
    required this.fit,
    required this.tint,
    required this.area,
  });

  final String src;
  final SceneFit fit;
  final Color? tint;
  final Rect area;

  @override
  Rect get _area => area;
}

final class SceneParticleLayer extends SceneLayer {
  SceneParticleLayer({
    required super.id,
    required super.depth,
    required super.opacity,
    required super.visible,
    required super.x,
    required super.y,
    required super.scale,
    required super.rotation,
    required this.count,
    required this.colors,
    required this.minSize,
    required this.maxSize,
    required this.minSpeed,
    required this.maxSpeed,
    required this.minLife,
    required this.maxLife,
    required this.minAngle,
    required this.maxAngle,
    required this.gravity,
    required this.drag,
    required this.fadeIn,
    required this.fadeOut,
    required this.area,
  });

  final int count;

  /// The colour ramp a particle walks through over its life.
  final List<Color> colors;
  final double minSize;
  final double maxSize;

  /// Logical pixels per second.
  final double minSpeed;
  final double maxSpeed;

  /// Seconds.
  final double minLife;
  final double maxLife;

  /// Degrees: 0 = right, 90 = down.
  final double minAngle;
  final double maxAngle;

  /// Logical pixels per second squared.
  final double gravity;

  /// Velocity decay per second (0 = none).
  final double drag;

  /// Fractions of the lifetime spent fading in and out.
  final double fadeIn;
  final double fadeOut;
  final Rect area;

  @override
  Rect get _area => area;
}

final class SceneGroupLayer extends SceneLayer {
  SceneGroupLayer({
    required super.id,
    required super.depth,
    required super.opacity,
    required super.visible,
    required super.x,
    required super.y,
    required super.scale,
    required super.rotation,
    required this.children,
    required this.area,
  });

  final List<SceneLayer> children;
  final Rect area;

  @override
  Rect get _area => area;
}

/// One look: what is drawn, and how it moves.
class SceneScene {
  SceneScene({required this.background, required this.layers, required this.timeline, this.tint, this.video});

  final SceneGradient background;
  final List<SceneLayer> layers;
  final List<SceneTrack> timeline;

  /// A wash over the whole scene, for a quick morning/evening mood.
  final Color? tint;

  /// Footage played behind the layers; the layers then draw over it. Null means
  /// the background gradient is painted instead.
  final SceneVideo? video;

  static SceneScene parse(Object? value, {SceneScene? inherit, required SceneBudget budget}) {
    final map = value ?? const <Object?, Object?>{};
    if (map is! Map) throw SceneFormatException('scene 必须是对象');
    final background = map['background'] == null
        ? inherit?.background ?? SceneGradient(colors: const [Color(0xFF000000), Color(0xFF000000)], stops: const [0, 1])
        : SceneGradient.parse(map['background']);
    final rawLayers = map['layers'];
    final layers = <SceneLayer>[];
    if (rawLayers is List) {
      final ids = <String>{};
      for (final raw in rawLayers) {
        budget.layers++;
        if (budget.layers > sceneMaxLayers) throw SceneFormatException('图层总数超过 $sceneMaxLayers');
        layers.add(SceneLayer.parse(raw, ids: ids, depth: 1, budget: budget));
      }
    }
    final timeline = <SceneTrack>[];
    final rawTimeline = map['timeline'];
    if (rawTimeline is List) {
      for (final raw in rawTimeline) {
        timeline.add(SceneTrack.parse(raw));
      }
    }
    if (timeline.length > sceneMaxTimelineTracks) throw SceneFormatException('timeline 超过 $sceneMaxTimelineTracks 条');
    final tint = map['tint'] == null ? null : sceneColor(map['tint'], 'tint');
    final video = map['video'] == null ? null : SceneVideo.parse(map['video']);
    if (inherit != null) {
      // A period only replaces the parts it names; the rest comes from the base scene.
      return SceneScene(
        background: map.containsKey('background') ? background : inherit.background,
        layers: map.containsKey('layers') ? layers : inherit.layers,
        timeline: map.containsKey('timeline') ? timeline : inherit.timeline,
        tint: map.containsKey('tint') ? tint : inherit.tint,
        video: map.containsKey('video') ? video : inherit.video,
      );
    }
    return SceneScene(background: background, layers: layers, timeline: timeline, tint: tint, video: video);
  }
}

/// A parsed wallpaper file.
class SceneDocument {
  SceneDocument({
    required this.id,
    required this.name,
    required this.duration,
    required this.loop,
    required this.fpsCap,
    required this.scene,
    required this.periods,
    this.videos = const {},
  });

  final String id;
  final String name;

  /// Seconds; informational (tracks loop on their own).
  final double duration;
  final bool loop;

  /// 24…60 frames per second. The runtime never draws faster than this.
  final int fpsCap;
  final SceneScene scene;

  /// Time-of-day variants; a missing entry falls back to [scene].
  final Map<ScenePeriod, SceneScene> periods;

  /// Per-period footage from the document-level `videos` map, a shortcut for
  /// putting one file under each period without repeating the whole scene.
  final Map<ScenePeriod, SceneVideo> videos;

  SceneScene sceneAt(ScenePeriod period) => periods[period] ?? scene;

  /// The video that plays in [period]: the `videos` map wins, then the period's
  /// own scene, then the base scene.
  SceneVideo? videoAt(ScenePeriod period) => videos[period] ?? sceneAt(period).video;

  /// Every file this document reads from its package: images and videos.
  /// `asset:` and `data:` sources are not files of the package and are skipped.
  Set<String> get sources {
    final sources = <String>{};
    void walk(List<SceneLayer> layers) {
      for (final layer in layers) {
        switch (layer) {
          case SceneImageLayer():
            sources.add(layer.src);
          case SceneGroupLayer():
            walk(layer.children);
          default:
            break;
        }
      }
    }

    for (final look in [scene, ...periods.values]) {
      walk(look.layers);
      final video = look.video;
      if (video != null) sources.add(video.src);
    }
    for (final video in videos.values) {
      sources.add(video.src);
    }
    sources.removeWhere((src) => src.startsWith('asset:') || src.startsWith('data:'));
    return sources;
  }

  static SceneDocument parse(String source) {
    Object? json;
    try {
      json = jsonDecode(source);
    } on FormatException catch (error) {
      throw SceneFormatException('JSON 无法解析：${error.message}');
    }
    return fromJson(json);
  }

  static SceneDocument fromJson(Object? json) {
    if (json is! Map) throw SceneFormatException('根节点必须是 JSON 对象');
    final version = _int(json['schemaVersion'], 'schemaVersion', sceneSchemaVersion);
    if (version > sceneSchemaVersion) {
      throw SceneFormatException('schemaVersion $version 高于本应用支持的 $sceneSchemaVersion，请升级应用');
    }
    if (version < 1) throw SceneFormatException('schemaVersion 必须大于 0');
    final budget = SceneBudget();
    final scene = SceneScene.parse(json, budget: budget);
    final periods = <ScenePeriod, SceneScene>{};
    final rawPeriods = json['periods'];
    if (rawPeriods is Map) {
      for (final period in ScenePeriod.values) {
        final raw = rawPeriods[period.name];
        if (raw == null) continue;
        periods[period] = SceneScene.parse(raw, inherit: scene, budget: budget);
      }
    }
    final videos = <ScenePeriod, SceneVideo>{};
    final rawVideos = json['videos'];
    if (rawVideos is Map) {
      for (final period in ScenePeriod.values) {
        final raw = rawVideos[period.name];
        if (raw == null) continue;
        videos[period] = SceneVideo.parse(raw, field: 'videos.${period.name}');
      }
    }
    final render = json['render'];
    final fpsCap = render is Map ? _int(render['fpsCap'], 'render.fpsCap', 30).clampInt(24, 60) : 30;
    return SceneDocument(
      id: _text(json['id'], 'id', 'scene'),
      name: _text(json['name'], 'name', ''),
      duration: _double(json['duration'], 'duration', 0),
      loop: json['loop'] is bool ? json['loop'] as bool : true,
      fpsCap: fpsCap,
      scene: scene,
      periods: periods,
      videos: videos,
    );
  }
}

/// Counts what a file has asked for so far, so a huge file is refused while it
/// is being parsed instead of after it has been allocated.
class SceneBudget {
  int layers = 0;
  int particles = 0;
}

String _text(Object? value, String field, String fallback) {
  if (value == null) return fallback;
  if (value is String) return value;
  throw SceneFormatException('$field 必须是字符串');
}

double _double(Object? value, String field, double fallback) {
  if (value == null) return fallback;
  if (value is num) return value.toDouble();
  throw SceneFormatException('$field 必须是数字');
}

int _int(Object? value, String field, int fallback) {
  if (value == null) return fallback;
  if (value is num) return value.toInt();
  throw SceneFormatException('$field 必须是整数');
}

double _opacity(Map value, String id) => _double(value['opacity'], '$id.opacity', 1).clampDouble(0, 1);

bool _visible(Map value, String id) => value['visible'] is bool ? value['visible'] as bool : true;

double _scale(Map value, String id) => _double(value['scale'], '$id.scale', 1).clampDouble(0.05, 20.0);

/// `[min, max]`, or a single number for both ends.
(double, double) _pair(Object? value, String field, double fallbackMin, double fallbackMax) {
  if (value == null) return (fallbackMin, fallbackMax);
  if (value is num) return (value.toDouble(), value.toDouble());
  if (value is List && value.isNotEmpty && value.length <= 2) {
    final min = _double(value[0], '$field[0]', fallbackMin);
    final max = value.length > 1 ? _double(value[1], '$field[1]', min) : min;
    return (math.min(min, max), math.max(min, max));
  }
  throw SceneFormatException('$field 必须是数字或 [最小, 最大]');
}

Rect _rect(Object? value, String field, Rect fallback) {
  if (value == null) return fallback;
  if (value is List && value.length == 4) {
    return Rect.fromLTRB(
      _double(value[0], '$field[0]', 0).clampDouble(-4, 4),
      _double(value[1], '$field[1]', 0).clampDouble(-4, 4),
      _double(value[2], '$field[2]', 1).clampDouble(-4, 4),
      _double(value[3], '$field[3]', 1).clampDouble(-4, 4),
    );
  }
  throw SceneFormatException('$field 必须是 [left, top, right, bottom]（0…1 的相对坐标）');
}

Offset _point(Object? value, String field, Offset fallback) {
  if (value == null) return fallback;
  if (value is List && value.length == 2) {
    return Offset(
      _double(value[0], '$field[0]', fallback.dx).clampDouble(-4, 4),
      _double(value[1], '$field[1]', fallback.dy).clampDouble(-4, 4),
    );
  }
  throw SceneFormatException('$field 必须是 [x, y]');
}

/// `"#RRGGBB"` or `"#AARRGGBB"`.
Color sceneColor(Object? value, String field) {
  if (value is! String) throw SceneFormatException('$field 必须是 "#RRGGBB" 或 "#AARRGGBB"');
  var text = value.trim();
  if (text.startsWith('#')) text = text.substring(1);
  if (text.length == 6) text = 'FF$text';
  if (text.length != 8) throw SceneFormatException('$field 颜色格式不对：$value');
  final rgba = int.tryParse(text, radix: 16);
  if (rgba == null) throw SceneFormatException('$field 颜色格式不对：$value');
  return Color(rgba);
}

/// `num.clamp` hands back `num`; these keep the concrete type so call sites can
/// stay `double` / `int`.
extension SceneClamp on num {
  double clampDouble(num lower, num upper) => clamp(lower, upper).toDouble();

  int clampInt(num lower, num upper) => clamp(lower, upper).toInt();
}

/// The same clamp, for values that are not an expression already being chained.
double sceneClamp(num value, num lower, num upper) => value.clamp(lower, upper).toDouble();
