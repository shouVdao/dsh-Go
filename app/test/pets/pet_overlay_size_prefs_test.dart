// 「App 外显示 › 大小」 is its own choice (docs/design/pets.md §2.10): the page's
// 大小 must not resize the floating window, and the other way around.

import 'package:dsh_app/pets/pet_prefs.dart';
import 'package:dsh_app/pets/pet_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> loaded([Map<String, Object> values = const {}]) async {
    SharedPreferences.setMockInitialValues(values);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.listen(petPrefsProvider, (_, _) {});
    await pumpEventQueue();
    expect(container.read(petPrefsProvider).loaded, isTrue);
    return container;
  }

  test('without a choice the window follows the page', () async {
    final c = await loaded();
    final prefs = c.read(petPrefsProvider);
    expect(prefs.overlaySize, isNull);
    expect(prefs.overlayCustomHeight, isNull);
    expect(prefs.overlayBodyHeight, prefs.bodyHeight);
  });

  test('the page and the window hold different presets', () async {
    final c = await loaded();
    final controller = c.read(petPrefsProvider.notifier);
    await controller.setSize(PetSize.small);
    await controller.setOverlaySize(PetSize.large);
    final prefs = c.read(petPrefsProvider);
    expect(prefs.size, PetSize.small);
    expect(prefs.bodyHeight, 22);
    expect(prefs.overlaySize, PetSize.large);
    expect(prefs.overlayBodyHeight, 40);

    // Changing the page again leaves the window's own choice alone.
    await controller.setSize(PetSize.medium);
    expect(c.read(petPrefsProvider).overlayBodyHeight, 40);
  });

  test('the window has its own 自定义 height', () async {
    final c = await loaded();
    final controller = c.read(petPrefsProvider.notifier);
    await controller.setSize(PetSize.custom);
    await controller.setCustomHeight(44);
    await controller.setOverlayCustomHeight(52);
    final prefs = c.read(petPrefsProvider);
    expect(prefs.overlaySize, PetSize.custom);
    expect(prefs.bodyHeight, 44);
    expect(prefs.overlayBodyHeight, 52);
  });

  test('both sizes survive a preference reload', () async {
    final c = await loaded();
    final controller = c.read(petPrefsProvider.notifier);
    await controller.setSize(PetSize.custom);
    await controller.setCustomHeight(40);
    await controller.setOverlayCustomHeight(55);
    final persisted = await SharedPreferences.getInstance();
    final second = await loaded({
      PetPrefsController.keys.size: persisted.getString(PetPrefsController.keys.size)!,
      PetPrefsController.keys.customHeight: persisted.getDouble(PetPrefsController.keys.customHeight)!,
      PetPrefsController.keys.overlaySize: persisted.getString(PetPrefsController.keys.overlaySize)!,
      PetPrefsController.keys.overlayCustomHeight: persisted.getDouble(PetPrefsController.keys.overlayCustomHeight)!,
    });
    final restored = second.read(petPrefsProvider);
    expect(restored.bodyHeight, 40);
    expect(restored.overlayBodyHeight, 55);
  });

  test('the push to the overlay carries the window size', () {
    const prefs = PetPrefs(size: PetSize.large, overlaySize: PetSize.small);
    final state = PetState(
      packId: 'deepy-whale',
      size: prefs.size,
      bodyHeight: prefs.bodyHeight,
      overlaySize: prefs.overlaySize,
      overlayBodyHeight: prefs.overlayBodyHeight,
    );
    expect(state.toMap()['size'], 'small');
    expect(state.toMap().containsKey('bodyHeight'), isFalse);

    const custom = PetPrefs(
      size: PetSize.custom,
      customHeight: 44,
      overlaySize: PetSize.custom,
      overlayCustomHeight: 61,
    );
    final tall = PetState(
      size: custom.size,
      bodyHeight: custom.bodyHeight,
      overlaySize: custom.overlaySize,
      overlayBodyHeight: custom.overlayBodyHeight,
    );
    expect(tall.toMap()['size'], 'custom');
    expect(tall.toMap()['bodyHeight'], 61);
  });
}
