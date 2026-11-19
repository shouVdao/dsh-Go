# mygo

[简体中文](README.md) · English

**mygo** is a personal fork of [ccch1mneyyy/dsh-Go](https://github.com/ccch1mneyyy/dsh-Go) (branch `harmonyos`; the repository itself is still `shouVdao/dsh-Go`).
Upstream's `main` is the mainline: mygo follows it while maintaining a set of UI, wallpaper, Live2D, pet and pendant changes that upstream **does not** have.

- Upstream: <https://github.com/ccch1mneyyy/dsh-Go> (default branch `main`)
- This repository: <https://github.com/shouVdao/dsh-Go> (branch `harmonyos`)
- Current baseline: merged up to upstream `9ad11167c`, **141 upstream commits** in total, both merges **conflict-free**; mygo is 4 commits ahead
- Diff against upstream: **115 files** (36 added, 79 modified, 0 deleted), `+17323 / −487`

> Upstream's two original landing pages (Chinese `README.md`, English `README.en.md`) have been replaced by this branch note; the originals remain readable via `git show upstream/main:README.md` and `git show upstream/main:README.en.md`, and the details on features, installation and contributing live in [docs/](docs/) and [CONTRIBUTING.md](CONTRIBUTING.md). This file only covers **how this branch differs from the mainline**.

---

## 1. Relation to the mainline

| Item | `main` (upstream) | mygo (`harmonyos`) |
|---|---|---|
| Role | Mainline | Replica + local enhancements, follows upstream merges |
| Merge policy | — | Periodic `git merge upstream/main`; on conflicts **local features win**, upstream features kept wherever possible |
| Build | Plain Flutter/Gradle | Plus an out-of-tree build script (see [section 6](#6-build)): signing, package rename and artifact verification in one pass |
| Test baseline | Linux + bundled Noto CJK fonts | The same tests as upstream; goldens need substitute fonts on this machine (see [section 7](#7-development-and-checks)) |

Upstream's default branch is `main`; this branch tracks the `harmonyos` line. The two merges took in `95588b696` (139 commits) and `9ad11167c` (2 commits: offer tawcroot after a PRoot startup failure). Merge commits: `aa6827a82`, `b9074649a`.

---

## 2. Differences at a glance

| Feature | Upstream `main` | mygo | Main locations |
|---|---|---|---|
| Start-page "usage tips" switch | Always shown | Can be turned off in Settings → Interface | `app/lib/state/settings_state.dart` (`chat_tips`), `app/lib/ui/chat/chat_screen.dart` |
| "Material & text" | Absent | Three controls: opacity / blur / text colour | `app/lib/state/appearance_state.dart`, `app/lib/ui/theme/*` |
| Looping live wallpaper (video) | Absent | Looping MP4/WebM | `app/lib/wallpaper/live_wallpaper.dart`, `app/lib/ui/wallpaper/video_wallpaper_editor_page.dart` |
| `.json` live wallpaper | Absent | `.jsonwall` scene bundles with day / dusk / night sets | `app/lib/wallpaper/scene_{document,engine,view}.dart`, [docs/json-wallpaper.md](docs/json-wallpaper.md) |
| Foreign Live2D models | `.moc3` only (Cubism 3+) | Also Cubism 2 (`.moc` + `model.json`); the `live2d.min.js` runtime is injected by the app | `app/assets/companion/live2d.min.js`, `app/assets/companion/stage.js`, [docs/live2d/README.md](docs/live2d/README.md) |
| "Convert Live2D model" wizard | Absent | In-app: pick a zip → preview/assign motions → build a pet pack or companion-room pack | [`app/lib/ui/pets/live2d_convert_page.dart`](app/lib/ui/pets/live2d_convert_page.dart) |
| Live2D pet sharpness | Bundled assets | Models render at screen density; textures stay crisp | `app/lib/pets/live2d_kit.dart`, `app/lib/ui/pets/pet_live2d_view.dart` |
| Pet overlay size | Shares the chat-page "size" | Two independent steps (`pet.overlay_size` / `pet.overlay_custom_height`) | `app/lib/pets/pet_prefs.dart` |
| Custom character image import | Absent | A pet's character can be a local image | `app/lib/pets/pet_library.dart` and friends |
| Balance whale pendant | Absent | Draggable balance widget above the composer: avatar / sounds / lines / custom image | `app/lib/ui/chat/pendant/whale_pendant.dart`, [docs/design/pendant.md](docs/design/pendant.md) |
| "Let AI make a pet" entry | Present | **Removed (scrapped)**, replaced by "Convert Live2D model"; the `/pet-theme` skill stays and is extended | `app/lib/ui/pets/pet_settings_page.dart` |
| `file_picker` | 13.4.x | Pinned to `13.3.0` + `android_file_picker 2.1.6` | `app/pubspec.yaml` |
| Voice capture | Assumes a recording exists when stopping | `stop()` is idempotent, safe with no recording | `app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/speech/CallCapture.kt` |
| Pet skill hosting | `pet-theme` on Android | Added to iOS and HarmonyOS | `app/ios/Runner/EngineSkills.swift`, `app/ohos/entry/src/main/ets/runtime/ManagedSkillCore.ets` |

---

## 3. What mygo adds

### 1. Interface: material & text, start-page tips switch

- "Material & text" lives in **Settings → Appearance**. Opacity and blur only affect glass panels and cards; text colour only affects text (optionally following the theme).
- The usage tips at the bottom of the start page ("hold send while generating to interject, queue or interrupt…") can be turned off in **Settings → Interface**; on by default.
- Both are wired into the settings search index, with Chinese and English strings kept in sync.

Files: `app/lib/state/appearance_state.dart`, `app/lib/ui/theme/{surfaces,glass,app_theme}.dart`, `app/lib/app.dart`, `app/lib/ui/settings/appearance/appearance_page.dart`, `app/lib/ui/settings/interface_page.dart`.

### 2. Wallpapers: looping video and `.json` scenes

Four wallpaper kinds are mutually exclusive (`enum WallpaperKind { gradient, image, video, json }`, persisted as `wallpaper_kind`):

- **Looping live wallpaper**: a local MP4/WebM (≤300 MB), fit or centre, with adjustable position; ExoPlayer on Android.
- **`.json` live wallpaper**: a single `.json` (≤20 MB) or a scene bundle (≤300 MB), switching day/dusk/night by system time; format in [docs/json-wallpaper.md](docs/json-wallpaper.md).
- Black bars above and below animated backgrounds are fixed; blur is baked into one image when the wallpaper is built and each frame draws just that image — no per-frame Gaussian blur (`app/lib/wallpaper/wallpaper_render.dart`).

### 3. Live2D: Cubism 2 support and the conversion wizard

- The companion stage accepts Cubism 2 models (`.moc` + `model.json`, including `*.mtn` motions); physics, pose, expressions and blinking are not executed and say so in the docs. Cubism 3+ stays on the `.moc3` path. The `live2d.min.js` runtime is injected by the app, so authors need not bundle it.
- The pet-page entry changed from "Let AI make a pet" to **"Convert Live2D model"** (`Live2dConvertPage`): pick a zip → read model/textures/motions/expressions → auto-match states by name → swap, skip or play-once → produce a pet pack (install directly) or a companion-room pack (save to Download, install in the companion room).
- Pet packs no longer require a `poster.png`: the converter writes no cover, and the app captures the first frame the stage draws (`app/lib/pets/live2d_kit.dart`).

### 4. Pets: overlay and custom characters

- The pet overlay outside the app has its own size, separate from the pet size inside the chat page (`botsPetOverlaySize` / `botsPetOverlayCustomSize`); the two no longer affect each other.
- Character images can be imported from a local picture; tap lag (repeated parsing and rebuilding) is fixed.
- The `pet-theme` skill is registered for iOS and HarmonyOS hosting (Android already had it upstream).

### 5. Balance whale pendant

A small whale above the composer: dragged to the left edge it faces outward; tap it for a line, hold the left/right buttons for press/release sounds.

- Three built-in options: avatar (`assets/pendant/whale_girl.png`), sounds (rubber duck `Ya1/Ya2`, sound set one `D1/D2`, mute), and bubble lines (one per row, editable, restorable).
- Can be swapped for a custom image and custom audio; it can fetch the balance (by key, showing "grant / top-up / balance running low") and, when unfocused or offline, shows status without errors.
- Position and size persist separately (`app/lib/state/pendant_options.dart`); docs in [docs/design/pendant.md](docs/design/pendant.md).

### 6. Miscellaneous

- `CallCapture.stop()` is idempotent: it returns cleanly when no session is recording instead of crashing on a null reference (`SpeechGates.kt` and `SpeechPlugin.kt` adjusted accordingly).
- The "Let AI make a pet" copy and its tests are gone; `pet_import_test.dart` now checks "tapping the entry opens the conversion page".
- `file_picker` is pinned at `13.3.0` (`android_file_picker 2.1.6`): 13.4.0's Android implementation is written in Kotlin and does not compile with the current AGP/Kotlin combination (`Unresolved reference` in `FileUtils.kt`).

---

## 4. Upstream content removed or replaced

| Upstream content | What mygo does | Why |
|---|---|---|
| The pet page's "Let AI make a pet" entry (`botsPetMake`) | Deleted, replaced by "Convert Live2D model" | The entry only typed `/pet-theme ` into the composer, a command the engine does not have; and the skill then only understood sprite assets, so foreign Live2D models had no path forward |
| Pet packs must carry `poster.png` | A model's first frame is enough | Foreign models rarely ship a cover |
| `.moc` (Cubism 2) always rejected | Import and display supported | Plenty of existing models are still Cubism 2, so the conversion bar was too high |

**The `/pet-theme` skill itself is not gone**: upstream's sprite-asset flow (`pet_theme_convert.py`, `pet_pack_check.py` — clawd-on-desk, GIF/APNG/WebP, frame folders, Aseprite, single images) coexists with the locally added Live2D flow (`live2d_pet_kit.py`), documented in [app/assets/skills/pet-theme/SKILL.md](app/assets/skills/pet-theme/SKILL.md). In other words: the page offers the wizard, and typing `/pet-theme` still lets the AI build one in conversation.

---

## 5. Project layout

```
app/            Flutter app (lib/ is Dart; android/ ios/ ohos/ are the three shells)
runtime/        Engine runtime and patches (versions pinned by pins.json)
packages/       Dependencies shipped with the repository
docs/           Design, guides, Live2D / pet / plugin docs
tooling/        Validation and replay tools
```

Added docs: [docs/json-wallpaper.md](docs/json-wallpaper.md), [docs/design/pendant.md](docs/design/pendant.md), [docs/design/pets.md](docs/design/pets.md) (updated for this branch), [docs/live2d/README.md](docs/live2d/README.md) (Cubism 2 added).

---

## 6. Build

Release builds use an out-of-tree script, `C:\tool\build-release.ps1` (Windows + Flutter SDK + Android SDK + a signing key):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\tool\build-release.ps1 -NoCopy -OutDir C:\tool\out
```

| Parameter | Default | Meaning |
|---|---|---|
| `-Package` | `io.dsh.go` | applicationId (changed only during the build, restored afterwards) |
| `-Version` | `1.2.1-beta` | versionName |
| `-Abi` | `arm64` | `arm64` / `x64` |
| `-Keystore` / `-KeyAlias` | `C:\tool\my-release-key.jks` / `my-key-alias` | Signing |
| `-StorePassword` / `-KeyPassword` | read from `key.properties` | Never written to disk or echoed |
| `-OutDir` / `-NoCopy` / `-BuildNumber` | — | Artifact destination, whether to copy, versionCode |
| `-DryRun` / `-SkipSourcePatches` | — | Print only / skip source patches |

What the script does: verify the `runtime/out` artifacts → apply 12 groups of embedded patches (wallpaper, Live2D, start-page tips, material & text, material tests, pet page fixes, pet sharpness, pet skill cover, model conversion, balance whale, conversion hardening, whale bubbles) → temporarily change applicationId and write `key.properties` → `flutter build apk` → check package name, ABI and signature with `aapt2` / `apksigner` → check whether the ONNX JNI classes survived → restore every temporary change byte-for-byte in `finally`.

> As of 2026-11-19 all 12 groups **already live in the repository** (commit `fd2f459ef`), so the script now only prints "already in the repository, skipping". If it ever prints "N places do not match (upstream changed the same region)", upstream has touched that code: merge it by hand once before running. The script deliberately refuses to skip silently.

Artifacts: `app/build/app/outputs/apk/<abi>/release/app-<abi>-release.apk`. Last verified build: `io.dsh.go` / `1.2.1-beta` / `arm64-v8a` / 222.5 MB / signature `CN=Silver Wolf` / ONNX JNI check passed / build exit code 0.

---

## 7. Development and checks

```powershell
cd app
flutter pub get
flutter analyze          # currently: 34 issues, all info, 0 errors / 0 warnings
flutter test             # see the environment notes below
```

- **l10n: only edit `app/lib/l10n/parts/*.arb`**, then run `python app/tool/l10n_merge.py` (regenerates `gen/` and `app_{zh,en}.arb`).
  Verify with `--check`: currently `✓ 76 parts, 8462 keys`.
- **User guides: only edit `docs/guide/`**, then run `python app/tool/guide_sync.py`; `--check` currently reports `38 files checked`.
- **Test fonts**: golden tests want `/usr/share/fonts/noto-cjk/NotoSansCJK-*.ttc` (a Linux path). On Windows, point
  `DSH_TEST_FONT_DIR=<dir>` at substitute fonts — but the screenshots will always differ, so **golden results are not evidence of anything on Windows**.
- Windows adds three fixed false failures: path separators (expected `/`, actual `\`), symlink creation `errno 1314`, and CRLF checkouts producing different SHA-256 values (after LF normalisation they match the expected hashes).
- Last targeted run (`test/safe_mode test/runtime test/l10n test/launch test/phone test/pets`): **1207 passed / 122 failed**, every failure falling into the environment causes above (mostly golden pixel differences).

---

## 8. Merging upstream (maintainer notes)

```powershell
git fetch upstream
git merge --no-ff upstream/main -m "Merge upstream/main into harmonyos"
```

1. Resolve conflicts as "local features first, keep upstream wherever possible"; then run `flutter analyze` and both l10n / guide `--check`s.
2. Run the build script once more: it is clean only when everything prints "already in the repository, skipping"; any "N places do not match" must be merged by hand per the docs first.
3. Re-confirm the upstream content mygo replaced (especially the "Let AI make a pet" entry): `git grep -n botsPetMake -- app` should be empty.
4. Reference rollback point: tag `pre-upstream-merge-20261119`.

---

## 9. License

Inherited from upstream. Third-party components and asset licences: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), [ASSETS.md](ASSETS.md).
