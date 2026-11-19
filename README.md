# mygo

[English](README.en.md) · 简体中文

## 项目说明

mygo 是 [DSH Go](https://github.com/ccch1mneyyy/dsh-Go) 的 Android 客户端分支，代码在上游仓库基础上同步开发，并包含以下功能。DSH Go 是 DeepSeek Harness 的移动端客户端，负责连接远端 DSH 实例、在手机上运行会话与工具。

- 仓库：<https://github.com/shouVdao/dsh-Go>
- 默认分支：`harmonyos`
- 上游基线：`9ad11167c`（2026-11-19）
- 应用 ID：`io.github.ccch1mneyyy.dsh_app`；最低 Android 8.0（API 26），targetSdk 28
- 平台：Android 为主；`app/` 同时保留 iOS 与鸿蒙（OpenHarmony）实现

## 功能

### 界面与外观

- **起始页使用提示开关**：设置 → 界面 → 起始页。关闭后，新会话的起始页不再渲染使用提示占位。
  - `app/lib/state/settings_state.dart`（`chatTips`，存储键 `chat_tips`）
  - `app/lib/ui/chat/chat_screen.dart`（按开关传入 `tips`）
- **材质与文字**：设置 → 外观 → 材质。浮层与卡片使用半透明玻璃材质，可调不透明度、模糊半径、字体颜色，并可跟随主题。
  - `app/lib/state/appearance_state.dart`
  - `app/lib/ui/settings/appearance/appearance_page.dart`
- **宠物悬浮窗尺寸**：设置 → 桌面宠物 → 悬浮窗大小。可为 App 外的宠物窗口选择更小的高度；聊天页里的宠物大小单独调整。
  - `app/lib/pets/pet_prefs.dart`（`overlaySize`、`overlayCustomHeight`）
  - `app/lib/ui/pets/overlay_settings_tile.dart`

### 壁纸

- **循环动态壁纸**：设置 → 外观 → 壁纸 → 循环动态壁纸。导入视频文件后按循环播放，无进度条与声音控件。
  - `app/lib/wallpaper/live_wallpaper.dart`
  - `app/lib/ui/wallpaper/video_wallpaper_editor_page.dart`
- **`.json` 动态壁纸**：设置 → 外观 → 壁纸 → `.json` 动态壁纸。导入场景包后按 `day`/`dusk`/`night` 时段切换画面，支持背景、图片、文字等节点。
  - `app/lib/wallpaper/scene_document.dart`、`scene_engine.dart`、`scene_view.dart`
  - 格式说明：`docs/json-wallpaper.md`

### 宠物与 Live2D

- **Cubism 2 模型**：宠物页可导入 `.moc` 模型与 `model.json`。运行库 `live2d.min.js` 由 App 注入，支持 `*.mtn` 动作；物理、姿势、表情与眨眼不执行。
  - `app/lib/pets/live2d_kit.dart`
  - `app/lib/pets/pet_live2d_install.dart`
- **模型清晰度**：按屏幕密度与舞台尺寸选择立方体纹理，优先 1024，缺失时回落到 512/256。宠物包不写入 `poster.png`，首帧由舞台截图。
  - `app/lib/pets/live2d_kit.dart`
- **转换 Live2D 模型**：宠物页入口，在 App 内把 Live2D 模型转换为宠物包，包含封面、尺寸与校验。
  - `app/lib/ui/pets/live2d_convert_page.dart`
- **`pet-theme` 技能托管**：Android、iOS 与鸿蒙三端都会把 `app/assets/skills/pet-theme` 复制进运行时的用户技能目录。技能内含精灵素材转换（GIF/ APNG/ WebP/ 逐帧/ Aseprite/ 单图，`pet_theme_convert.py`）与 Live2D 转换（`live2d_pet_kit.py`）。
  - `app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/runtime/ManagedSkillInstaller.kt`
  - `app/ios/Runner/EngineSkills.swift`
  - `app/ohos/entry/src/main/ets/runtime/ManagedSkillCore.ets`

### 挂件

- **余额小鲸鱼**：对话页悬浮挂件，显示余额与谷/峰倒计时。点她弹出余额气泡，再点气泡换成台词气泡并逐句切换；按住可拖动并吸附到屏幕边缘，位置会保存。音效可在设置里更换或关闭。
  - `app/lib/ui/chat/pendant/whale_pendant.dart`
  - `app/lib/state/pendant_options.dart`
  - 设计与行为说明：`docs/design/pendant.md`
- **自定义角色图**：挂件设置可导入自己的角色图，图片复制到 App 私有目录后使用；镜像翻转只作用于内置图。
  - `app/lib/state/settings_state.dart`（`pendantArt`、`pendantArtPath`）
  - `app/lib/ui/settings/appearance/pendant_section.dart`

### 构建与兼容

- **依赖版本固定**：`file_picker` 固定 13.3.0、`android_file_picker` 固定 2.1.6，因为 13.4.0 对应的 `android_file_picker` 2.2.0 无法通过 Kotlin 编译。
  - `app/pubspec.yaml`

## 与上游 main 的差异

| 项目 | 上游 main | mygo | 主要位置 |
| --- | --- | --- | --- |
| 起始页使用提示 | 固定显示 | 可在设置中关闭 | `app/lib/state/settings_state.dart`、`app/lib/ui/chat/chat_screen.dart` |
| 外观材质 | 无 | 材质与文字：不透明度、模糊、字体颜色、跟随主题 | `app/lib/state/appearance_state.dart` |
| 壁纸种类 | 渐变、图片 | 增加循环视频与 `.json` 场景包 | `app/lib/state/wallpaper_state.dart`（`WallpaperKind`） |
| Live2D 模型 | Cubism 3 | 增加 Cubism 2（`.moc` + `model.json`） | `app/lib/pets/live2d_kit.dart` |
| 宠物页入口 | 「让 AI 做一只宠物」，输入 `/pet-theme` | 「转换 Live2D 模型」向导 | `app/lib/ui/pets/pet_settings_page.dart`、`live2d_convert_page.dart` |
| 宠物包封面 | 必须有 `poster.png` | 无封面时取舞台首帧 | `app/lib/pets/live2d_kit.dart` |
| 宠物悬浮窗 | 固定尺寸 | 可选更小尺寸 | `app/lib/pets/pet_prefs.dart` |
| 余额挂件 | 无 | 可开关的余额小鲸鱼，可导入自定义角色图 | `app/lib/ui/chat/pendant/whale_pendant.dart`、`app/lib/state/settings_state.dart` |
| `pet-theme` 技能 | 仅 Android 托管 | Android、iOS、鸿蒙三端托管，并含 Live2D 流程 | `ManagedSkillInstaller.kt`、`EngineSkills.swift`、`ManagedSkillCore.ets` |
| `file_picker` | 13.4.0 | 固定 13.3.0 / `android_file_picker` 2.1.6 | `app/pubspec.yaml` |

## 项目结构

| 路径 | 内容 |
| --- | --- |
| `app/` | Flutter 界面、Android Kotlin 实现、iOS Swift/WidgetKit 实现与鸿蒙 ArkTS 实现 |
| `packages/dsh_client/` | DSH Web API 的 Dart 客户端 |
| `packages/dsh_remote/` | DSH Remote 的 Dart 客户端 |
| `runtime/` | Android Linux 运行时、iOS 运行时特化、引擎补丁与 App 桥接 |
| `docs/` | 设计文档、用户指南与宠物/Live2D 制作说明 |
| `tooling/` | 工具链安装、APK/iOS 构建与诊断脚本 |

## 复现方式

以下流程与上游一致，面向 Linux x86_64。需要 Bash、Git、curl、tar、unzip、xz、Python 3、zstd 与常见 GNU 命令；工具链脚本会安装 Temurin JDK 17、Flutter 3.47.7 与 Android SDK/NDK。App 要求的 Dart 版本见 `app/pubspec.yaml`。

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

- 工具链默认安装到 `~/dev`，可用 `DEV_ROOT` 指定目录；脚本会复用已有安装，构建前需核对版本。
- `runtime/build-runtime.sh` 生成运行时包，产物是 App 的构建输入，需要联网下载依赖并校验固定版本。
- `DSH_BETA_TOKEN_FILE=` 表示不嵌入任何内测通道令牌；`--keep-daemon` 保留 Gradle daemon。
- x86_64 构建：`bash runtime/build-runtime.sh x86_64`，然后 `DSH_BETA_TOKEN_FILE= bash tooling/build-apk.sh -f x64 --keep-daemon`。
- 只查看构建命令不执行：`DSH_BETA_TOKEN_FILE= bash tooling/build-apk.sh --dry-run -f all`。
- 产物位于 `app/build/app/outputs/flutter-apk/app-arm64-release.apk`。
- 未配置 `app/android/key.properties` 时，release 构建使用 debug 签名，不能覆盖使用其他签名的安装包；发布密钥与 `key.properties` 不应提交到仓库。
- Windows 下上述脚本需在 WSL 或 Git Bash 中运行；已生成运行时包后，也可直接执行 `cd app && flutter build apk --release --target-platform android-arm64`。

## 开发与自检

```bash
cd app
flutter pub get
flutter analyze
flutter test
```

- 修改 `app/lib/l10n/parts/*.arb` 后运行 `python app/tool/l10n_merge.py` 生成 `app/lib/l10n/gen/`，不要手改生成文件。
- 修改 `docs/guide/` 后运行 `python app/tool/guide_sync.py`。
- 字体与 golden 测试需要 Noto CJK 字体，默认读取 `/usr/share/fonts/noto-cjk`，可用环境变量 `DSH_TEST_FONT_DIR` 指定目录，目录中需有 `NotoSansCJK-Light.ttc`、`NotoSansCJK-Regular.ttc`、`NotoSansCJK-Bold.ttc`。
- 在 Windows 上，部分测试会因路径分隔符、符号链接权限（`errno 1314`）与 CRLF 换行导致断言失败，属环境差异，以 Linux 结果为准。

## 开源协议

本项目跟随上游采用 [GNU Affero General Public License v3.0](LICENSE)。修改与再发布须遵循该许可证的条款，保留版权、许可与修改声明。

- `sdk/` 与 `examples/` 保持 MIT 许可。
- 第三方代码与素材按各自声明，来源见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
- DSH Go 名称与标识、Deepy 小鲸鱼、鲸娘形象不在 AGPL 授权范围内，使用条件见 [ASSETS.md](ASSETS.md)。
