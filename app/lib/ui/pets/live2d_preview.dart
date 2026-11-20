// One motion of a model that is not installed yet, played on the web stage.
//
// The converter asks which of a model's motions a pet state should play, and a
// group name is not something a person can judge: `m05` may be a wave or a
// blink. So the list gets a ▶ per motion and this sheet plays it, on a pack made
// up on the spot — the model the page has in memory, written to a temporary
// folder and handed to the same view the chat draws pets with. Nothing here is
// installed, and closing the sheet deletes the folder.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../l10n/l10n.dart';
import '../../pets/live2d_kit.dart';
import '../../pets/pet_pack.dart';
import '../../pets/pet_state.dart';
import '../theme/app_icons.dart';
import 'pet_live2d_view.dart';

/// A dialog that plays [motion] of [report]'s model — and holds one of its
/// expressions, when [expression] says so — with the model's other motions and
/// expressions one button away.
class Live2dPreviewSheet extends ConsumerStatefulWidget {
  const Live2dPreviewSheet({super.key, required this.report, required this.motion, this.expression, this.framing});

  final Live2dKitReport report;
  final String motion;
  final String? expression;

  /// The room's framing (`zoom`, `x`, `y`) to show the model with, so a pack's
  /// placement can be judged before it is built.
  final Map<String, double>? framing;

  static Future<void> show(
    BuildContext context, {
    required Live2dKitReport report,
    required String motion,
    String? expression,
    Map<String, double>? framing,
  }) => showDialog<void>(
    context: context,
    builder: (context) => Live2dPreviewSheet(report: report, motion: motion, expression: expression, framing: framing),
  );

  @override
  ConsumerState<Live2dPreviewSheet> createState() => _Live2dPreviewSheetState();
}

class _Live2dPreviewSheetState extends ConsumerState<Live2dPreviewSheet> {
  /// The canvas a preview pack claims. The stage fits the model to the canvas
  /// it draws into, so any square works and none of it is written anywhere.
  static const _canvas = 1024;

  late Directory? _dir;
  PetPack? _pack;
  late String _motion = widget.motion;
  late String? _expression = widget.expression;

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  @override
  void dispose() {
    final dir = _dir;
    _dir = null;
    if (dir != null) unawaited(dir.delete(recursive: true).catchError((Object _) => dir));
    super.dispose();
  }

  /// Writes the model the page read to a temporary pack: `character/` holds the
  /// files as downloaded, and the pack around them is only what the stage needs
  /// to boot (pet_live2d_view.dart reads `live2d.model`).
  Future<void> _prepare() async {
    final model = widget.report.model;
    try {
      final root = Directory(
        '${(await getTemporaryDirectory()).path}/live2d-preview-${DateTime.now().microsecondsSinceEpoch}',
      );
      _dir = root;
      final character = Directory('${root.path}/character');
      await character.create(recursive: true);
      for (final MapEntry(:key, :value) in model.files.entries) {
        final file = File('${character.path}/$key');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(value, flush: false);
      }
      if (!mounted) return;
      setState(() => _pack = PetPack.parse(_json(model.descriptor), dir: root.path));
    } on Object catch (error) {
      if (mounted) setState(() => _pack = null);
      debugPrint('live2d preview: $error');
    }
  }

  /// A pet pack whose only state is the motion being previewed. The poster
  /// animation is required by pack.json even though no sprite is ever drawn —
  /// the stage paints the model instead.
  Map<String, Object?> _json(String descriptor) {
    final side = _canvas.toDouble();
    return {
      'schema': PetPack.schema,
      'id': 'live2d-preview',
      'name': widget.report.model.name,
      'type': 'live2d',
      'canvas': {'w': _canvas, 'h': _canvas},
      'anchor': {'x': _canvas ~/ 2, 'baseline': _canvas},
      'contentBox': {'x': 0, 'y': 0, 'w': _canvas, 'h': _canvas},
      'scale': 1,
      'pixelArt': false,
      'animations': {
        'poster': {
          'sheet': 'poster.png',
          'frameW': _canvas,
          'frameH': _canvas,
          'cols': 1,
          'box': {'x': 0, 'y': 0, 'w': side, 'h': side},
          'frames': [
            {'i': 0, 'ms': 1000},
          ],
          'loop': true,
        },
      },
      'states': {
        for (final state in PetStateName.values) state.name: ['poster'],
      },
      'live2d': {
        'model': descriptor,
        'states': {PetStateName.idle.name: _motion},
        'fallback': _motion,
      },
    };
  }

  void _step(int delta) {
    final motions = widget.report.motions;
    if (motions.isEmpty) return;
    final index = motions.indexWhere((motion) => motion.key == _motion);
    final next = motions[(index + delta + motions.length) % motions.length];
    setState(() => _motion = next.key);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final motions = widget.report.motions;
    final index = motions.indexWhere((motion) => motion.key == _motion);
    final pack = _pack;
    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _expression == null
                          ? l10n.botsPetConvertPreviewTitle(_motion)
                          : l10n.botsPetConvertPreviewExpressionTitle(_expression!),
                      style: theme.textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(AppIcons.close, size: 20),
                    tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  ),
                ],
              ),
            ),
            AspectRatio(
              aspectRatio: 1,
              child: ColoredBox(
                color: theme.colorScheme.surfaceContainerLow,
                child: pack == null
                    ? const Center(child: CircularProgressIndicator())
                    : PetLive2dView(
                        pack: pack,
                        state: PetStateName.idle,
                        reaction: null,
                        motion: _motion,
                        expression: _expression,
                        framing: widget.framing,
                        child: _Placeholder(text: l10n.botsPetConvertPreviewHint),
                      ),
              ),
            ),
            if (widget.report.expressions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final expression in widget.report.expressions)
                      ChoiceChip(
                        label: Text(expression.name, style: theme.textTheme.labelSmall),
                        selected: _expression == expression.name,
                        onSelected: (selected) => setState(() => _expression = selected ? expression.name : null),
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: motions.length < 2 ? null : () => _step(-1),
                    icon: const Icon(Icons.chevron_left, size: 22),
                    tooltip: MaterialLocalizations.of(context).previousPageTooltip,
                  ),
                  Expanded(
                    child: Text(
                      motions.isEmpty ? '' : '${index + 1} / ${motions.length}',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelMedium,
                    ),
                  ),
                  IconButton(
                    onPressed: motions.length < 2 ? null : () => _step(1),
                    icon: const Icon(Icons.chevron_right, size: 22),
                    tooltip: MaterialLocalizations.of(context).nextPageTooltip,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the stage area shows while the runtime boots — or instead of it, when
/// the phone has no Live2D runtime installed (only a poster would draw).
class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
