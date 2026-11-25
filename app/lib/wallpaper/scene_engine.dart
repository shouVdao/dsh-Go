// The runtime behind the .json wallpaper: advances a parsed scene by a time
// step and paints it. One engine per scene; the view owns the ticker and the
// images, and painting is synchronous so a repaint never waits.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'scene_document.dart';

/// Advances and paints one [SceneDocument].
class SceneEngine extends ChangeNotifier {
  SceneEngine({required this.document, required ScenePeriod period, this.images = const {}, this.paintBackground = true}) {
    apply(period);
  }

  final SceneDocument document;
  final Map<String, ui.Image> images;

  /// Whether the scene's background gradient is painted. A period with footage
  /// turns this off so the video shows through; the layers still draw over it.
  bool paintBackground = true;

  late SceneScene _scene;
  late ScenePeriod _period;
  late Gradient _background;
  late List<SceneLayer> _layers;

  /// Tracks by layer id, then property.
  final Map<String, Map<SceneProperty, SceneTrack>> _tracks = {};
  final Map<String, _ParticleField> _particles = {};
  final Map<String, _ShaderCache> _shaders = {};

  /// Seconds since the scene appeared.
  double time = 0;
  Size _size = Size.zero;
  bool _animated = false;

  ScenePeriod get period => _period;
  SceneScene get scene => _scene;

  /// Switches to another time-of-day variant, restarting the clock.
  void apply(ScenePeriod period) {
    _period = period;
    _scene = document.sceneAt(period);
    _background = _scene.background.gradient();
    _layers = List<SceneLayer>.of(_scene.layers)..sort((a, b) => a.depth.compareTo(b.depth));
    _tracks.clear();
    for (final track in _scene.timeline) {
      (_tracks[track.layer] ??= {})[track.property] = track;
    }
    _shaders.clear();
    final fields = <String, _ParticleField>{};
    void collect(List<SceneLayer> layers) {
      for (final layer in layers) {
        switch (layer) {
          case SceneParticleLayer():
            fields[layer.id] = _particles[layer.id] ?? _ParticleField(layer, layer.id.hashCode);
          case SceneGroupLayer():
            collect(layer.children);
          default:
            break;
        }
      }
    }

    collect(_layers);
    _particles
      ..clear()
      ..addAll(fields);
    time = 0;
    _animated = _scene.timeline.isNotEmpty || _particles.isNotEmpty;
  }

  /// One time step, in seconds. The view clamps it before calling.
  void advance(double dt) {
    time += dt;
    for (final field in _particles.values) {
      field.advance(dt, _size, _value(field.layer, SceneProperty.speed, 1).clampDouble(0, 8));
    }
    if (_animated) notifyListeners();
  }

  void paint(Canvas canvas, Size size) {
    _size = size;
    final bounds = Offset.zero & size;
    if (paintBackground) canvas.drawRect(bounds, Paint()..shader = _background.createShader(bounds));
    _paintLayers(canvas, size, _layers, 1);
    final tint = _scene.tint;
    if (tint != null) canvas.drawRect(bounds, Paint()..color = tint);
  }

  double _value(SceneLayer layer, SceneProperty property, double fallback) {
    final track = _tracks[layer.id]?[property];
    return track == null ? fallback : track.sample(time);
  }

  void _paintLayers(Canvas canvas, Size size, List<SceneLayer> layers, double inherited) {
    for (final layer in layers) {
      final opacity = (_value(layer, SceneProperty.opacity, layer.opacity) * inherited).clampDouble(0, 1);
      final visible = _value(layer, SceneProperty.visible, layer.visible ? 1 : 0) >= 0.5;
      if (!visible || opacity <= 0.002) continue;
      final scale = _value(layer, SceneProperty.scale, layer.scale).clampDouble(0.02, 40);
      final rotation = _value(layer, SceneProperty.rotation, layer.rotation) * math.pi / 180;
      final dx = _value(layer, SceneProperty.x, layer.x);
      final dy = _value(layer, SceneProperty.y, layer.y);
      final moved = scale != 1 || rotation != 0 || dx != 0 || dy != 0;
      if (moved) {
        canvas.save();
        canvas.translate(size.width / 2 + dx, size.height / 2 + dy);
        canvas.rotate(rotation);
        canvas.scale(scale);
        canvas.translate(-size.width / 2, -size.height / 2);
      }
      switch (layer) {
        case SceneGroupLayer():
          _paintLayers(canvas, size, layer.children, opacity);
        case SceneGradientLayer():
          _paintGradient(canvas, size, layer, opacity);
        case SceneGlowLayer():
          _paintGlow(canvas, size, layer, opacity);
        case SceneImageLayer():
          _paintImage(canvas, size, layer, opacity);
        case SceneParticleLayer():
          final count = _value(layer, SceneProperty.count, 1).clampDouble(0, 1);
          _particles[layer.id]?.paint(canvas, layer, opacity, count);
      }
      if (moved) canvas.restore();
    }
  }

  void _paintGradient(Canvas canvas, Size size, SceneGradientLayer layer, double opacity) {
    final rect = layer.areaIn(size);
    if (rect.isEmpty) return;
    final alpha = (opacity * 255).round().clampInt(0, 255);
    var shader = _shaders[layer.id];
    if (shader == null || shader.alpha != alpha) {
      // A gradient's own colours carry the layer's opacity: no saveLayer per frame.
      shader = _ShaderCache(
        alpha,
        SceneGradient(
          colors: [for (final color in layer.gradient.colors) color.withValues(alpha: color.a * opacity)],
          stops: layer.gradient.stops,
          angle: layer.gradient.angle,
          radial: layer.gradient.radial,
          center: layer.gradient.center,
        ).gradient(),
      );
      _shaders[layer.id] = shader;
    }
    canvas.drawRect(rect, Paint()..shader = shader.gradient.createShader(rect));
  }

  void _paintGlow(Canvas canvas, Size size, SceneGlowLayer layer, double opacity) {
    final rect = layer.areaIn(size);
    if (rect.isEmpty) return;
    final color = layer.color.withValues(alpha: layer.color.a * opacity);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          colors: [color, color.withValues(alpha: 0)],
          stops: [math.max(0.0, 1 - layer.falloff), 1],
        ).createShader(rect),
    );
  }

  void _paintImage(Canvas canvas, Size size, SceneImageLayer layer, double opacity) {
    final image = images[layer.src];
    if (image == null) return;
    final area = layer.areaIn(size);
    if (area.isEmpty) return;
    final (src, dst) = _fitRect(Size(image.width.toDouble(), image.height.toDouble()), area, layer.fit);
    final paint = Paint()..filterQuality = FilterQuality.medium;
    final tint = layer.tint;
    if (tint != null) {
      paint.colorFilter = ColorFilter.mode(tint.withValues(alpha: tint.a * opacity), BlendMode.srcATop);
    } else {
      paint.color = Color.fromRGBO(255, 255, 255, opacity);
    }
    canvas.drawImageRect(image, src, dst, paint);
  }

  static (Rect, Rect) _fitRect(Size image, Rect area, SceneFit fit) {
    final full = Rect.fromLTWH(0, 0, image.width, image.height);
    switch (fit) {
      case SceneFit.fill:
        return (full, area);
      case SceneFit.contain:
        final scale = math.min(area.width / image.width, area.height / image.height);
        return (full, Rect.fromCenter(center: area.center, width: image.width * scale, height: image.height * scale));
      case SceneFit.cover:
        final scale = math.max(area.width / image.width, area.height / image.height);
        final crop = Rect.fromCenter(
          center: Offset(image.width / 2, image.height / 2),
          width: area.width / scale,
          height: area.height / scale,
        );
        return (crop, area);
    }
  }
}

class _ShaderCache {
  _ShaderCache(this.alpha, this.gradient);

  final int alpha;
  final Gradient gradient;
}

/// The particles of one layer: typed arrays, no per-frame allocation.
class _ParticleField {
  _ParticleField(this.layer, int seed) : _random = math.Random(seed) {
    final count = layer.count;
    _x = Float32List(count);
    _y = Float32List(count);
    _vx = Float32List(count);
    _vy = Float32List(count);
    _age = Float32List(count);
    _life = Float32List(count);
    _size = Float32List(count);
    for (var i = 0; i < count; i++) {
      _respawn(i, const Size(1, 1));
      // Start mid-flight so the first frame is a full sky, not an empty one.
      final age = _random.nextDouble() * _life[i];
      _age[i] = age;
      _x[i] += _vx[i] * age;
      _y[i] += _vy[i] * age;
    }
  }

  final SceneParticleLayer layer;
  final math.Random _random;
  late final Float32List _x;
  late final Float32List _y;
  late final Float32List _vx;
  late final Float32List _vy;
  late final Float32List _age;
  late final Float32List _life;
  late final Float32List _size;
  final Paint _dot = Paint()..isAntiAlias = true;

  void _respawn(int i, Size size) {
    final area = layer.areaIn(size);
    _x[i] = area.left + _random.nextDouble() * area.width;
    _y[i] = area.top + _random.nextDouble() * area.height;
    final angle = (layer.minAngle + _random.nextDouble() * (layer.maxAngle - layer.minAngle)) * math.pi / 180;
    final speed = layer.minSpeed + _random.nextDouble() * (layer.maxSpeed - layer.minSpeed);
    _vx[i] = math.cos(angle) * speed;
    _vy[i] = math.sin(angle) * speed;
    _age[i] = 0;
    _life[i] = math.max(0.2, layer.minLife + _random.nextDouble() * (layer.maxLife - layer.minLife));
    _size[i] = layer.minSize + _random.nextDouble() * (layer.maxSize - layer.minSize);
  }

  void advance(double dt, Size size, double speed) {
    final step = dt * speed;
    final drag = layer.drag <= 0 ? 1.0 : math.max(0.0, 1 - layer.drag * step);
    final gravity = layer.gravity * step;
    const margin = 64.0;
    final width = size.width;
    final height = size.height;
    for (var i = 0; i < _x.length; i++) {
      _age[i] += step;
      if (_age[i] >= _life[i]) {
        _respawn(i, size);
        continue;
      }
      _vx[i] *= drag;
      _vy[i] = _vy[i] * drag + gravity;
      _x[i] += _vx[i] * step;
      _y[i] += _vy[i] * step;
      if (_x[i] < -margin || _x[i] > width + margin || _y[i] < -margin || _y[i] > height + margin) {
        _respawn(i, size);
      }
    }
  }

  void paint(Canvas canvas, SceneParticleLayer layer, double opacity, double countScale) {
    final shown = (_x.length * countScale).round().clampInt(0, _x.length);
    for (var i = 0; i < shown; i++) {
      final t = (_age[i] / _life[i]).clampDouble(0, 1);
      var alpha = 1.0;
      if (layer.fadeIn > 0 && t < layer.fadeIn) {
        alpha = t / layer.fadeIn;
      } else if (layer.fadeOut > 0 && t > 1 - layer.fadeOut) {
        alpha = (1 - t) / layer.fadeOut;
      }
      alpha = alpha * opacity;
      if (alpha <= 0.01) continue;
      final ramp = _ramp(layer.colors, t);
      canvas.drawCircle(Offset(_x[i], _y[i]), _size[i] / 2, _dot..color = ramp.withValues(alpha: ramp.a * alpha));
    }
  }

  static Color _ramp(List<Color> colors, double t) {
    if (colors.length == 1) return colors.first;
    final scaled = t.clampDouble(0, 1) * (colors.length - 1);
    final index = scaled.floor().clampInt(0, colors.length - 2);
    return Color.lerp(colors[index], colors[index + 1], scaled - index) ?? colors[index];
  }
}
