// 设置 › 主题 › 启动画面: the user's own launch screen (lib/launch/custom_launch.dart), and
// whether it is the one in use; and the interactive launch screen (lib/launch/interactive_launch.dart).

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../launch/custom_launch.dart';
import '../launch/interactive_launch.dart';
import '../launch/launch_import.dart';

final launchImportProvider = Provider<LaunchImport>((ref) => LaunchImport());

/// The stored custom launch screen (null: none chosen yet).
final customLaunchProvider = AsyncNotifierProvider<CustomLaunchController, CustomLaunch?>(CustomLaunchController.new);

class CustomLaunchController extends AsyncNotifier<CustomLaunch?> {
  @override
  Future<CustomLaunch?> build() => CustomLaunch.load();

  /// The system picker; the pick becomes the launch screen in use. Null when it did, else why not
  /// ([LaunchImportProblem.cancelled] included).
  Future<LaunchImportProblem?> choose() async {
    final previous = state.value;
    final (custom, problem) = await ref.read(launchImportProvider).pick(previous: previous);
    if (custom == null) return problem ?? LaunchImportProblem.unreadable;
    await _store(custom);
    // Only now: until the new choice is saved, the old files are the one the next launch reads.
    await LaunchImport.removeFiles(previous, except: custom);
    return null;
  }

  /// The custom one in use (true) or the default (false); the file stays either way.
  Future<void> use(bool custom) async {
    final current = state.value;
    if (current == null || current.on == custom) return;
    await _store(current.copyWith(on: custom));
  }

  Future<void> setFit(LaunchFit fit) async {
    final current = state.value;
    if (current == null || current.fit == fit) return;
    await _store(current.copyWith(fit: fit));
  }

  Future<void> setBackdrop(LaunchBackdrop backdrop) async {
    final current = state.value;
    if (current == null || current.backdrop == backdrop) return;
    await _store(current.copyWith(backdrop: backdrop));
  }

  /// Where the screen sits in a [LaunchFit.fill] picture.
  Future<void> frame({required double zoom, required double alignX, required double alignY}) async {
    final current = state.value;
    if (current == null) return;
    await _store(
      current.copyWith(
        zoom: zoom.clamp(1.0, CustomLaunch.maxZoom),
        alignX: alignX.clamp(-1.0, 1.0),
        alignY: alignY.clamp(-1.0, 1.0),
      ),
    );
  }

  Future<void> _store(CustomLaunch custom) async {
    state = AsyncData(custom);
    await CustomLaunch.save(custom);
  }
}

/// The interactive launch screen's settings (its defaults until first changed).
final interactiveLaunchProvider = AsyncNotifierProvider<InteractiveLaunchController, InteractiveLaunch>(
  InteractiveLaunchController.new,
);

class InteractiveLaunchController extends AsyncNotifier<InteractiveLaunch> {
  @override
  Future<InteractiveLaunch> build() async => await InteractiveLaunch.load() ?? const InteractiveLaunch();

  /// Applies [edit] and saves it (the stored one stays if saving fails).
  Future<void> change(InteractiveLaunch Function(InteractiveLaunch current) edit) async {
    final current = state.value;
    if (current == null) return;
    final next = edit(current);
    if (next == current) return;
    await InteractiveLaunch.save(next);
    state = AsyncData(next);
  }

  /// The system picker for [scene]'s background: a picture or a clip (an animation is refused).
  /// Null when it was set, else why not ([LaunchImportProblem.cancelled] included).
  Future<LaunchImportProblem?> chooseBackground(InteractiveScene scene) async {
    final current = state.value;
    if (current == null) return LaunchImportProblem.unreadable;
    final previous = current.backgrounds[scene];
    final (picked, problem) = await ref.read(launchImportProvider).pick();
    if (picked == null) return problem ?? LaunchImportProblem.unreadable;
    if (picked.kind == LaunchMediaKind.animation) {
      await LaunchImport.removeFiles(picked);
      return LaunchImportProblem.unsupported;
    }
    try {
      // A background fills the screen, whatever the picture.
      await update((c) => c.withBackground(scene, picked.copyWith(fit: LaunchFit.fill)));
    } catch (_) {
      await LaunchImport.removeFiles(picked);
      return LaunchImportProblem.unreadable;
    }
    await LaunchImport.removeFiles(previous, except: picked);
    return null;
  }

  /// [scene] back to the built-in plate (its file is deleted).
  Future<void> clearBackground(InteractiveScene scene) async {
    final previous = state.value?.backgrounds[scene];
    if (previous == null) return;
    await update((c) => c.withBackground(scene, null));
    await LaunchImport.removeFiles(previous);
  }
}