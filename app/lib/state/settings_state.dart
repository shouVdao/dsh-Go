import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import '../performance/performance_state.dart';
import '../secrets/secure_storage.dart';
import 'pendant_options.dart';
import 'provider_keys.dart';
import 'read_list_epoch.dart';

/// User settings: the DeepSeek API key (and custom-provider keys, see
/// [ProviderKeyVault]) live in the Android Keystore-backed secure storage;
/// plain preferences go to SharedPreferences.
class AppSettings {
  const AppSettings({
    this.apiKey = '',
    this.themeMode = ThemeMode.system,
    this.autoStartLocal = true,
    this.autoStartLocalExplicit = true,
    this.autoApproveCommands = false,
    this.automaticDiagnostics = false,
    this.phoneStorage = false,
    this.webPhoneLayout = true,
    this.chatSuggestions = true,
    this.chatTips = true,
    this.pendant = true,
    this.pendantArt = pendantArtHead,
    this.pendantArtPath = '',
    this.pendantSound = pendantSoundDuck,
    this.pendantSoundPath = '',
    this.pendantLines = '',
    this.pendantX = 0.04,
    this.pendantY = 0,
    this.hardwareEnterSends = false,
    this.chatTextScale = 1.0,
    this.foldCompletedTurns = true,
    this.visualReplies = true,
    this.customProviderIds = const {},
    this.loaded = false,
  });

  final String apiKey;
  final ThemeMode themeMode;

  /// Start the local DSH automatically when the app opens.
  final bool autoStartLocal;

  /// A stored user choice. Policy defaults never create this preference.
  final bool autoStartLocalExplicit;

  /// New local sessions use DSH's `danger-full-access` preset (commands run without asking).
  /// Off by default: there is no sandbox on Android, so each command escalation asks first.
  final bool autoApproveCommands;

  /// Explicit opt-in to sending content-free local failure facts to the model.
  final bool automaticDiagnostics;

  /// Mount the phone's shared storage at /sdcard in the Linux environment.
  final bool phoneStorage;

  /// Fit the embedded DSH Web to a phone (`assets/web/`). Off shows the
  /// official layout untouched, e.g. to check a plugin that restyles it.
  final bool webPhoneLayout;

  /// Show the fixed suggestion cards on the native chat's start page.
  final bool chatSuggestions;

  /// Show the one-at-a-time usage tips on the start page (gestures and entry
  /// points the app really has).
  final bool chatTips;

  /// Show the balance whale above the composer (Settings > Appearance >
  /// Balance whale).
  final bool pendant;

  /// The character art: [pendantArtHead] or [pendantArtCustom] with
  /// [pendantArtPath].
  final String pendantArt;

  /// A picked image copied into the app's own folder, used when [pendantArt]
  /// is [pendantArtCustom]. Empty when there is none.
  final String pendantArtPath;

  /// The sound pair a press and release play: [pendantSoundDuck] (Ya1/Ya2),
  /// [pendantSoundFx1] (D1/D2), [pendantSoundOff], or [pendantSoundCustom] with
  /// [pendantSoundPath].
  final String pendantSound;

  /// A picked audio file played on press when [pendantSound] is custom. Empty
  /// when there is none.
  final String pendantSoundPath;

  /// The bubble's own lines, one per line; empty means [pendantDefaultLines].
  final String pendantLines;

  /// Where the whale sits in the strip above the composer, as fractions of that
  /// strip: 0 is the left edge, 0 the bottom. Dragging stores it.
  final double pendantX;
  final double pendantY;

  /// Hardware Enter sends; Shift+Enter and the software keyboard still insert newlines.
  final bool hardwareEnterSends;

  /// Size of chat content relative to the system setting (header and
  /// composer keep theirs). One of [chatTextScales].
  final double chatTextScale;

  /// A normally finished turn folds its thinking, tool calls and interim
  /// messages into one summary line above the answer (DSH Web's default).
  final bool foldCompletedTurns;

  /// Tell the local DSH it may answer with ```dsh-ui views (charts, cards,
  /// options): a section of the managed AGENTS.md, written at engine start.
  /// Off only drops the instructions; views that arrive are still drawn.
  final bool visualReplies;

  /// Custom providers created on the local engine whose key is kept on the
  /// phone ([ProviderKeyVault]). Known at launch, before the engine runs, so
  /// the first-run gate can tell "has a model to talk to" without it.
  final Set<String> customProviderIds;
  final bool loaded;

  bool get hasApiKey => apiKey.trim().isNotEmpty;

  /// A DeepSeek key or a custom provider on the local engine.
  bool get hasModelAccess => hasApiKey || customProviderIds.isNotEmpty;

  AppSettings copyWith({
    String? apiKey,
    ThemeMode? themeMode,
    bool? autoStartLocal,
    bool? autoStartLocalExplicit,
    bool? autoApproveCommands,
    bool? automaticDiagnostics,
    bool? phoneStorage,
    bool? webPhoneLayout,
    bool? chatSuggestions,
    bool? chatTips,
    bool? pendant,
    String? pendantArt,
    String? pendantArtPath,
    String? pendantSound,
    String? pendantSoundPath,
    String? pendantLines,
    double? pendantX,
    double? pendantY,
    bool? hardwareEnterSends,
    double? chatTextScale,
    bool? foldCompletedTurns,
    bool? visualReplies,
    Set<String>? customProviderIds,
    bool? loaded,
  }) => AppSettings(
    apiKey: apiKey ?? this.apiKey,
    themeMode: themeMode ?? this.themeMode,
    autoStartLocal: autoStartLocal ?? this.autoStartLocal,
    autoStartLocalExplicit: autoStartLocalExplicit ?? this.autoStartLocalExplicit,
    autoApproveCommands: autoApproveCommands ?? this.autoApproveCommands,
    automaticDiagnostics: automaticDiagnostics ?? this.automaticDiagnostics,
    phoneStorage: phoneStorage ?? this.phoneStorage,
    webPhoneLayout: webPhoneLayout ?? this.webPhoneLayout,
    chatSuggestions: chatSuggestions ?? this.chatSuggestions,
    chatTips: chatTips ?? this.chatTips,
    pendant: pendant ?? this.pendant,
    pendantArt: pendantArt ?? this.pendantArt,
    pendantArtPath: pendantArtPath ?? this.pendantArtPath,
    pendantSound: pendantSound ?? this.pendantSound,
    pendantSoundPath: pendantSoundPath ?? this.pendantSoundPath,
    pendantLines: pendantLines ?? this.pendantLines,
    pendantX: pendantX ?? this.pendantX,
    pendantY: pendantY ?? this.pendantY,
    hardwareEnterSends: hardwareEnterSends ?? this.hardwareEnterSends,
    chatTextScale: chatTextScale ?? this.chatTextScale,
    foldCompletedTurns: foldCompletedTurns ?? this.foldCompletedTurns,
    visualReplies: visualReplies ?? this.visualReplies,
    customProviderIds: customProviderIds ?? this.customProviderIds,
    loaded: loaded ?? this.loaded,
  );
}

/// Chat text sizes offered in settings: (scale, label).
List<(double, String)> get chatTextScales => [
  (0.9, appL10n.stateSizeSmall),
  (1.0, appL10n.stateSizeStandard),
  (1.15, appL10n.stateSizeLarge),
  (1.3, appL10n.stateSizeExtraLarge),
];

class SettingsController extends Notifier<AppSettings> {
  static const _apiKeyKey = 'deepseek_api_key';
  static const _themeKey = 'theme_mode';
  static const _autoStartKey = 'auto_start_local';
  static const _autoApproveKey = 'auto_approve_commands';
  static const _automaticDiagnosticsKey = 'automatic_diagnostics';
  static const _phoneStorageKey = 'phone_storage';
  static const _webPhoneLayoutKey = 'web_phone_layout';
  static const _chatSuggestionsKey = 'chat_suggestions';
  static const _chatTipsKey = 'chat_tips';
  static const _pendantKey = 'pendant_widget';
  static const _pendantArtKey = 'pendant_art';
  static const _pendantArtPathKey = 'pendant_art_path';
  static const _pendantSoundKey = 'pendant_sound';
  static const _pendantSoundPathKey = 'pendant_sound_path';
  static const _pendantLinesKey = 'pendant_lines';
  static const _pendantXKey = 'pendant_x';
  static const _pendantYKey = 'pendant_y';
  static const _hardwareEnterKey = 'hardware_enter_sends';
  static const _chatTextScaleKey = 'chat_text_scale';
  static const _foldTurnsKey = 'fold_completed_turns';
  static const _visualRepliesKey = 'visual_replies';
  static const _secure = AppSecureStorage();
  late Future<void> _loaded;

  @override
  AppSettings build() {
    ref.listen(performanceDefaultsProvider.select((p) => p.autoStartLocal), (_, next) {
      if (!state.autoStartLocalExplicit) state = state.copyWith(autoStartLocal: next);
    });
    _loaded = _load();
    return const AppSettings(autoStartLocalExplicit: false);
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!ref.mounted) return;
    await performanceReady(ref);
    if (!ref.mounted) return;
    String apiKey = '';
    try {
      apiKey = await _secure.read(key: _apiKeyKey) ?? '';
    } catch (_) {
      // Keystore unavailable or corrupted; the user can re-enter the key.
    }
    if (!ref.mounted) return;
    var providerIds = const <String>{};
    try {
      providerIds = (await ref.read(providerKeyVaultProvider).readAll()).keys.toSet();
    } catch (_) {
      // Same: the providers still work, only the self-heal copy is gone.
    }
    if (!ref.mounted) return;
    state = AppSettings(
      apiKey: apiKey,
      themeMode: ThemeMode.values.firstWhere(
        (m) => m.name == prefs.getString(_themeKey),
        orElse: () => ThemeMode.system,
      ),
      autoStartLocal: prefs.getBool(_autoStartKey) ?? ref.read(performanceDefaultsProvider).autoStartLocal,
      autoStartLocalExplicit: prefs.containsKey(_autoStartKey),
      autoApproveCommands: prefs.getBool(_autoApproveKey) ?? false,
      automaticDiagnostics: prefs.getBool(_automaticDiagnosticsKey) ?? false,
      phoneStorage: prefs.getBool(_phoneStorageKey) ?? false,
      webPhoneLayout: prefs.getBool(_webPhoneLayoutKey) ?? true,
      chatSuggestions: prefs.getBool(_chatSuggestionsKey) ?? true,
      chatTips: prefs.getBool(_chatTipsKey) ?? true,
      pendant: prefs.getBool(_pendantKey) ?? true,
      pendantArt: prefs.getString(_pendantArtKey) ?? pendantArtHead,
      pendantArtPath: prefs.getString(_pendantArtPathKey) ?? '',
      pendantSound: prefs.getString(_pendantSoundKey) ?? pendantSoundDuck,
      pendantSoundPath: prefs.getString(_pendantSoundPathKey) ?? '',
      pendantLines: prefs.getString(_pendantLinesKey) ?? '',
      pendantX: (prefs.getDouble(_pendantXKey) ?? 0.04).clamp(0.0, 1.0),
      pendantY: (prefs.getDouble(_pendantYKey) ?? 0.0).clamp(0.0, 1.0),
      hardwareEnterSends: prefs.getBool(_hardwareEnterKey) ?? false,
      chatTextScale: _knownScale(prefs.getDouble(_chatTextScaleKey)),
      foldCompletedTurns: prefs.getBool(_foldTurnsKey) ?? true,
      visualReplies: prefs.getBool(_visualRepliesKey) ?? true,
      customProviderIds: providerIds,
      loaded: true,
    );
  }

  /// Takes the keys in again once the saved credentials were cleared
  /// (credential_recovery.dart). Only the keys: invalidating this provider would
  /// drop [AppSettings.loaded] and the whole app back to the splash.
  Future<void> reloadCredentials() async {
    await _loaded;
    if (!ref.mounted) return;
    var apiKey = '';
    var providerIds = const <String>{};
    try {
      apiKey = await _secure.read(key: _apiKeyKey) ?? '';
      providerIds = (await ref.read(providerKeyVaultProvider).readAll()).keys.toSet();
    } catch (_) {
      // As in [_load]: the user can re-enter them.
    }
    if (!ref.mounted) return;
    state = state.copyWith(apiKey: apiKey, customProviderIds: providerIds);
  }

  /// Keeps [key] for the local engine's custom provider [id] (see
  /// [ProviderKeyVault]).
  Future<void> saveProviderKey(String id, String key) async {
    ref.read(readListCredentialEpochProvider.notifier).advance();
    await ref.read(providerKeyVaultProvider).write(id, key);
    state = state.copyWith(customProviderIds: {...state.customProviderIds, id});
  }

  Future<void> removeProviderKey(String id) async {
    ref.read(readListCredentialEpochProvider.notifier).advance();
    await ref.read(providerKeyVaultProvider).delete(id);
    state = state.copyWith(customProviderIds: {...state.customProviderIds}..remove(id));
  }

  Future<void> setApiKey(String key) async {
    ref.read(readListCredentialEpochProvider.notifier).advance();
    final trimmed = key.trim();
    if (trimmed.isEmpty) {
      await _secure.delete(key: _apiKeyKey);
    } else {
      await _secure.write(key: _apiKeyKey, value: trimmed);
    }
    state = state.copyWith(apiKey: trimmed);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeKey, mode.name);
    state = state.copyWith(themeMode: mode);
  }

  Future<void> setAutoApproveCommands(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoApproveKey, value);
    state = state.copyWith(autoApproveCommands: value);
  }

  Future<void> setAutomaticDiagnostics(bool value) async {
    await _loaded;
    if (!ref.mounted) return;
    // Revocation is immediate; enabling must not start a paid request before
    // its opt-in is durably saved. Storage exceptions fail closed too.
    if (!value) state = state.copyWith(automaticDiagnostics: false);
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setBool(_automaticDiagnosticsKey, value)) {
        throw StateError('automatic_diagnostics_store_failed');
      }
      if (ref.mounted && value) state = state.copyWith(automaticDiagnostics: true);
    } catch (_) {
      if (ref.mounted) state = state.copyWith(automaticDiagnostics: false);
      rethrow;
    }
  }

  Future<void> setPhoneStorage(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_phoneStorageKey, value);
    state = state.copyWith(phoneStorage: value);
  }

  static double _knownScale(double? v) => chatTextScales.any((s) => s.$1 == v) ? v! : 1.0;

  Future<void> setChatTextScale(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_chatTextScaleKey, value);
    state = state.copyWith(chatTextScale: value);
  }

  Future<void> setFoldCompletedTurns(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_foldTurnsKey, value);
    state = state.copyWith(foldCompletedTurns: value);
  }

  /// Takes effect at the next engine start (the instructions live in the
  /// managed AGENTS.md, written before DSH starts).
  Future<void> setVisualReplies(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_visualRepliesKey, value);
    state = state.copyWith(visualReplies: value);
  }

  Future<void> setWebPhoneLayout(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_webPhoneLayoutKey, value);
    state = state.copyWith(webPhoneLayout: value);
  }

  Future<void> setHardwareEnterSends(bool value) async {
    await _loaded;
    if (!ref.mounted) return;
    state = state.copyWith(hardwareEnterSends: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_hardwareEnterKey, value);
  }

  Future<void> setChatSuggestions(bool value) async {
    await _loaded;
    if (!ref.mounted) return;
    state = state.copyWith(chatSuggestions: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_chatSuggestionsKey, value);
  }

  Future<void> setChatTips(bool value) async {
    await _loaded;
    if (!ref.mounted) return;
    state = state.copyWith(chatTips: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_chatTipsKey, value);
  }

  Future<void> setPendant(bool value) async {
    await _loaded;
    if (!ref.mounted) return;
    state = state.copyWith(pendant: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_pendantKey, value);
  }

  /// The character art; [path] is only kept for [pendantArtCustom].
  Future<void> setPendantArt(String art, {String path = ''}) async {
    await _loaded;
    if (!ref.mounted) return;
    state = state.copyWith(pendantArt: art, pendantArtPath: path);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendantArtKey, art);
    await prefs.setString(_pendantArtPathKey, path);
  }

  /// The press/release sound pair; [path] is only kept for [pendantSoundCustom].
  Future<void> setPendantSound(String sound, {String path = ''}) async {
    await _loaded;
    if (!ref.mounted) return;
    state = state.copyWith(pendantSound: sound, pendantSoundPath: path);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendantSoundKey, sound);
    await prefs.setString(_pendantSoundPathKey, path);
  }

  /// The bubble's lines, one per line; empty restores the built-in set.
  Future<void> setPendantLines(String lines) async {
    await _loaded;
    if (!ref.mounted) return;
    state = state.copyWith(pendantLines: lines);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendantLinesKey, lines);
  }

  /// Where the whale sits above the composer, as fractions of that strip.
  Future<void> setPendantPlace(double x, double y) async {
    await _loaded;
    if (!ref.mounted) return;
    state = state.copyWith(pendantX: x, pendantY: y);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_pendantXKey, x);
    await prefs.setDouble(_pendantYKey, y);
  }

  Future<void> setAutoStartLocal(bool value) async {
    await _loaded;
    if (!ref.mounted) return;
    state = state.copyWith(autoStartLocal: value, autoStartLocalExplicit: true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoStartKey, value);
  }
}

final settingsProvider = NotifierProvider<SettingsController, AppSettings>(SettingsController.new);
