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
  String? _problem;
  String? _saved;
  bool _busy = false;

  /// The zip that was picked, in bytes, when it is past what the converter
  /// reads. Shown as advice ("make it smaller first") instead of an error.
  int? _tooLarge;

  Future<void> _pick() async {
    if (_busy) return;
    final l10n = context.l10n;
    setState(() {
      _busy = true;
      _problem = null;
      _saved = null;
      _tooLarge = null;
    });
    File? temp;
    try {
      final picked = await FilePicker.pickFile();
      if (picked == null || !mounted) return;
      temp = File(
        '${(await getTemporaryDirectory()).path}/live2d-model-${DateTime.now().microsecondsSinceEpoch}.zip',
      );
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
  Future<void> _preview(String motion) =>
      Live2dPreviewSheet.show(context, report: _report!, motion: motion);

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

  Future<void> _build({required bool pet}) async {
    final report = _report;
    if (report == null || _busy) return;
    final l10n = context.l10n;
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
      final bytes = pet ? await Live2dKit.buildPet(report, _mapping) : await Live2dKit.buildRoom(report);
      final temp = File(
        '${(await getTemporaryDirectory()).path}/live2d-${pet ? 'pet' : 'room'}-${DateTime.now().microsecondsSinceEpoch}.zip',
      );
      await temp.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      if (pet) {
        final (:pack, :replaced) = await ref.read(userPetsProvider.notifier).import(temp);
        // The pack's canvas and content box are guesses: the first frame the
        // stage draws rewrites both (pet_live2d_view.dart).
        final folder = await ref.read(petLibraryProvider).folder(pack.id);
        await File('${folder.path}/$contentBoxAutoName').writeAsString('1', flush: true);
        await ref.read(petPrefsProvider.notifier).setPack(pack.id);
        if (!mounted) return;
        setState(() => _saved = replaced ? l10n.botsPetImportReplaced(pack.name) : l10n.botsPetConvertPetDone(pack.name));
      } else {
        final where = await ref
            .read(filesChannelProvider)
            .saveToDownloads(temp.path, name: '${report.model.name}-room.zip', mime: 'application/zip');
        if (!mounted) return;
        setState(() => _saved = l10n.botsPetConvertRoomDone(where));
      }
      await temp.delete().catchError((Object _) => temp);
    } on PetImportException catch (error) {
      if (mounted) setState(() => _problem = petImportProblemText(l10n, error));
    } on Live2dKitException catch (error) {
      if (mounted) setState(() => _problem = l10n.botsPetConvertFailed('${error.code} ${error.detail ?? ''}'.trim()));
    } on Object catch (error) {
      if (mounted) setState(() => _problem = l10n.botsPetConvertFailed('$error'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
    final missing = report == null
        ? const <String>[]
        : [
            for (final key in [..._stateKeys, ..._reactionKeys])
              if (_mapping[key] == null) _stateName(key),
          ];
    final used = _mapping.values.whereType<String>().toSet();
    final unused = report?.motions.where((motion) => !used.contains(motion.key)).length ?? 0;
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
          SettingsSection(
            children: [SettingsTile(title: l10n.botsPetConvertWorking, chevron: false, onTap: null)],
          ),
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
              SettingsTile(
                icon: AppIcons.skill,
                title: l10n.botsPetConvertTooLargeCopy,
                onTap: _copyPrompt,
              ),
            ],
          ),
        if (_problem case final problem?)
          SettingsSection(
            children: [SettingsTile(title: problem, danger: true, chevron: false)],
          ),
        if (_saved case final saved?)
          SettingsSection(
            children: [SettingsTile(title: saved, chevron: false)],
          ),
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
              SettingsTile(
                title: l10n.botsPetConvertMotions,
                value: Text('${report.motions.length}'),
                chevron: false,
              ),
              SettingsTile(
                title: l10n.botsPetConvertExpressions,
                value: Text('${report.expressions.length}'),
                chevron: false,
              ),
            ],
          ),
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
          SettingsSection(
            children: [
              SettingsTile(
                icon: AppIcons.addImage,
                title: l10n.botsPetConvertPet,
                subtitle: l10n.botsPetConvertPetHint,
                onTap: _busy ? null : () => _build(pet: true),
              ),
              SettingsTile(
                icon: AppIcons.files,
                title: l10n.botsPetConvertRoom,
                subtitle: l10n.botsPetConvertRoomHint,
                onTap: _busy ? null : () => _build(pet: false),
              ),
            ],
          ),
        ],
      ],
    );
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
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
            child: Text(l10n.botsPetConvertChooseMotion),
          ),
          SettingsTile(
            title: l10n.botsPetConvertNone,
            value: selected == null ? const Icon(Icons.check, size: 18) : null,
            onTap: () => Navigator.of(context).pop(''),
          ),
          for (final motion in report.motions)
            SettingsTile(
              title: motion.key,
              subtitle: motion.gesture ? null : l10n.botsPetConvertPhysicsOnly,
              value: motion.key == selected
                  ? const Icon(Icons.check, size: 18)
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
