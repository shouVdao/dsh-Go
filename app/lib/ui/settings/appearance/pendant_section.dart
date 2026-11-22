// Settings for the balance whale: whether it shows, which character and sound
// it wears, and the lines its bubble says. Lives on the theme page, next to the
// rest of the look-and-feel settings.

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../l10n/l10n.dart';
import '../../../state/pendant_options.dart';
import '../../../state/settings_state.dart';
import '../../theme/app_icons.dart';
import '../settings_widgets.dart';

class PendantSection extends ConsumerWidget {
  const PendantSection({super.key});

  Future<void> _pickArt(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    // The picker hands back a `content://` URI on Android, so `path` is null
    // and the bytes have to be streamed into our own copy instead.
    final picked = await FilePicker.pickFile(type: FileType.image);
    if (picked == null) return;
    File? target;
    try {
      final dir = Directory('${(await getApplicationSupportDirectory()).path}/pendant');
      await dir.create(recursive: true);
      target = File('${dir.path}/art-${DateTime.now().millisecondsSinceEpoch}${_ext(picked.name)}');
      await _copy(picked, target);
      // Decoded once before the setting changes: a picture the engine cannot
      // read would leave the built-in whale in place with no explanation.
      await _decode(target);
    } on FileSystemException {
      if (target != null) await _discard(target);
      if (context.mounted) _say(context, l10n.pendantPickFailed);
      return;
    } on Object {
      if (target != null) await _discard(target);
      if (context.mounted) _say(context, l10n.pendantPickUnsupported);
      return;
    }
    final previous = ref.read(settingsProvider).pendantArtPath;
    await ref.read(settingsProvider.notifier).setPendantArt(pendantArtCustom, path: target.path);
    await _forget(previous, keep: target.path);
  }

  Future<void> _pickSound(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final picked = await FilePicker.pickFile(type: FileType.audio);
    if (picked == null) return;
    File? target;
    try {
      final dir = Directory('${(await getApplicationSupportDirectory()).path}/pendant');
      await dir.create(recursive: true);
      target = File('${dir.path}/sound-${DateTime.now().millisecondsSinceEpoch}${_ext(picked.name)}');
      await _copy(picked, target);
    } on FileSystemException {
      if (target != null) await _discard(target);
      if (context.mounted) _say(context, l10n.pendantPickFailed);
      return;
    }
    final previous = ref.read(settingsProvider).pendantSoundPath;
    await ref.read(settingsProvider.notifier).setPendantSound(pendantSoundCustom, path: target.path);
    await _forget(previous, keep: target.path);
  }

  Future<void> _editLines(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final settings = ref.read(settingsProvider);
    final controller = TextEditingController(text: pendantLinesOf(settings.pendantLines).join('\n'));
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.pendantLinesEdit),
        content: TextField(
          controller: controller,
          minLines: 6,
          maxLines: 12,
          autofocus: true,
          decoration: InputDecoration(hintText: l10n.pendantLinesHint, border: const OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(''), child: Text(l10n.pendantLinesReset)),
          TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.commonCancel)),
          FilledButton(onPressed: () => Navigator.of(context).pop(controller.text), child: Text(l10n.commonSave)),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return;
    await ref.read(settingsProvider.notifier).setPendantLines(result);
  }

  void _say(BuildContext context, String text) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));
  }

  static String _ext(String name) {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot).toLowerCase();
  }

  /// Streams the picked file into [target]; the picker's own path is a
  /// `content://` URI on Android, which `File` cannot open.
  static Future<void> _copy(PlatformFile picked, File target) async {
    final sink = target.openWrite();
    try {
      await sink.addStream(picked.readAsByteStream());
    } finally {
      await sink.close();
    }
  }

  /// Throws unless the engine can decode [file] — the same decoder that draws
  /// it, so "it opened here" means "it will show on the pendant".
  static Future<void> _decode(File file) async {
    final codec = await ui.instantiateImageCodec(await file.readAsBytes());
    try {
      final frame = await codec.getNextFrame();
      frame.image.dispose();
    } finally {
      codec.dispose();
    }
  }

  /// Drops the copy [path] this pick replaces, so picking five pictures does
  /// not leave five in the app folder.
  static Future<void> _forget(String path, {required String keep}) async {
    if (path.isEmpty || path == keep) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Best effort: a stale copy costs a few hundred KB.
    }
  }

  static Future<void> _discard(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Nothing was written, or the folder refuses deletes; either way the
      // setting still points at the previous picture.
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    // The sheets below close themselves before the picker opens, so the pick
    // has to run against this page's context: the sheet's is gone by the time
    // the picker returns, and `context.mounted` would drop the result.
    final page = context;

    return SettingsSection(
      title: l10n.pendantTitle,
      // The switch below carries the spot: a section and its first row may
      // not both anchor it, or the search index counts it twice.
      children: [
        SettingsSwitchTile(
          spot: Spots.pendant,
          subtitle: l10n.hubPendantHint,
          value: settings.pendant,
          onChanged: (v) => unawaited(notifier.setPendant(v)),
        ),
        SettingsTile(
          spot: Spots.pendantArt,
          icon: AppIcons.avatar,
          title: l10n.pendantArtTitle,
          value: Text(settings.pendantArt == pendantArtCustom ? l10n.pendantArtCustom : l10n.pendantArtHead),
          onTap: settings.pendant == false
              ? null
              : () => showModalBottomSheet<void>(
                  context: context,
                  builder: (context) => SafeArea(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ListTile(
                          leading: const Icon(AppIcons.image),
                          title: Text(l10n.pendantArtHead),
                          trailing: settings.pendantArt == pendantArtHead ? const Icon(AppIcons.selected) : null,
                          onTap: () {
                            unawaited(notifier.setPendantArt(pendantArtHead));
                            Navigator.of(context).pop();
                          },
                        ),
                        ListTile(
                          leading: const Icon(AppIcons.gallery),
                          title: Text(l10n.pendantArtCustom),
                          subtitle: settings.pendantArtPath.isEmpty ? Text(l10n.pendantArtPick) : null,
                          trailing: settings.pendantArt == pendantArtCustom ? const Icon(AppIcons.selected) : null,
                          onTap: () {
                            Navigator.of(context).pop();
                            unawaited(_pickArt(page, ref));
                          },
                        ),
                      ],
                    ),
                  ),
                ),
        ),
        SettingsTile(
          spot: Spots.pendantSound,
          icon: AppIcons.readAloud,
          title: l10n.pendantSoundTitle,
          value: Text(switch (settings.pendantSound) {
            pendantSoundOff => l10n.pendantSoundOff,
            pendantSoundFx1 => l10n.pendantSoundFx1,
            pendantSoundCustom => l10n.pendantSoundCustom,
            _ => l10n.pendantSoundDuck,
          }),
          onTap: settings.pendant == false
              ? null
              : () => showModalBottomSheet<void>(
                  context: context,
                  builder: (context) => SafeArea(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final (key, label) in [
                          (pendantSoundDuck, l10n.pendantSoundDuck),
                          (pendantSoundFx1, l10n.pendantSoundFx1),
                          (pendantSoundOff, l10n.pendantSoundOff),
                        ])
                          ListTile(
                            leading: Icon(key == pendantSoundOff ? AppIcons.micMuted : AppIcons.readAloud),
                            title: Text(label),
                            trailing: settings.pendantSound == key ? const Icon(AppIcons.selected) : null,
                            onTap: () {
                              unawaited(notifier.setPendantSound(key));
                              Navigator.of(context).pop();
                            },
                          ),
                        ListTile(
                          leading: const Icon(AppIcons.audio),
                          title: Text(l10n.pendantSoundCustom),
                          subtitle: settings.pendantSoundPath.isEmpty ? Text(l10n.pendantSoundPick) : null,
                          trailing: settings.pendantSound == pendantSoundCustom ? const Icon(AppIcons.selected) : null,
                          onTap: () {
                            Navigator.of(context).pop();
                            unawaited(_pickSound(page, ref));
                          },
                        ),
                      ],
                    ),
                  ),
                ),
        ),
        SettingsTile(
          spot: Spots.pendantLines,
          icon: AppIcons.chat,
          title: l10n.pendantLinesTitle,
          subtitle: l10n.pendantLinesHint,
          onTap: settings.pendant == false ? null : () => unawaited(_editLines(context, ref)),
        ),
        SettingsTile(
          spot: Spots.pendantReset,
          icon: AppIcons.pin,
          title: l10n.pendantResetPlace,
          onTap: settings.pendant == false ? null : () => unawaited(notifier.setPendantPlace(0.04, 0)),
        ),
      ],
    );
  }
}
