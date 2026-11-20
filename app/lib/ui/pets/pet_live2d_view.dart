// The chat's Live2D pet: the companion's web stage (app/assets/companion/)
// with `mode=pet` — her room hidden, the model alone on a see-through page —
// driven by the pet's own state instead of her mood.
//
// The stage lives on a loopback server (CompanionServer) so the WebView can
// read the model files: `runtime/` comes from the installed companion pack
// (a pet pack carries no runtime of its own), `character/` from the pet's
// folder, and `character/character.json` + `character/index.json` are made up
// here from the pack's `live2d` section.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../companion/companion_server.dart';
import '../../pets/overlay_channel.dart';
import '../../pets/pet_pack.dart';
import '../../pets/pet_sheets.dart';
import '../../pets/pet_signals.dart';
import '../../pets/pet_state.dart';
import '../plugins/islands/island_platform.dart';
import '../web/web_view_guard.dart';

/// `<app support>/companion/pack/runtime`: the runtime a Live2D pet borrows.
final petLive2dRuntimeProvider = Provider<Future<Directory> Function()>(
  (ref) =>
      () async => Directory('${(await getApplicationSupportDirectory()).path}/companion/pack/runtime'),
);

/// How long a reaction's motion plays before the state's own comes back.
const petLive2dReactionMs = 1400;

/// Why a pet's stage could not draw (only logged; the poster stays).
const petLive2dStageFailed = 'pet live2d failed';

/// The pet's `character/` files plus the room's runtime, as one pack.
class PetLive2dPackSource implements CompanionPackSource {
  PetLive2dPackSource({required this.root, required this.runtime, required this.name, required this.config});

  /// The installed pet: `pack.json`, `poster.png`, `character/`.
  final Directory root;

  /// `<app support>/companion/pack/runtime` (may not exist).
  final Directory runtime;
  final String name;
  final PetLive2d config;

  List<String>? _characterFiles;

  @override
  Future<CompanionPackEntry?> open(String path) async {
    if (path == 'character/character.json') {
      final bytes = utf8.encode(jsonEncode({'schema': 1, 'name': name, 'model': config.model}));
      return CompanionPackEntry(bytes.length, () => Stream.value(bytes));
    }
    if (path == 'character/index.json') {
      final bytes = utf8.encode(jsonEncode(await _index()));
      return CompanionPackEntry(bytes.length, () => Stream.value(bytes));
    }
    if (path.startsWith('runtime/')) {
      return _entry(File('${runtime.path}/${path.substring('runtime/'.length)}'));
    }
    return _entry(File('${root.path}/$path'));
  }

  Future<List<String>> _index() async => _characterFiles ??= await _list();

  Future<List<String>> _list() async {
    final dir = Directory('${root.path}/character');
    if (!await dir.exists()) return const [];
    final names = <String>[];
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      names.add(entity.path.substring(dir.path.length + 1).replaceAll('\\', '/'));
    }
    names.sort();
    return names;
  }

  Future<CompanionPackEntry?> _entry(File file) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.file) return null;
    return CompanionPackEntry(await file.length(), file.openRead);
  }

  @override
  Future<void> close() async {}
}

/// Draws [pack]'s model; [child] is the still poster shown until it loads and
/// whenever it can't.
class PetLive2dView extends ConsumerStatefulWidget {
  const PetLive2dView({
    super.key,
    required this.pack,
    required this.state,
    required this.reaction,
    this.motion,
    this.expression,
    this.framing,
    this.paused = false,
    this.child,
  });

  final PetPack pack;
  final PetStateName state;

  /// A reaction key (`tapLeft`, `tickle`, …) to play once, then back.
  final String? reaction;

  /// Plays this motion instead of the state's own.
  ///
  /// The converter has no mapping yet when it previews a model's motions, so
  /// there is no state to name them through (live2d_convert_page.dart).
  final String? motion;

  /// One of the model's own expressions, held while it shows — the converter's
  /// expression preview (live2d_preview.dart). A pet never sets it.
  final String? expression;

  /// The room's framing (`zoom`, `x`, `y`), applied to the preview only: a pet
  /// draws the model alone and lets the stage size the canvas to it, while the
  /// converter wants to show how the same keys will place the model in her room
  /// (live2d_convert_page.dart). A pet never sets it.
  final Map<String, double>? framing;

  /// The pet is hidden or the page is not the visible one.
  final bool paused;
  final Widget? child;

  @override
  ConsumerState<PetLive2dView> createState() => _PetLive2dViewState();
}

class _PetLive2dViewState extends ConsumerState<PetLive2dView> with WidgetsBindingObserver {
  static const _readyTimeout = Duration(seconds: 30);

  /// The zoom the room starts from when a pack sets no framing (stage.js).
  static const _roomZoom = 1.2;

  CompanionServer? _server;
  WebViewController? _web;
  int? _webId;
  Timer? _timeout;
  Timer? _reactionTimer;
  bool _ready = false;
  bool _failed = false;
  bool _paused = false;
  String? _cue;
  AppLifecycleState? _lifecycle;

  /// The stage was asked for the still a model-only pack ships without.
  bool _posterAsked = false;

  /// That still is also this pack's first sight of the model: its size becomes
  /// the canvas and its body the content box (`.content-box-auto`).
  bool _calibrating = false;

  /// The longest side a poster is captured at: the pack rules allow 4096, and
  /// no pet is drawn anywhere near it.
  static const _posterSide = 2048;

  PetLive2d? get _config => widget.pack.live2d;

  @override
  void initState() {
    super.initState();
    _lifecycle = WidgetsBinding.instance.lifecycleState;
    WidgetsBinding.instance.addObserver(this);
    _paused = widget.paused || _background;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_start());
    });
  }

  bool get _background => _lifecycle != null && _lifecycle != AppLifecycleState.resumed;

  @override
  void didUpdateWidget(PetLive2dView old) {
    super.didUpdateWidget(old);
    if (old.pack != widget.pack) {
      _posterAsked = false;
      _calibrating = false;
      unawaited(_restart());
      return;
    }
    if (old.state != widget.state) {
      _reactionTimer?.cancel();
      _cue = null;
      _send('state', {'name': _stateMotion()});
    } else if (old.motion != widget.motion) {
      // Another motion of the same model: the stage swaps it in place.
      _reactionTimer?.cancel();
      _cue = null;
      _send('state', {'name': _stateMotion()});
    } else if (old.expression != widget.expression) {
      _sendExpression();
    } else if (old.reaction != widget.reaction && widget.reaction != null) {
      _cue = _motionFor();
      _send('state', {'name': _cue});
      _reactionTimer?.cancel();
      _reactionTimer = Timer(const Duration(milliseconds: petLive2dReactionMs), () {
        if (!mounted) return;
        _cue = null;
        _send('state', {'name': _stateMotion()});
      });
    } else if (_cue == null) {
      _send('state', {'name': _stateMotion()});
    }
    _syncPause();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    _syncPause();
  }

  String _stateMotion() {
    if (widget.motion case final motion?) return motion;
    final config = _config;
    if (config == null) return '';
    return config.states[widget.state.name] ?? config.states[PetStateName.idle.name] ?? config.fallback ?? '';
  }

  String _motionFor() {
    final config = _config;
    if (config == null) return '';
    final key = widget.reaction;
    return (key == null ? null : config.reactions[key]) ?? _stateMotion();
  }

  /// Holds [PetLive2dView.expression] on the stage; the expression preview is
  /// the only caller, and it wants it to stay, not relax back to calm.
  void _sendExpression() {
    final expression = widget.expression;
    if (expression == null) return;
    _send('emotion', {'name': expression, 'hold': const Duration(hours: 1).inMilliseconds});
  }

  void _syncPause() {
    final paused = widget.paused || _background;
    if (_paused == paused) return;
    _paused = paused;
    _send(paused ? 'pause' : 'resume');
    if (!paused && _ready) {
      // `pause` stops every motion; put the current one back.
      _send('state', {'name': _cue ?? _stateMotion()});
    }
  }

  Future<void> _restart() async {
    _reactionTimer?.cancel();
    _timeout?.cancel();
    if (mounted) setState(() => _ready = false);
    await _teardown();
    if (mounted) unawaited(_start());
  }

  Future<void> _teardown() async {
    final id = _webId;
    _webId = null;
    final web = _web;
    if (web != null && mounted) setState(() => _web = null);
    if (id != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(IslandPlatform.instance.destroy(id)));
    }
    await _server?.close();
    _server = null;
  }

  Future<void> _start() async {
    final dir = widget.pack.dir;
    final config = _config;
    if (dir == null || config == null) {
      _fail('no-pack');
      return;
    }
    try {
      final runtime = await ref.read(petLive2dRuntimeProvider)();
      final server = await CompanionServer.startWith(
        rootBundle,
        PetLive2dPackSource(root: Directory(dir), runtime: runtime, name: widget.pack.name, config: config),
      );
      if (!mounted) {
        await server.close();
        return;
      }
      _server = server;
      final web = WebViewController(onPermissionRequest: (request) => unawaited(request.deny()));
      await web.setJavaScriptMode(JavaScriptMode.unrestricted);
      await web.setBackgroundColor(const Color(0x00000000));
      await web.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) =>
              server.ownsUrl(request.url) ? NavigationDecision.navigate : NavigationDecision.prevent,
          onWebResourceError: (error) {
            if (error.isForMainFrame ?? false) _fail('load');
          },
        ),
      );
      await web.addJavaScriptChannel('DshCompanion', onMessageReceived: (m) => _onMessage(m.message));
      final id = defaultTargetPlatform == TargetPlatform.android ? WebViewGuard.identifierOf(web) : null;
      if (id != null) {
        if (!await IslandPlatform.instance.attach(id, dark: false, textZoom: 100)) {
          _fail('guard');
          return;
        }
        _webId = id;
      }
      if (!mounted) return;
      setState(() => _web = web);
      _timeout = Timer(_readyTimeout, () => _fail('timeout'));
      final framing = widget.framing;
      await web.loadRequest(
        server.pageUrl(
          query: {
            'mode': 'pet',
            if (framing != null) 'roomZoom': '${framing['zoom'] ?? _roomZoom}',
            if (framing != null) 'roomX': '${framing['x'] ?? 0}',
            if (framing != null) 'roomY': '${framing['y'] ?? 0}',
          },
        ),
      );
    } on Object catch (error) {
      _fail('$error');
    }
  }

  void _onMessage(String raw) {
    if (!mounted || _failed) return;
    final Object? message;
    try {
      message = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (message is! Map) return;
    switch (message['type']) {
      case 'ready':
        _timeout?.cancel();
        setState(() => _ready = true);
        _syncPause();
        _send('state', {'name': _motionFor()});
        _sendExpression();
        unawaited(_capturePoster());
      case 'poster':
        unawaited(_savePoster(message));
      case 'error':
        _fail('${message['message']}');
    }
  }

  /// A model-only pack got a blank poster on import: the stage draws the
  /// model, so the first frame it draws is the still every sprite-only surface
  /// needs (the floating window, the grids). A pack the converter wrote also
  /// gets its canvas proportions and body box from that frame — nobody had
  /// seen the model when the zip was built (`.content-box-auto`).
  Future<void> _capturePoster() async {
    final dir = widget.pack.dir;
    if (dir == null || _posterAsked) return;
    if (!File('$dir/$posterPendingName').existsSync()) return;
    _posterAsked = true;
    _calibrating = File('$dir/$contentBoxAutoName').existsSync();
    if (_calibrating) {
      // The model's own proportions: a still at the guessed aspect would bake
      // the stretch into the floating window for good.
      _send('poster', {'fit': 'model', 'w': _posterSide, 'h': _posterSide});
      return;
    }
    final canvas = widget.pack.canvas;
    _send('poster', {'w': canvas.width.round(), 'h': canvas.height.round()});
  }

  Future<void> _savePoster(Map<Object?, Object?> message) async {
    final dir = widget.pack.dir;
    final data = message['data'];
    if (dir == null || data is! String) return;
    final comma = data.indexOf(',');
    if (comma < 0) return;
    final Uint8List bytes;
    try {
      bytes = base64Decode(data.substring(comma + 1));
    } on FormatException {
      return;
    }
    final width = (message['w'] as num?)?.round() ?? widget.pack.canvas.width.round();
    final height = (message['h'] as num?)?.round() ?? widget.pack.canvas.height.round();
    if (width < 1 || height < 1 || width > _posterSide || height > _posterSide) return;
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: width, targetHeight: height);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final box = _calibrating ? await _bodyBox(image) : null;
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    codec.dispose();
    if (png == null) return;
    final staging = File('$dir/poster.png.new');
    try {
      await staging.writeAsBytes(png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes), flush: true);
      if (box != null) {
        // The canvas is rewritten with the poster: a poster that no longer
        // matches it is a pack the importer rejects on the next start.
        await _writeBodyBox(dir, width: width, height: height, box: box);
        await File('$dir/$contentBoxAutoName').delete();
      }
      await staging.rename('$dir/poster.png');
      await File('$dir/$posterPendingName').delete();
    } on FileSystemException {
      // Read-only storage (a backup restored it so): the blank stays.
      try {
        await staging.delete();
      } on FileSystemException {
        // nothing to undo
      }
      return;
    }
    PetSheets.instance.forget(widget.pack.id);
    if (box != null) ref.invalidate(petPackProvider(widget.pack.id));
    unawaited(ref.read(petOverlayChannelProvider).reloadPack(widget.pack.id));
  }

  /// The opaque part of the first frame, in its own pixels: columns and rows
  /// holding enough solid pixels to be the figure rather than a wisp of the
  /// moon behind her.
  Future<({int left, int top, int width, int height})?> _bodyBox(ui.Image image) async {
    final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (raw == null) return null;
    final pixels = raw.buffer.asUint8List(raw.offsetInBytes, raw.lengthInBytes);
    final w = image.width;
    final h = image.height;
    final rows = List<int>.filled(h, 0);
    final cols = List<int>.filled(w, 0);
    for (var y = 0; y < h; y++) {
      final base = y * w * 4;
      for (var x = 0; x < w; x++) {
        if (pixels[base + x * 4 + 3] < 250) continue;
        rows[y]++;
        cols[x]++;
      }
    }
    final rowFloor = math.max(2, (w * 0.01).round());
    final colFloor = math.max(2, (h * 0.01).round());
    int? top;
    for (var y = 0; y < h; y++) {
      if (rows[y] < rowFloor) continue;
      top = y;
      break;
    }
    if (top == null) return null;
    var bottom = top;
    for (var y = h - 1; y >= top; y--) {
      if (rows[y] < rowFloor) continue;
      bottom = y;
      break;
    }
    int? left;
    for (var x = 0; x < w; x++) {
      if (cols[x] < colFloor) continue;
      left = x;
      break;
    }
    if (left == null) return null;
    var right = left;
    for (var x = w - 1; x >= left; x--) {
      if (cols[x] < colFloor) continue;
      right = x;
      break;
    }
    return (left: left, top: top, width: right - left + 1, height: bottom - top + 1);
  }

  /// pack.json with the frame's proportions and the body's box: the pet then
  /// stands on its perch at its own size (petScale reads `contentBox.height`),
  /// and taps land on the body rather than on an empty margin.
  Future<void> _writeBodyBox(
    String dir, {
    required int width,
    required int height,
    required ({int left, int top, int width, int height}) box,
  }) async {
    final file = File('$dir/pack.json');
    final text = await file.readAsString();
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      return;
    }
    if (json is! Map<String, Object?>) return;
    json['canvas'] = {'w': width, 'h': height};
    json['contentBox'] = {'x': box.left, 'y': box.top, 'w': box.width, 'h': box.height};
    json['anchor'] = {
      'x': (box.left + box.width ~/ 2).clamp(0, width),
      'baseline': (box.top + box.height).clamp(0, height),
    };
    await file.writeAsString('${const JsonEncoder.withIndent('  ').convert(json)}\n', flush: true);
  }

  void _send(String type, [Map<String, Object?> args = const {}]) {
    final web = _web;
    if (web == null || !_ready) return;
    unawaited(web.runJavaScript('stage.command(${jsonEncode({'type': type, ...args})})').catchError((Object _) {}));
  }

  void _fail(String why) {
    _timeout?.cancel();
    if (kDebugMode) debugPrint('[$petLive2dStageFailed] $why');
    if (mounted) {
      setState(() {
        _ready = false;
        _failed = true;
      });
    }
    // Keep the poster: stop the page and free its loopback port.
    unawaited(_teardown());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timeout?.cancel();
    _reactionTimer?.cancel();
    final id = _webId;
    _webId = null;
    unawaited(_server?.close() ?? Future<void>.value());
    if (id != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(IslandPlatform.instance.destroy(id)));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final web = _web;
    return Stack(
      fit: StackFit.expand,
      children: [
        // The poster fades out once the stage draws: its page is see-through
        // and the model keeps moving, so a still left behind it reads as a
        // second silhouette (a doubled outline at the feet).
        if (widget.child != null)
          AnimatedOpacity(opacity: _ready ? 0 : 1, duration: const Duration(milliseconds: 220), child: widget.child!),
        if (web != null && !_failed)
          IgnorePointer(
            child: AnimatedOpacity(
              opacity: _ready ? 1 : 0,
              duration: const Duration(milliseconds: 220),
              child: WebViewWidget(
                controller: web,
                gestureRecognizers: {Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new)},
              ),
            ),
          ),
      ],
    );
  }
}
