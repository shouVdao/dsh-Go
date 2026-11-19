// The balance whale above the composer: the app's own version of the
// DeepSeek-Balance-Whale-Widget. It is only the character until it is tapped:
// a tap shows the balance for three seconds, and tapping the balance bubble
// says one of the preset lines in a bubble of its own. Pressing squeezes it and
// plays the squish clip, letting go springs back with the release clip.
// Dragging moves it anywhere in the strip above the composer, snapping flush to
// either edge; the side the straight edge of the artwork points at follows the
// screen edge it snapped to.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/balance_state.dart';
import '../../../state/pendant_options.dart';
import '../../../state/settings_state.dart';
import '../../theme/motion.dart';
import '../balance_widgets.dart';

/// Side of the head's box; the bubble size follows from it.
const whalePendantArt = 62.0;

/// The balance bubble: narrow enough to stay out of the way, wide enough for
/// `¥ 1234.56`.
const _balanceWidth = 150.0;
const _balanceHeight = 98.0;

/// The line bubble holds only text, so it can be a little wider and shorter.
const _lineWidth = 168.0;

/// How long a tapped bubble stays before the whale goes back to being just art.
const _hold = Duration(seconds: 3);

/// A drag within this much of an edge parks the whale on it.
const _snap = 0.08;

/// The pet hands its drag to the arena before the page's own swipe can
/// (`PetMetrics.dragSlop / 2`); the same slop here keeps a sideways drag on the
/// whale from turning into a page change.
const _dragSlop = 3.0;

/// Which bubble is out, if any.
enum _Bubble { none, balance, line }

class WhalePendant extends ConsumerStatefulWidget {
  const WhalePendant({super.key, this.aside = false});

  /// The chat is showing something above the composer, so the whale steps out
  /// of the way without losing its bubble.
  final bool aside;

  @override
  ConsumerState<WhalePendant> createState() => _WhalePendantState();
}

class _WhalePendantState extends ConsumerState<WhalePendant> {
  /// Made on the first press: a test host has no audio plugin, and building
  /// one up front reports a missing channel long after the test has ended.
  ///
  /// A pool per clip, not a player per press: every `play` on a single player
  /// released the native session and asked for a new one, so the first tap
  /// sounded and the rest queued behind a prepare that never finished. The
  /// pool keeps a few players loaded with the clip and resumes one of them.
  AudioPool? _press;
  AudioPool? _release;

  /// The preset the pools were built for; changing it rebuilds them.
  String? _pooled;
  int _audioFails = 0;

  /// True while a pool is being built: the first press loads the clip, and a
  /// second one arriving in that window must not build a second pool.
  bool _loadingSound = false;

  _Bubble _bubble = _Bubble.none;
  String? _line;
  Timer? _holdTimer;
  bool _dragging = false;

  /// The squeeze and the drag move on their own: rebuilding the bubble and the
  /// balance card for every pointer event was what made a tap feel heavy.
  final ValueNotifier<bool> _squashed = ValueNotifier<bool>(false);
  final ValueNotifier<Offset> _dragOffset = ValueNotifier<Offset>(Offset.zero);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(balanceProvider.notifier).refresh();
    });
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _squashed.dispose();
    _dragOffset.dispose();
    unawaited(_press?.dispose());
    unawaited(_release?.dispose());
    super.dispose();
  }

  /// A press and a release each get their own clip, like the original widget.
  Future<void> _play({required bool press}) async {
    final settings = ref.read(settingsProvider);
    if (settings.pendantSound == pendantSoundOff || _audioFails >= 3) return;
    if (_loadingSound) return;
    _loadingSound = true;
    try {
      final pool = await _pool(press: press, settings: settings);
      if (pool == null) return;
      await pool.start();
    } catch (error) {
      // A missing or unsupported clip must not break the tap, and it must not
      // silence the widget for good either: give the clip a couple more tries.
      _audioFails++;
      debugPrint('whale pendant sound: $error');
    } finally {
      _loadingSound = false;
    }
  }

  /// The pool for one half of a press, built the first time it is needed.
  ///
  /// The custom clip is a single file: the press plays it and the release has
  /// nothing of its own. `PlayerMode.mediaPlayer` is deliberate — the pool
  /// reuses a prepared player and takes it back when the clip ends, while low
  /// latency players never report completion and would leak out of the pool.
  Future<AudioPool?> _pool({required bool press, required AppSettings settings}) async {
    final custom = settings.pendantSound == pendantSoundCustom;
    final key = custom ? 'custom:${settings.pendantSoundPath}' : settings.pendantSound;
    if (_pooled != key) {
      _pooled = key;
      _press = await _close(_press);
      _release = await _close(_release);
    }
    final cached = press ? _press : _release;
    if (cached != null) return cached;
    final Source? source;
    if (custom) {
      if (!press || settings.pendantSoundPath.isEmpty) return null;
      source = DeviceFileSource(settings.pendantSoundPath);
    } else if (pendantSoundAssets(settings.pendantSound) case final pair?) {
      final clip = press ? pair.press : pair.release;
      source = AssetSource(clip.substring('assets/'.length));
    } else {
      source = null;
    }
    if (source == null) return null;
    final pool = await AudioPool.create(source: source, minPlayers: 1, maxPlayers: 3);
    if (press) {
      _press = pool;
    } else {
      _release = pool;
    }
    return pool;
  }

  static Future<AudioPool?> _close(AudioPool? pool) async {
    await pool?.dispose();
    return null;
  }

  /// Down and up drive the same spring, so a short tap and a long press both
  /// squash under the finger and spring back when it leaves.
  void _squeeze({required bool down}) {
    if (!mounted || _squashed.value == down) return;
    _squashed.value = down;
    unawaited(_play(press: down));
  }

  /// A tap on the character shows the balance for a moment; it never stays.
  void _showBalance() {
    HapticFeedback.lightImpact();
    ref.read(balanceProvider.notifier).refresh();
    setState(() {
      _bubble = _Bubble.balance;
      _line = null;
    });
    _holdBubble();
  }

  /// A tap on the balance bubble says one of the preset lines instead, in a
  /// bubble with nothing but the line in it.
  void _saySomething() {
    final lines = pendantLinesOf(ref.read(settingsProvider).pendantLines);
    HapticFeedback.selectionClick();
    setState(() {
      _bubble = _Bubble.line;
      _line = lines[math.Random().nextInt(lines.length)];
    });
    _holdBubble();
  }

  /// Every bubble is on a timer: three seconds, then back to just the whale.
  /// The countdown inside the balance card ticks itself, so this timer changes
  /// the tree once, at the end.
  void _holdBubble() {
    _holdTimer?.cancel();
    _holdTimer = Timer(_hold, () {
      if (!mounted) return;
      setState(() {
        _bubble = _Bubble.none;
        _line = null;
      });
    });
  }

  /// Where a drag left the whale, as fractions of the strip it can move in.
  void _dragEnd(Size strip) {
    final settings = ref.read(settingsProvider);
    final delta = _dragOffset.value;
    _dragOffset.value = Offset.zero;
    final width = math.max(1.0, strip.width - whalePendantArt);
    final height = math.max(1.0, strip.height - whalePendantArt);
    var x = (settings.pendantX + delta.dx / width).clamp(0.0, 1.0);
    final y = (settings.pendantY - delta.dy / height).clamp(0.0, 1.0);
    // The two edges are a snap target: close enough and it parks flush there,
    // with the artwork's straight edge facing that edge.
    x = x < _snap
        ? 0.0
        : x > 1 - _snap
        ? 1.0
        : x;
    ref.read(settingsProvider.notifier).setPendantPlace(x, y);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    // Only the balance bubble needs the balance: watching it while the whale
    // is just art rebuilt this subtree every time something else refreshed it.
    final balance = _bubble == _Bubble.balance ? ref.watch(balanceProvider) : null;
    // The artwork is cut straight down its right edge, so that edge is the one
    // that has to sit against the screen edge: mirrored while on the left.
    final mirrored = settings.pendantX < 0.5;

    return LayoutBuilder(
      builder: (context, constraints) {
        final strip = Size(constraints.maxWidth, constraints.maxHeight);
        final bubble = switch (_bubble) {
          _Bubble.none => null,
          _Bubble.balance => _BalanceCard(state: balance!, mirrored: mirrored, onTap: _saySomething),
          _Bubble.line => _LineCard(line: _line ?? '', mirrored: mirrored, onTap: _saySomething),
        };

        // Only the character squashes and plays a clip: pressing a bubble
        // should not move her.
        final art = Listener(
          onPointerDown: (_) => _squeeze(down: true),
          onPointerUp: (_) => _squeeze(down: false),
          onPointerCancel: (_) => _squeeze(down: false),
          child: RepaintBoundary(
            child: ValueListenableBuilder<bool>(
              valueListenable: _squashed,
              builder: (context, squashed, child) => TweenAnimationBuilder<double>(
                tween: Tween<double>(end: squashed ? 1 : 0),
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutBack,
                builder: (context, squash, child) => Transform(
                  alignment: Alignment.bottomCenter,
                  transform: Matrix4.diagonal3Values(1 + 0.05 * squash, 1 - 0.12 * squash, 1),
                  child: child,
                ),
                child: child,
              ),
              child: SizedBox.square(dimension: whalePendantArt, child: _art(settings, mirrored)),
            ),
          ),
        );

        final body = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _showBalance,
          onPanStart: (_) => setState(() => _dragging = true),
          onPanUpdate: (details) => _dragOffset.value += details.delta,
          onPanEnd: (_) {
            setState(() => _dragging = false);
            _dragEnd(strip);
          },
          child: MouseRegion(
            cursor: _dragging ? SystemMouseCursors.grabbing : SystemMouseCursors.click,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: mirrored ? CrossAxisAlignment.start : CrossAxisAlignment.end,
              children: [
                if (bubble != null) ...[RepaintBoundary(child: bubble), const SizedBox(height: 10)],
                art,
              ],
            ),
          ),
        );

        return AnimatedSlide(
          offset: widget.aside ? const Offset(0, 1.4) : Offset.zero,
          duration: AppMotion.standard,
          curve: AppMotion.std,
          child: AnimatedOpacity(
            opacity: widget.aside ? 0 : 1,
            duration: AppMotion.standard,
            child: IgnorePointer(
              ignoring: widget.aside,
              child: Align(
                alignment: Alignment(
                  (settings.pendantX * 2 - 1).clamp(-1.0, 1.0),
                  (1 - settings.pendantY * 2).clamp(-1.0, 1.0),
                ),
                child: ValueListenableBuilder<Offset>(
                  valueListenable: _dragOffset,
                  builder: (context, drag, child) => Transform.translate(offset: drag, child: child),
                  child: MediaQuery(
                    // Catching the drag earlier than the page's own swipe is
                    // what keeps a sideways pull on the whale from turning the
                    // page; the pet wins its arena the same way.
                    data: MediaQuery.of(context)
                        .copyWith(gestureSettings: const DeviceGestureSettings(touchSlop: _dragSlop)),
                    child: body,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// The character: a built-in asset or the picked picture. A deleted custom
  /// file falls back to the built-in head rather than an error box.
  Widget _art(AppSettings settings, bool mirrored) {
    final custom = settings.pendantArtPath;
    if (settings.pendantArt == pendantArtCustom && custom.isNotEmpty) {
      return Image.file(
        File(custom),
        fit: BoxFit.contain,
        // Drawn at 62dp: decoding the full phone-camera picture would cost
        // tens of megabytes for pixels nobody sees.
        cacheWidth: 320,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, _, _) => _builtinArt(settings, mirrored),
      );
    }
    return _builtinArt(settings, mirrored);
  }

  Widget _builtinArt(AppSettings settings, bool mirrored) {
    final asset = pendantArtAsset(settings.pendantArt) ?? 'assets/pendant/whale_girl.png';
    return Transform.flip(
      flipX: mirrored,
      child: Image.asset(
        asset,
        fit: BoxFit.contain,
        cacheWidth: 320,
        filterQuality: FilterQuality.medium,
        excludeFromSemantics: true,
      ),
    );
  }
}

/// The balance: title, amount, and the price window it is charged at. Tapping
/// it swaps in one of the preset lines.
class _BalanceCard extends StatefulWidget {
  const _BalanceCard({required this.state, required this.mirrored, required this.onTap});

  final BalanceState state;
  final bool mirrored;
  final VoidCallback onTap;

  @override
  State<_BalanceCard> createState() => _BalanceCardState();
}

class _BalanceCardState extends State<_BalanceCard> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // The countdown moves once a second. Only this card rebuilds for it: the
    // whale and the rest of the chat stay out of the way.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final ink = theme.colorScheme.onSurface;
    final window = pendantPriceWindow(BalanceController.now());
    final balance = widget.state.balance;

    return GestureDetector(
      onTap: widget.onTap,
      child: _BubbleFrame(
        mirrored: widget.mirrored,
        width: _balanceWidth,
        height: _balanceHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              l10n.pendantBalance,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: ink.withValues(alpha: 0.75),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              balance == null ? '\u2014' : formatMoney(balance),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.headlineSmall?.copyWith(
                color: ink,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 4),
            _WindowPill(valley: window.valley, left: window.untilFlip),
          ],
        ),
      ),
    );
  }
}

/// A preset line on its own: no title, no amount, nothing but what she says.
class _LineCard extends StatelessWidget {
  const _LineCard({required this.line, required this.mirrored, required this.onTap});

  final String line;
  final bool mirrored;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = theme.colorScheme.onSurface;
    return GestureDetector(
      onTap: onTap,
      child: _BubbleFrame(
        mirrored: mirrored,
        width: _lineWidth,
        height: null,
        child: Text(
          line,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(color: ink, fontWeight: FontWeight.w600, height: 1.3),
        ),
      ),
    );
  }
}

/// The white thought bubble both cards sit in, with the two dots trailing
/// towards the character on the side it stands on.
class _BubbleFrame extends StatelessWidget {
  const _BubbleFrame({required this.mirrored, required this.width, required this.height, required this.child});

  final bool mirrored;
  final double width;
  final double? height;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = theme.colorScheme.onSurface;
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: ink.withValues(alpha: 0.85), width: 3),
                boxShadow: [
                  BoxShadow(
                    color: theme.colorScheme.shadow.withValues(alpha: 0.14),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            bottom: -13,
            right: mirrored ? null : 22,
            left: mirrored ? 22 : null,
            child: _Tail(ink: ink, size: 10),
          ),
          Positioned(
            bottom: -29,
            right: mirrored ? null : 8,
            left: mirrored ? 8 : null,
            child: _Tail(ink: ink, size: 6),
          ),
          Padding(padding: const EdgeInsets.fromLTRB(14, 10, 14, 10), child: child),
        ],
      ),
    );
  }
}

/// `谷 07:16:00` next to the amount: which price window applies and how long
/// until it flips.
class _WindowPill extends StatelessWidget {
  const _WindowPill({required this.valley, required this.left});

  final bool valley;
  final Duration left;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final color = valley ? const Color(0xFF2E9E4F) : theme.colorScheme.tertiary;
    return DecoratedBox(
      decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(7)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                child: Text(
                  valley ? l10n.pendantValley : l10n.pendantPeak,
                  style: theme.textTheme.labelSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(width: 5),
            Text(
              pendantCountdown(left),
              style: theme.textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
                fontFeatures: const [ui.FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Tail extends StatelessWidget {
  const _Tail({required this.ink, required this.size});

  final Color ink;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        shape: BoxShape.circle,
        border: Border.all(color: ink.withValues(alpha: 0.85), width: 2),
      ),
    );
  }
}
