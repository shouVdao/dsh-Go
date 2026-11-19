# mygo

English · [简体中文](README.md)

## Project

mygo is an Android client branch of [DSH Go](https://github.com/ccch1mneyyy/dsh-Go), developed from the upstream repository and including the features below. DSH Go is the mobile client for DeepSeek Harness: it connects to a remote DSH instance and runs sessions and tools on the phone.

- Repository: <https://github.com/shouVdao/dsh-Go>
- Default branch: `harmonyos`
- Upstream baseline: `9ad11167c` (2026-11-19)
- Application ID: `io.github.ccch1mneyyy.dsh_app`; minimum Android 8.0 (API 26), targetSdk 28
- Platform: Android first; `app/` also keeps the iOS and OpenHarmony implementations

## Features

### Interface and appearance

- **Start-page tips toggle**: Settings → Interface → Start page. When off, the start page of a new conversation renders no tips placeholder.
  - `app/lib/state/settings_state.dart` (`chatTips`, preference key `chat_tips`)
  - `app/lib/ui/chat/chat_screen.dart` (passes `tips` according to the toggle)
- **Material and text**: Settings → Appearance → Material. Overlays and cards use a translucent glass material with adjustable opacity, blur radius, text color, and a follow-theme option.
  - `app/lib/state/appearance_state.dart`
  - `app/lib/ui/settings/appearance/appearance_page.dart`
- **Pet overlay size**: Settings → Desktop pet → Overlay size. Choose a smaller height for the pet window outside the app; the in-chat pet size is adjusted separately.
  - `app/lib/pets/pet_prefs.dart` (`overlaySize`, `overlayCustomHeight`)
  - `app/lib/ui/pets/overlay_settings_tile.dart`

### Wallpapers

- **Looping live wallpaper**: Settings → Appearance → Wallpaper → Looping live wallpaper. An imported video file loops as the wallpaper, without progress or sound controls.
  - `app/lib/wallpaper/live_wallpaper.dart`
  - `app/lib/ui/wallpaper/video_wallpaper_editor_page.dart`
- **`.json` live wallpaper**: Settings → Appearance → Wallpaper → `.json` live wallpaper. An imported scene package switches between `day`/`dusk`/`night` scenes and supports background, image, and text nodes.
  - `app/lib/wallpaper/scene_document.dart`, `scene_engine.dart`, `scene_view.dart`
  - Format reference: `docs/json-wallpaper.md`

### Pets and Live2D

- **Cubism 2 models**: the pet page imports `.moc` models with `model.json`. The app injects the `live2d.min.js` runtime and plays `*.mtn` motions; physics, poses, expressions, and eye blinking are not evaluated.
  - `app/lib/pets/live2d_kit.dart`
  - `app/lib/pets/pet_live2d_install.dart`
- **Model sharpness**: the cube texture is chosen from screen density and stage size, preferring 1024 and falling back to 512/256. Pet packs are not written with a `poster.png`; the first frame comes from a stage screenshot.
  - `app/lib/pets/live2d_kit.dart`
- **Convert Live2D model**: pet-page entry that turns a Live2D model into a pet pack inside the app, including cover, size, and validation.
  - `app/lib/ui/pets/live2d_convert_page.dart`
- **`pet-theme` skill hosting**: Android, iOS, and OpenHarmony each copy `app/assets/skills/pet-theme` into the runtime user-skills directory. The skill contains sprite-asset conversion (GIF/ APNG/ WebP/ frame directories/ Aseprite/ single image, `pet_theme_convert.py`) and Live2D conversion (`live2d_pet_kit.py`).
  - `app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/runtime/ManagedSkillInstaller.kt`
  - `app/ios/Runner/EngineSkills.swift`
  - `app/ohos/entry/src/main/ets/runtime/ManagedSkillCore.ets`

### Pendant

- **Balance whale**: a floating pendant on the chat page that shows the balance and the valley/peak countdown. Tapping her opens the balance bubble, and tapping the bubble switches to the line bubble, stepping through lines. Holding drags the pendant, snapping it to the screen edge and saving its position. Sounds can be changed or turned off in settings.
  - `app/lib/ui/chat/pendant/whale_pendant.dart`
  - `app/lib/state/pendant_options.dart`
  - Design and behavior: `docs/design/pendant.md`
- **Custom character art**: the pendant settings import a user-provided character image, copied into the app's private directory; mirroring applies only to the built-in art.
  - `app/lib/state/settings_state.dart` (`pendantArt`, `pendantArtPath`)
  - `app/lib/ui/settings/appearance/pendant_section.dart`

### Build and compatibility

- **Pinned dependencies**: `file_picker` is pinned to 13.3.0 and `android_file_picker` to 2.1.6, because `android_file_picker` 2.2.0 (required by 13.4.0) does not compile with Kotlin; `path_provider_android` is pinned to 2.2.20, because its 2.3.x JNI implementation passes the `Landroid/content/Context;` descriptor to `JClass.forName` as a class name and throws `ClassNotFoundException`, which takes down the tavern, companion, workshop, and converter pages together.
  - `app/pubspec.yaml`

## Differences from upstream main

| Item | Upstream main | mygo | Main location |
| --- | --- | --- | --- |
| Start-page tips | Always shown | Can be turned off in settings | `app/lib/state/settings_state.dart`, `app/lib/ui/chat/chat_screen.dart` |
| Appearance material | None | Material and text: opacity, blur, text color, follow theme | `app/lib/state/appearance_state.dart` |
| Wallpaper kinds | Gradient, image | Adds looping video and `.json` scene packages | `app/lib/state/wallpaper_state.dart` (`WallpaperKind`) |
| Live2D models | Cubism 3 | Adds Cubism 2 (`.moc` + `model.json`) | `app/lib/pets/live2d_kit.dart` |
| Pet-page entry | "Let AI make a pet", types `/pet-theme` | "Convert Live2D model" wizard | `app/lib/ui/pets/pet_settings_page.dart`, `live2d_convert_page.dart` |
| Pet-pack cover | Required `poster.png` | Falls back to the stage's first frame | `app/lib/pets/live2d_kit.dart` |
| Pet overlay | Fixed sizes | Adds a smaller size | `app/lib/pets/pet_prefs.dart` |
| Balance pendant | None | Toggleable balance whale with optional custom art | `app/lib/ui/chat/pendant/whale_pendant.dart`, `app/lib/state/settings_state.dart` |
| `pet-theme` skill | Android hosting only | Hosted on Android, iOS, and OpenHarmony, with the Live2D flow | `ManagedSkillInstaller.kt`, `EngineSkills.swift`, `ManagedSkillCore.ets` |
| `file_picker` | 13.4.0 | Pinned 13.3.0 / `android_file_picker` 2.1.6 | `app/pubspec.yaml` |

## Project layout

| Path | Contents |
| --- | --- |
| `app/` | Flutter UI, Android Kotlin implementation, iOS Swift/WidgetKit implementation, and OpenHarmony ArkTS implementation |
| `packages/dsh_client/` | Dart client for the DSH Web API |
| `packages/dsh_remote/` | Dart client for DSH Remote |
| `runtime/` | Android Linux runtime, iOS runtime specialization, engine patches, and app bridges |
| `docs/` | Design documents, user guides, and pet/Live2D authoring references |
| `tooling/` | Toolchain installation, APK/iOS build, and diagnostic scripts |

## Reproducing the build

The flow matches upstream and targets Linux x86_64. It needs Bash, Git, curl, tar, unzip, xz, Python 3, zstd, and the usual GNU commands. The toolchain script installs Temurin JDK 17, Flutter 3.47.7, and the Android SDK/NDK. The required Dart version is declared in `app/pubspec.yaml`.

```bash
git clone https://github.com/shouVdao/dsh-Go.git
cd dsh-Go

bash tooling/setup-toolchain.sh
source tooling/env.sh
flutter --version
java -version

bash runtime/build-runtime.sh arm64-v8a
DSH_BETA_TOKEN_FILE= bash tooling/build-apk.sh -f arm64 --keep-daemon
```

- The toolchain installs into `~/dev` by default; set `DEV_ROOT` to use another directory. The script reuses existing installations, so verify the versions before building.
- `runtime/build-runtime.sh` produces the runtime package that the app consumes; it downloads dependencies over the network and verifies pinned versions.
- `DSH_BETA_TOKEN_FILE=` embeds no beta-channel token; `--keep-daemon` leaves the Gradle daemon running.
- x86_64 build: `bash runtime/build-runtime.sh x86_64`, then `DSH_BETA_TOKEN_FILE= bash tooling/build-apk.sh -f x64 --keep-daemon`.
- Print the build commands without running them: `DSH_BETA_TOKEN_FILE= bash tooling/build-apk.sh --dry-run -f all`.
- The artifact is written to `app/build/app/outputs/flutter-apk/app-arm64-release.apk`.
- Without `app/android/key.properties`, release builds use the debug signing key and cannot replace an installation signed with a different key. Release keys and `key.properties` must not be committed.
- On Windows, run the scripts above under WSL or Git Bash; once the runtime package exists, `cd app && flutter build apk --release --target-platform android-arm64` also works.

## Development and checks

```bash
cd app
flutter pub get
flutter analyze
flutter test
```

- After editing `app/lib/l10n/parts/*.arb`, run `python app/tool/l10n_merge.py` to regenerate `app/lib/l10n/gen/`; do not edit generated files by hand.
- After editing `docs/guide/`, run `python app/tool/guide_sync.py`.
- Font and golden tests need Noto CJK fonts. The default directory is `/usr/share/fonts/noto-cjk`; set `DSH_TEST_FONT_DIR` to another directory containing `NotoSansCJK-Light.ttc`, `NotoSansCJK-Regular.ttc`, and `NotoSansCJK-Bold.ttc`.
- On Windows, some tests fail on path separators, symbolic-link permissions (`errno 1314`), and CRLF line endings. Those are environment differences; Linux results are the reference.

## License

This project follows upstream and is licensed under the [GNU Affero General Public License v3.0](LICENSE). Modifications and redistribution must comply with its terms and keep the copyright, license, and modification notices.

- `sdk/` and `examples/` remain MIT-licensed.
- Third-party code and assets keep their own terms; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- The DSH Go name and logo, Deepy, and the whale-girl artwork are not covered by AGPL-3.0; see [ASSETS.md](ASSETS.md).
