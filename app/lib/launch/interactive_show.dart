// 互动启动画面的步骤：只有时间和输入，不碰界面，测得了。
//
//   brand   品牌入场（自动，约 2.6 s）
//   start   第一幕：背景 + 准星，“开始”按钮（等待）
//   confirm 第二幕：资料卡，“确认”按钮（等待；确认后特效平滑加速）
//   scan    扫描演出（自动：按时长，或这一幕的视频放完）
//   welcome 欢迎文字 + 光晕 / 色散（自动）
//   done    演出结束，启动画面照常收起
//
// 时间只靠 [InteractiveShow.tick] 往前走：暂停时不走，一帧最多走 100 ms，所以 App 从后台
// 回来接着刚才的地方，不补播、不重放。等待中的一幕只认一次点击；新一幕的按钮出来前的
// 点击不算（连点不会一下跳过两幕）。跳过随时可用，只结束演出。

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

enum ShowStage { brand, start, confirm, scan, welcome, done }

class InteractiveShow extends ChangeNotifier {
  InteractiveShow({this.reduced = false, this._effectSpeed = 1, this.scanWaitsForMedia = false});

  /// 减少动画: the intro and the welcome are short and nothing spins; the buttons stay.
  final bool reduced;

  /// The scan scene has a clip: it lasts until the clip ends (at least [scanMin], at most
  /// [scanMax]).
  final bool scanWaitsForMedia;

  final double _effectSpeed;

  static const brandLength = 2.6;
  static const brandLengthReduced = 0.8;

  /// A waiting scene comes in over this; its button takes no tap before [acceptAfter].
  static const enter = 0.9;
  static const acceptAfter = 0.55;

  /// A pressed scene goes out over this, then the next one starts.
  static const exit = 0.5;
  static const scanLength = 3.6;
  static const scanMin = 1.6;
  static const scanMax = 20.0;
  static const welcomeLength = 2.8;
  static const welcomeLengthReduced = 1.4;

  /// How much faster the effects run once confirmed.
  static const boostTo = 2.8;

  /// The longest step one tick may take (a frame after the app was away is not a jump).
  static const maxStep = 0.1;

  ShowStage _stage = ShowStage.brand;
  ShowStage get stage => _stage;

  double _t = 0;

  /// Seconds into [stage].
  double get t => _t;

  double? _pressedAt;
  double _effect = 0;
  double _boost = 1;
  bool _paused = false;
  bool _mediaEnded = false;

  bool get done => _stage == ShowStage.done;

  /// The effects' clock: seconds at the effect speed, faster after the confirm.
  double get effectTime => _effect;

  /// The effects' current rate (1 at rest, up to [boostTo] × the effect speed).
  double get effectRate => _effectSpeed * _boost;

  bool get paused => _paused;
  set paused(bool value) {
    if (_paused == value) return;
    _paused = value;
    notifyListeners();
  }

  double get brandLengthNow => reduced ? brandLengthReduced : brandLength;
  double get welcomeLengthNow => reduced ? welcomeLengthReduced : welcomeLength;

  /// The current scene's button has been pressed (it is going out).
  bool get pressed => _pressedAt != null;

  /// 0 → 1 as a pressed scene goes out.
  double get leaving => _pressedAt == null ? 0 : ((_t - _pressedAt!) / exit).clamp(0.0, 1.0);

  /// Waiting for a tap on [stage]'s button.
  bool get waiting => (_stage == ShowStage.start || _stage == ShowStage.confirm) && _pressedAt == null;

  /// The decorative bar at the bottom: where the show is, not what the engine does.
  double get progress => switch (_stage) {
    ShowStage.brand => 0.12 * (_t / brandLengthNow).clamp(0.0, 1.0),
    ShowStage.start => 0.34,
    ShowStage.confirm => 0.5,
    ShowStage.scan => 0.66 + 0.27 * (_t / (scanWaitsForMedia ? scanMax : scanLength)).clamp(0.0, 1.0),
    ShowStage.welcome || ShowStage.done => 1,
  };

  void tick(Duration elapsed) {
    if (_paused || done) return;
    final dt = math.min(elapsed.inMicroseconds / Duration.microsecondsPerSecond, maxStep);
    if (dt <= 0) return;
    _t += dt;
    final boosted = _stage.index > ShowStage.confirm.index || (_stage == ShowStage.confirm && pressed);
    final target = boosted ? boostTo : 1.0;
    // Eases toward the target (about 0.8 s to get most of the way).
    _boost += (target - _boost) * math.min(1, dt * 3.5);
    if (!reduced) _effect += dt * effectRate;
    _advance();
    notifyListeners();
  }

  /// A tap on [at]'s button: true when it counts.
  bool press(ShowStage at) {
    if (_stage != at || !waiting || _paused || _t < acceptAfter) return false;
    _pressedAt = _t;
    notifyListeners();
    return true;
  }

  /// The scan scene's clip has played through.
  void mediaEnded() => _mediaEnded = true;

  /// 跳过 / back: the show ends now.
  void skip() {
    if (done) return;
    _go(ShowStage.done);
    notifyListeners();
  }

  void _advance() {
    switch (_stage) {
      case ShowStage.brand when _t >= brandLengthNow:
        _go(ShowStage.start);
      case ShowStage.start || ShowStage.confirm when _pressedAt != null && _t - _pressedAt! >= exit:
        _go(_stage == ShowStage.start ? ShowStage.confirm : ShowStage.scan);
      case ShowStage.scan when _scanOver:
        _go(ShowStage.welcome);
      case ShowStage.welcome when _t >= welcomeLengthNow:
        _go(ShowStage.done);
      default:
        break;
    }
  }

  bool get _scanOver {
    if (!scanWaitsForMedia) return _t >= (reduced ? scanMin : scanLength);
    return (_mediaEnded && _t >= scanMin) || _t >= scanMax;
  }

  void _go(ShowStage next) {
    _stage = next;
    _t = 0;
    _pressedAt = null;
  }
}
