// 设置 › 宠物 › 转换 Live2D 模型: a third-party model folder (a zip) turned into
// a pet pack or a companion-room pack, without an AI in the loop. The stages
// are the work: pick the zip, read what the model can do, say which of her
// states play which of its motions (live2d_kit.dart explains the naming), and
// build the pack. What a model cannot do is said out loud — the pack the app
// installs maps only the states someone chose, and the rest stay unimplemented.

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../companion/companion_adapt_contract.dart';
import '../../companion/companion_float.dart';
import '../../companion/companion_pack.dart';
import '../../l10n/l10n.dart';
import '../../pets/live2d_kit.dart';
import '../../pets/pet_library.dart';
import '../../pets/pet_pack.dart';
import '../../pets/pet_prefs.dart';
import '../../pets/pet_signals.dart';
import '../../state/artifacts.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import 'live2d_preview.dart';
import 'pet_picker.dart' show petImportProblemText;

class Live2dConvertPage extends ConsumerStatefulWidget {
  const Live2dConvertPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const Live2dConvertPage());

  @override
  ConsumerState<Live2dConvertPage> createState() => _Live2dConvertPageState();
}

class _Live2dConvertPageState extends ConsumerState<Live2dConvertPage> {
  Live2dKitReport? _report;
  Map<String, String?> _mapping = const {};
  Map<String, String?> _emotions = const {};
  Map<String, String?> _actions = const {};
  _Target _target = _Target.pet;
  String? _problem;
  String? _saved;
  bool _busy = false;

  /// The room pack just built, kept on disk so it can be installed from here
  /// without a trip through Downloads (companion_pack.dart).
  File? _roomZip;

  /// Whether this phone already has a companion runtime to carry into a pack.
  bool _runtimeInstalled = false;
  bool _runtimeChecked = false;
  bool _bundleRuntime = true;

  /// The room's camera, written into `character.json` as `framing`: the stage's
  /// own keys, so a pack places its model the way this page showed it. The
  /// defaults are the room's (`stage.js`), not zeroes.
  static const _defaultZoom = 1.2;
  double _zoom = _defaultZoom;
  double _offsetX = 0;
  double _offsetY = 0;

  Map<String, double> get _framing => {'zoom': _zoom, 'x': _offsetX, 'y': _offsetY};

  /// Brings the result section — the page's last one — into view once the build
  /// that produced it has laid out. Without it the row lands below the fold and
  /// only its top edge shows.
  final _resultKey = GlobalKey();

  void _revealResult() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _resultKey.currentContext;
      if (target == null || !mounted) return;
      unawaited(
        Scrollable.ensureVisible(
          target,
          alignment: 0,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  /// The zip that was picked, in bytes, when it is past what the converter
  /// reads. Shown as advice ("make it smaller first") instead of an error.
  int? _tooLarge;

  @override
  void initState() {
    super.initState();
    unawaited(_checkRuntime());
  }

  @override
  void dispose() {
    _dropRoomZip();
    super.dispose();
  }

  void _dropRoomZip() {
    final zip = _roomZip;
    _roomZip = null;
    if (zip != null) unawaited(zip.delete().catchError((Object _) => zip));
  }

  /// The runtime a room pack may carry: whatever companion pack is installed.
  Future<void> _checkRuntime() async {
    var installed = false;
    try {
      final store = await ref.read(companionFloatStoreProvider)();
      installed = await store.installed();
    } on Object {
      installed = false;
    }
    if (!mounted) return;
    setState(() {
      _runtimeInstalled = installed;
      _runtimeChecked = true;
    });
  }

  Future<Directory?> _runtimeDir() async {
    try {
      final store = await ref.read(companionFloatStoreProvider)();
      return Directory('${store.pack.path}/runtime');
    } on Object {
      return null;
    }
  }

  Future<void> _pick() async {
    if (_busy) return;
    final l10n = context.l10n;
    setState(() {
      _busy = true;
      _problem = null;
      _saved = null;
      _tooLarge = null;
      _dropRoomZip();
    });
    File? temp;
    try {
      final picked = await FilePicker.pickFile();
      if (picked == null || !mounted) return;
      temp = File('${(await getTemporaryDirectory()).path}/live2d-model-${DateTime.now().microsecondsSinceEpoch}.zip');
      final sink = temp.openWrite();
      try {
        await sink.addStream(picked.readAsByteStream());
      } finally {
        await sink.close();
      }
      // Asked before the kit reads a byte: a model past the cap costs the phone
      // more memory than it has, and "make it smaller" is the answer either way.
      final length = await temp.length();
      if (length > Live2dKit.inspectByteCap) {
        if (mounted) setState(() => _tooLarge = length);
        return;
      }
      final report = await Live2dKit.inspect(temp.path);
      if (!mounted) return;
      setState(() {
        _report = report;
        _mapping = report.suggestion;
        _emotions = Live2dKit.suggestRoomEmotions(report);
        _actions = Live2dKit.suggestRoomActions(report);
        _problem = report.motions.isEmpty ? l10n.botsPetConvertNoMotions : null;
      });
    } on Live2dKitException catch (error) {
      if (!mounted) return;
      if (error.code == 'too-large') {
        setState(() => _tooLarge = temp?.lengthSync() ?? 0);
      } else {
        setState(() => _problem = l10n.botsPetConvertFailed('${error.code} ${error.detail ?? ''}'.trim()));
      }
    } on FileSystemException catch (error) {
      if (mounted) setState(() => _problem = l10n.botsPetConvertFailed(error.message));
    } finally {
      final file = temp;
      if (file != null) await file.delete().catchError((Object _) => file);
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Plays one motion before it is mapped to anything (live2d_preview.dart).
  Future<void> _preview(String motion) => Live2dPreviewSheet.show(context, report: _report!, motion: motion);

  /// Shows one of the model's expressions on the stage, so a name can be
  /// matched to a face instead of guessed.
  /// Previews one expression on the model, on the motion its idle state would
  /// play, so the face is shown the way the companion will show it.
  Future<void> _previewExpression(String expression) {
    final report = _report!;
    final motion = report.suggestion['idle'] ?? (report.motions.isEmpty ? '' : report.motions.first.key);
    return Live2dPreviewSheet.show(context, report: report, motion: motion, expression: expression);
  }

  /// Shows the model where and at what size the room will draw it.
  Future<void> _previewFraming() {
    final report = _report!;
    final motion = report.suggestion['idle'] ?? (report.motions.isEmpty ? '' : report.motions.first.key);
    return Live2dPreviewSheet.show(context, report: report, motion: motion, framing: _framing);
  }

  void _resetFraming() => setState(() {
    _zoom = _defaultZoom;
    _offsetX = 0;
    _offsetY = 0;
  });

  String _offsetLabel(double value) => value.abs() < 0.005 ? '0' : '${value > 0 ? '+' : ''}${value.toStringAsFixed(2)}';

  Future<void> _copyPrompt() async {
    final l10n = context.l10n;
    await Clipboard.setData(ClipboardData(text: l10n.botsPetConvertTooLargePrompt));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.botsPetConvertTooLargeCopied)));
  }

  Future<void> _choose(String key) async {
    final report = _report;
    if (report == null) return;
    final picked = await showModalBottomSheet<String?>(
      context: context,
      builder: (context) => _MotionSheet(report: report, selected: _mapping[key], onPreview: _preview),
    );
    if (picked == null || !mounted) return;
    setState(() => _mapping = {..._mapping, key: picked.isEmpty ? null : picked});
  }

  Future<void> _swap() async {
    final first = await _pickState(title: context.l10n.botsPetConvertSwapPick, exclude: null);
    if (first == null || !mounted) return;
    final second = await _pickState(title: context.l10n.botsPetConvertSwapPick2(first), exclude: first);
    if (second == null || !mounted) return;
    setState(() {
      final next = {..._mapping};
      final carried = next[first];
      next[first] = next[second];
      next[second] = carried;
      _mapping = next;
    });
  }

  Future<String?> _pickState({required String title, required String? exclude}) async {
    final report = _report;
    if (report == null) return null;
    return showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(padding: const EdgeInsets.fromLTRB(20, 18, 20, 8), child: Text(title)),
            for (final key in _stateKeys)
              if (key != exclude)
                SettingsTile(
                  title: _stateName(key),
                  value: Text(_mapping[key] ?? context.l10n.botsPetConvertNone),
                  onTap: () => Navigator.of(context).pop(key),
                ),
          ],
        ),
      ),
    );
  }

  Future<void> _build() async {
    final report = _report;
    if (report == null || _busy) return;
    final l10n = context.l10n;
    final pet = _target == _Target.pet;
    setState(() {
      _busy = true;
      _problem = null;
      _saved = null;
    });
    try {
      if (pet) {
        final problems = Live2dKit.mappingProblems(report, _mapping);
        final blocking = problems.where((problem) => !problem.startsWith('motions-ignored:')).toList();
        if (blocking.isNotEmpty) {
          setState(() {
            _problem = blocking.first.startsWith('idle-missing:')
                ? l10n.botsPetConvertNeedIdle
                : l10n.botsPetConvertMapping(_sentence(blocking.first));
          });
          return;
        }
      }
      // The switch is off, and disabled, while this phone has no runtime, so a
      // toggle nobody could flip never fails the build halfway through.
      final runtime = !pet && _bundleRuntime && _runtimeInstalled
          ? await _runtimeFiles() ?? const <String, Uint8List>{}
          : const <String, Uint8List>{};
      final bytes = pet
          ? await Live2dKit.buildPet(report, _mapping)
          : await Live2dKit.buildRoom(
              report,
              emotions: _emotions,
              actions: _actions,
              framing: _framing,
              runtime: runtime,
            );
      final temp = File(
        '${(await getTemporaryDirectory()).path}/live2d-${pet ? 'pet' : 'room'}-${DateTime.now().microsecondsSinceEpoch}.zip',
      );
      await temp.writeAsBytes(bytes, flush: true);
      if (!mounted) {
        await temp.delete().catchError((Object _) => temp);
        return;
      }
      if (pet) {
        final (:pack, :replaced) = await ref.read(userPetsProvider.notifier).import(temp);
        // The pack's canvas and content box are guesses: the first frame the
        // stage draws rewrites both (pet_live2d_view.dart).
        final folder = await ref.read(petLibraryProvider).folder(pack.id);
        await File('${folder.path}/$contentBoxAutoName').writeAsString('1', flush: true);
        await ref.read(petPrefsProvider.notifier).setPack(pack.id);
        if (!mounted) return;
        setState(
          () => _saved = replaced ? l10n.botsPetImportReplaced(pack.name) : l10n.botsPetConvertPetDone(pack.name),
        );
        _revealResult();
        await temp.delete().catchError((Object _) => temp);
      } else {
        // Saved to Downloads as a portable copy, and kept on disk so it can
        // also be installed straight into the companion from here.
        final where = await ref
            .read(filesChannelProvider)
            .saveToDownloads(temp.path, name: '${report.model.name}-room.zip', mime: 'application/zip');
        if (!mounted) return;
        _dropRoomZip();
        setState(() {
          _roomZip = temp;
          _saved = l10n.botsPetConvertRoomDone(where);
        });
        _revealResult();
      }
    } on PetImportException catch (error) {
      if (mounted) setState(() => _problem = petImportProblemText(l10n, error));
    } on Live2dKitException catch (error) {
      if (mounted) setState(() => _problem = l10n.botsPetConvertFailed('${error.code} ${error.detail ?? ''}'.trim()));
    } on CompanionPackException catch (error) {
      if (mounted) setState(() => _problem = l10n.botsPetConvertFailed(error.problem.name));
    } on Object catch (error) {
      if (mounted) setState(() => _problem = l10n.botsPetConvertFailed('$error'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Reads the installed companion runtime, or says why it is missing.
  Future<Map<String, Uint8List>?> _runtimeFiles() async {
    final dir = await _runtimeDir();
    if (dir == null) return null;
    return Live2dKit.readRuntime(dir);
  }

  /// Installs the room pack that was just built, which also brings the runtime
  /// a character-only pack leans on (companion_pack.dart).
  Future<void> _installRoom() async {
    final zip = _roomZip;
    final report = _report;
    if (zip == null || report == null || _busy) return;
    final l10n = context.l10n;
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      final store = await ref.read(companionFloatStoreProvider)();
      await store.install(zip.path);
      await _checkRuntime();
      if (!mounted) return;
      setState(() => _saved = l10n.botsPetConvertRoomImported(report.model.name));
      _revealResult();
    } on CompanionPackException catch (error) {
      if (mounted) {
        setState(
          () => _problem = error.problem == CompanionPackProblem.noRuntime
              ? l10n.botsPetConvertRuntimeMissing
              : l10n.botsPetConvertFailed(error.problem.name),
        );
      }
    } on Object catch (error) {
      if (mounted) setState(() => _problem = l10n.botsPetConvertFailed('$error'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Imports a ready-made companion pack from the phone: the usual way to get
  /// a runtime when this device has never had one.
  Future<void> _importRuntime() async {
    if (_busy) return;
    final l10n = context.l10n;
    setState(() {
      _busy = true;
      _problem = null;
    });
    File? temp;
    try {
      final picked = await FilePicker.pickFile();
      if (picked == null || !mounted) return;
      temp = File(
        '${(await getTemporaryDirectory()).path}/companion-pack-${DateTime.now().microsecondsSinceEpoch}.zip',
      );
      final sink = temp.openWrite();
      try {
        await sink.addStream(picked.readAsByteStream());
      } finally {
        await sink.close();
      }
      final store = await ref.read(companionFloatStoreProvider)();
      await store.install(temp.path);
      await _checkRuntime();
      if (!mounted) return;
      setState(() => _saved = l10n.botsPetConvertRuntimeDone);
      _revealResult();
    } on CompanionPackException catch (error) {
      if (mounted) setState(() => _problem = l10n.botsPetConvertFailed(error.problem.name));
    } on Object catch (error) {
      if (mounted) setState(() => _problem = l10n.botsPetConvertFailed('$error'));
    } finally {
      final file = temp;
      if (file != null) await file.delete().catchError((Object _) => file);
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseExpression(String key) async {
    final report = _report;
    if (report == null) return;
    final picked = await showModalBottomSheet<String?>(
      context: context,
      builder: (context) => _ExpressionSheet(report: report, selected: _emotions[key], onPreview: _previewExpression),
    );
    if (picked == null || !mounted) return;
    setState(() => _emotions = {..._emotions, key: picked.isEmpty ? null : picked});
  }

  Future<void> _chooseAction(String key) async {
    final report = _report;
    if (report == null) return;
    final picked = await showModalBottomSheet<String?>(
      context: context,
      builder: (context) => _MotionSheet(report: report, selected: _actions[key], onPreview: _preview),
    );
    if (picked == null || !mounted) return;
    setState(() => _actions = {..._actions, key: picked.isEmpty ? null : picked});
  }

  String _stateName(String key) => switch (key) {
    'idle' => context.l10n.botsPetStateIdle,
    'thinking' => context.l10n.botsPetStateThinking,
    'working' => context.l10n.botsPetStateWorking,
    'juggling' => context.l10n.botsPetStateJuggling,
    'sweeping' => context.l10n.botsPetStateSweeping,
    'notification' => context.l10n.botsPetStateNotification,
    'attention' => context.l10n.botsPetStateAttention,
    'error' => context.l10n.botsPetStateError,
    'carrying' => context.l10n.botsPetStateCarrying,
    'sleeping' => context.l10n.botsPetStateSleeping,
    'waking' => context.l10n.botsPetStateWaking,
    'tapLeft' => context.l10n.botsPetReactionTapLeft,
    'tapRight' => context.l10n.botsPetReactionTapRight,
    'tickle' => context.l10n.botsPetReactionTickle,
    'annoyed' => context.l10n.botsPetReactionAnnoyed,
    _ => context.l10n.botsPetReactionDrag,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final report = _report;
    final pet = _target == _Target.pet;
    final missing = report == null
        ? const <String>[]
        : [
            for (final key in [..._stateKeys, ..._reactionKeys])
              if (_mapping[key] == null) _stateName(key),
          ];
    final used = _mapping.values.whereType<String>().toSet();
    final unused = report?.motions.where((motion) => !used.contains(motion.key)).length ?? 0;
    final result = _saved != null || _roomZip != null;
    return AppPage.list(
      title: l10n.botsPetConvertEntry,
      children: [
        SettingsSection(
          footer: Text(l10n.botsPetConvertPickHint),
          children: [
            SettingsTile(
              icon: AppIcons.files,
              title: l10n.botsPetConvertPick,
              subtitle: report == null ? l10n.botsPetConvertPickSubtitle : report.model.name,
              onTap: _pick,
            ),
          ],
        ),
        if (_busy)
          SettingsSection(children: [SettingsTile(title: l10n.botsPetConvertWorking, chevron: false, onTap: null)]),
        if (_tooLarge case final bytes?)
          SettingsSection(
            title: l10n.botsPetConvertTooLarge(_size(context, bytes)),
            footer: Text(l10n.botsPetConvertTooLargeHint(_size(context, Live2dKit.inspectByteCap))),
            children: [
              SettingsTile(
                icon: AppIcons.files,
                title: l10n.botsPetConvertPick,
                subtitle: l10n.botsPetConvertPickSubtitle,
                onTap: _busy ? null : _pick,
              ),
              SettingsTile(icon: AppIcons.skill, title: l10n.botsPetConvertTooLargeCopy, onTap: _copyPrompt),
            ],
          ),
        if (_problem case final problem?)
          SettingsSection(children: [SettingsTile(title: problem, danger: true, chevron: false)]),
        if (report != null) ...[
          SettingsSection(
            title: l10n.botsPetConvertModel,
            children: [
              SettingsTile(
                title: l10n.botsPetConvertFiles,
                value: Text(l10n.botsPetConvertCount(report.model.files.length, _size(context, report.totalBytes))),
                chevron: false,
              ),
              SettingsTile(
                title: l10n.botsPetConvertTextures,
                value: Text('${report.textures.length}'),
                chevron: false,
              ),
              SettingsTile(title: l10n.botsPetConvertMotions, value: Text('${report.motions.length}'), chevron: false),
              SettingsTile(
                title: l10n.botsPetConvertExpressions,
                value: Text('${report.expressions.length}'),
                chevron: false,
              ),
            ],
          ),
          // Two targets: a desktop pet is driven by app states, the companion
          // by what the character says. They need different packs.
          SettingsSection(
            title: l10n.botsPetConvertTarget,
            footer: Text(l10n.botsPetConvertTargetHint),
            children: [
              SettingsTile(
                icon: AppIcons.image,
                title: l10n.botsPetConvertTargetPet,
                value: pet ? const Icon(AppIcons.selected, size: 18) : null,
                onTap: () => setState(() => _target = _Target.pet),
              ),
              SettingsTile(
                icon: AppIcons.chat,
                title: l10n.botsPetConvertTargetRoom,
                value: pet ? null : const Icon(AppIcons.selected, size: 18),
                onTap: () => setState(() => _target = _Target.room),
              ),
            ],
          ),
          if (pet) ...[
            if (report.motions.isNotEmpty)
              SettingsSection(
                title: l10n.botsPetConvertMotionList,
                children: [
                  for (final motion in report.motions)
                    SettingsTile(
                      title: motion.key,
                      subtitle: motion.gesture ? null : l10n.botsPetConvertPhysicsOnly,
                      value: Text(
                        '${motion.duration.toStringAsFixed(1)}s ${motion.loop ? l10n.botsPetConvertLoop : l10n.botsPetConvertOnce}',
                      ),
                      trailing: IconButton(
                        onPressed: () => _preview(motion.key),
                        icon: const Icon(AppIcons.play, size: 20),
                        tooltip: l10n.botsPetConvertPreview,
                      ),
                      chevron: false,
                    ),
                ],
              ),
            SettingsSection(
              title: l10n.botsPetConvertMap,
              footer: Text(
                missing.isEmpty ? l10n.botsPetConvertMapDone : l10n.botsPetConvertMissing(missing.join('、')),
              ),
              children: [
                for (final key in _stateKeys)
                  SettingsTile(
                    title: _stateName(key),
                    value: Text(_mapping[key] ?? l10n.botsPetConvertNone),
                    onTap: () => _choose(key),
                  ),
              ],
            ),
            SettingsSection(
              title: l10n.botsPetConvertEvents,
              children: [
                for (final key in _reactionKeys)
                  SettingsTile(
                    title: _stateName(key),
                    value: Text(_mapping[key] ?? l10n.botsPetConvertNone),
                    onTap: () => _choose(key),
                  ),
              ],
            ),
            SettingsSection(
              footer: switch (report.motions.length) {
                0 => Text(l10n.botsPetConvertNoMotions),
                _ => unused == 0 ? null : Text(l10n.botsPetConvertIgnored(unused)),
              },
              children: [
                SettingsTile(
                  icon: AppIcons.skill,
                  title: l10n.botsPetConvertAuto,
                  onTap: () => setState(() => _mapping = report.suggestion),
                ),
                SettingsTile(icon: AppIcons.swap, title: l10n.botsPetConvertSwap, onTap: _swap),
              ],
            ),
          ] else ...[
            SettingsSection(
              title: l10n.botsPetConvertRoomEmotions,
              footer: Text(
                report.expressions.isEmpty ? l10n.botsPetConvertRoomNoExpressions : l10n.botsPetConvertRoomEmotionsHint,
              ),
              children: [
                for (final key in companionAdaptEmotions)
                  SettingsTile(
                    title: _emotionLabel(key),
                    subtitle: _subtitle(key, _expressionFile(report, _emotions[key])),
                    value: Text(_emotions[key] ?? l10n.botsPetConvertExpressionNone),
                    onTap: report.expressions.isEmpty ? null : () => _chooseExpression(key),
                  ),
              ],
            ),
            SettingsSection(
              title: l10n.botsPetConvertRoomActions,
              footer: Text(l10n.botsPetConvertRoomActionsHint),
              children: [
                for (final key in companionAdaptActions)
                  SettingsTile(
                    title: _actionLabel(key),
                    subtitle: _subtitle(key, _motionFile(report, _actions[key])),
                    value: Text(_actions[key] ?? l10n.botsPetConvertNone),
                    onTap: () => _chooseAction(key),
                  ),
              ],
            ),
            SettingsSection(
              title: l10n.botsPetConvertFraming,
              footer: Text(l10n.botsPetConvertFramingHint),
              children: [
                _FramingSlider(
                  title: l10n.botsPetConvertFramingZoom,
                  value: _zoom,
                  min: 0.6,
                  max: 2.2,
                  label: (value) => '${value.toStringAsFixed(2)}×',
                  onChanged: (value) => setState(() => _zoom = value),
                ),
                _FramingSlider(
                  title: l10n.botsPetConvertFramingX,
                  value: _offsetX,
                  min: -1,
                  max: 1,
                  label: _offsetLabel,
                  onChanged: (value) => setState(() => _offsetX = value),
                ),
                _FramingSlider(
                  title: l10n.botsPetConvertFramingY,
                  value: _offsetY,
                  min: -1,
                  max: 1,
                  label: _offsetLabel,
                  onChanged: (value) => setState(() => _offsetY = value),
                ),
                SettingsTile(icon: AppIcons.play, title: l10n.botsPetConvertFramingPreview, onTap: _previewFraming),
                SettingsTile(icon: AppIcons.swap, title: l10n.botsPetConvertFramingReset, onTap: _resetFraming),
              ],
            ),
            SettingsSection(
              title: l10n.botsPetConvertRuntime,
              footer: Text(_runtimeInstalled ? l10n.botsPetConvertRuntimeReady : l10n.botsPetConvertRuntimeMissing),
              children: [
                SettingsSwitchTile(
                  icon: AppIcons.folder,
                  title: l10n.botsPetConvertRuntimeBundle,
                  subtitle: l10n.botsPetConvertRuntimeBundleHint,
                  value: _bundleRuntime && _runtimeInstalled,
                  onChanged: _runtimeChecked && _runtimeInstalled
                      ? (value) => setState(() => _bundleRuntime = value)
                      : null,
                ),
                SettingsTile(
                  icon: AppIcons.download,
                  title: l10n.botsPetConvertRuntimeImport,
                  subtitle: l10n.botsPetConvertRuntimeImportHint,
                  onTap: _busy ? null : _importRuntime,
                ),
              ],
            ),
          ],
          SettingsSection(
            children: [
              SettingsTile(
                icon: pet ? AppIcons.addImage : AppIcons.files,
                title: pet ? l10n.botsPetConvertPet : l10n.botsPetConvertRoom,
                subtitle: pet ? l10n.botsPetConvertPetHint : l10n.botsPetConvertRoomHint,
                onTap: _busy ? null : _build,
              ),
            ],
          ),
        ],
        // What the build produced stays at the very bottom of the page.
        if (result)
          SettingsSection(
            key: _resultKey,
            title: l10n.botsPetConvertResult,
            children: [
              if (_saved case final saved?) SettingsTile(title: saved, chevron: false),
              if (_roomZip != null)
                SettingsTile(
                  icon: AppIcons.add,
                  title: l10n.botsPetConvertRoomImport,
                  subtitle: l10n.botsPetConvertRoomImportHint,
                  onTap: _busy ? null : _installRoom,
                ),
            ],
          ),
      ],
    );
  }

  /// The expression file behind an expression name, shown as a hint.
  String? _expressionFile(Live2dKitReport report, String? name) {
    if (name == null) return null;
    for (final expression in report.expressions) {
      if (expression.name == name) return expression.file;
    }
    return null;
  }

  /// The key the AI writes, plus the file behind the pick once there is one.
  String _subtitle(String key, String? file) => file == null ? key : '$key · $file';

  String _emotionLabel(String key) {
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    return (zh ? _emotionLabelsZh : _emotionLabelsEn)[key] ?? key;
  }

  String _actionLabel(String key) {
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    return (zh ? _actionLabelsZh : _actionLabelsEn)[key] ?? key;
  }

  String? _motionFile(Live2dKitReport report, String? key) {
    if (key == null) return null;
    for (final motion in report.motions) {
      if (motion.key == key) return motion.file;
    }
    return null;
  }

  /// The kit's problems open with a stable token (`states-missing: …`); what a
  /// person reads is the sentence after it.
  static String _sentence(String problem) {
    final colon = problem.indexOf(': ');
    return colon < 0 ? problem : problem.substring(colon + 2);
  }

  static String _size(BuildContext context, int bytes) {
    if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    if (bytes >= 1024) return '${(bytes / 1024).round()} KB';
    return '$bytes B';
  }
}

/// The eleven states, in pack order, then the five reactions.
const _stateKeys = <String>[
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

const _reactionKeys = <String>['tapLeft', 'tapRight', 'tickle', 'annoyed', 'drag'];

/// Display names for the companion's vocabulary. The keys stay the same, since
/// that is what the AI writes and what `character.json` stores.
const _emotionLabelsZh = <String, String>{
  'calm': '平静',
  'happy': '开心',
  'shy': '害羞',
  'sad': '难过',
  'angry': '生气',
  'surprised': '惊讶',
  'confused': '疑惑',
  'smug': '得意',
  'sleepy': '困',
  'worried': '担心',
};

const _emotionLabelsEn = <String, String>{
  'calm': 'Calm',
  'happy': 'Happy',
  'shy': 'Shy',
  'sad': 'Sad',
  'angry': 'Angry',
  'surprised': 'Surprised',
  'confused': 'Confused',
  'smug': 'Smug',
  'sleepy': 'Sleepy',
  'worried': 'Worried',
};

const _actionLabelsZh = <String, String>{
  'nod': '点头',
  'nodSmall': '轻点头',
  'shake': '摇头',
  'tilt': '歪头',
  'tiltLeft': '左歪头',
  'lookUp': '抬头',
  'recoil': '后退',
  'duck': '低头',
  'sway': '摇摆',
  'stretch': '伸展',
  'yawn': '打哈欠',
  'wave': '挥手',
};

const _actionLabelsEn = <String, String>{
  'nod': 'Nod',
  'nodSmall': 'Nod a little',
  'shake': 'Shake the head',
  'tilt': 'Tilt the head',
  'tiltLeft': 'Tilt left',
  'lookUp': 'Look up',
  'recoil': 'Recoil',
  'duck': 'Duck',
  'sway': 'Sway',
  'stretch': 'Stretch',
  'yawn': 'Yawn',
  'wave': 'Wave',
};

/// What the converter is building: a desktop pet pack (states drive motions)
/// or a companion pack (emotions drive expressions, actions drive motions).
enum _Target { pet, room }

/// One expression for an emotion, or 「不套表情」: an empty answer.
class _ExpressionSheet extends StatelessWidget {
  const _ExpressionSheet({required this.report, required this.selected, required this.onPreview});

  final Live2dKitReport report;
  final String? selected;
  final ValueChanged<String> onPreview;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(padding: const EdgeInsets.fromLTRB(20, 18, 20, 8), child: Text(l10n.botsPetConvertChooseExpression)),
          SettingsTile(
            title: l10n.botsPetConvertExpressionNone,
            value: selected == null ? const Icon(AppIcons.selected, size: 18) : null,
            onTap: () => Navigator.of(context).pop(''),
          ),
          for (final expression in report.expressions)
            SettingsTile(
              title: expression.name,
              subtitle: expression.file,
              value: expression.name == selected ? const Icon(AppIcons.selected, size: 18) : null,
              trailing: IconButton(
                onPressed: () => onPreview(expression.name),
                icon: const Icon(AppIcons.play, size: 20),
                tooltip: l10n.botsPetConvertPreview,
              ),
              onTap: () => Navigator.of(context).pop(expression.name),
            ),
        ],
      ),
    );
  }
}

/// One framing number — scale, or one of the two offsets — as a labelled
/// slider. The room's camera is three plain numbers (`stage.js`), and a slider
/// is the only way to judge them without building a pack first.
class _FramingSlider extends StatelessWidget {
  const _FramingSlider({
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.label,
    required this.onChanged,
  });

  final String title;
  final double value;
  final double min;
  final double max;
  final String Function(double) label;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final v = value.clamp(min, max);
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 14, SettingsMetrics.inset, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(
              child: Row(
                children: [
                  Expanded(child: Text(title, style: settingsTitleStyle(context))),
                  const SizedBox(width: 12),
                  Text(label(v), style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Semantics(
              label: title,
              child: Slider(
                value: v,
                min: min,
                max: max,
                padding: EdgeInsets.zero,
                activeColor: scheme.onSurfaceVariant,
                inactiveColor: scheme.onSurface.withValues(alpha: 0.1),
                semanticFormatterCallback: (raw) => label(raw),
                onChanged: onChanged,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One motion for a state, or 「未实现」: an empty answer.
class _MotionSheet extends StatelessWidget {
  const _MotionSheet({required this.report, required this.selected, required this.onPreview});

  final Live2dKitReport report;
  final String? selected;
  final ValueChanged<String> onPreview;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(padding: const EdgeInsets.fromLTRB(20, 18, 20, 8), child: Text(l10n.botsPetConvertChooseMotion)),
          SettingsTile(
            title: l10n.botsPetConvertNone,
            value: selected == null ? const Icon(AppIcons.selected, size: 18) : null,
            onTap: () => Navigator.of(context).pop(''),
          ),
          for (final motion in report.motions)
            SettingsTile(
              title: motion.key,
              subtitle: motion.gesture ? null : l10n.botsPetConvertPhysicsOnly,
              value: motion.key == selected
                  ? const Icon(AppIcons.selected, size: 18)
                  : Text('${motion.duration.toStringAsFixed(1)}s'),
              trailing: IconButton(
                onPressed: () => onPreview(motion.key),
                icon: const Icon(AppIcons.play, size: 20),
                tooltip: l10n.botsPetConvertPreview,
              ),
              onTap: () => Navigator.of(context).pop(motion.key),
            ),
        ],
      ),
    );
  }
}
