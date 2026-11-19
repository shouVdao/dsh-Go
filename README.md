# mygo

[English](README.en.md) · 简体中文

**mygo** 是 [ccch1mneyyy/dsh-Go](https://github.com/ccch1mneyyy/dsh-Go) 的个人复刻分支（分支 `harmonyos`，仓库仍在 `shouVdao/dsh-Go`）。
上游 `main` 是主线，mygo 一边跟随上游，一边维护一批上游**没有**的界面、壁纸、Live2D、宠物与挂件改动。

- 上游：<https://github.com/ccch1mneyyy/dsh-Go>（默认分支 `main`）
- 本仓库：<https://github.com/shouVdao/dsh-Go>（分支 `harmonyos`）
- 当前基线：已并入上游 `9ad11167c`，累计 **141 个上游提交**，两次合并均**零冲突**；mygo 领先 4 个提交
- 与上游的差异：**115 个文件**（新增 36、修改 79、删除 0），`+17323 / −487`

> 上游原来的两份落地页（中文 `README.md`、英文 `README.en.md`）已由这份分支说明替换；原文仍可用 `git show upstream/main:README.md`、`git show upstream/main:README.en.md` 读到，功能、安装与贡献的细节见 [docs/](docs/)、[CONTRIBUTING.md](CONTRIBUTING.md)。本文件只讲**这个分支和主分支的区别**。

---

## 一、与主分支的关系

| 项 | 主分支 `main`（上游） | mygo（本分支 `harmonyos`） |
|---|---|---|
| 定位 | 主线 | 复刻 + 本地增强，跟随上游合并 |
| 合并策略 | — | 定期 `git merge upstream/main`，冲突时**本地功能优先**，尽量保留上游新功能 |
| 构建 | 常规 Flutter/Gradle | 另有一份仓库外的构建脚本（见 [第六节](#六构建)），签名、改包名、核对产物一条龙 |
| 测试基线 | Linux + 自带 Noto CJK 字体 | 与上游相同的测试；本机跑 golden 需要替代字体（见 [第七节](#七开发与自检)） |

上游默认分支是 `main`，本分支长期基于 `harmonyos` 线；两次合并分别吃进 `95588b696`（139 个提交）和 `9ad11167c`（2 个提交，PRoot 失败后提供 tawcroot 启动）。合并提交：`aa6827a82`、`b9074649a`。

---

## 二、差异总览

| 功能 | 上游 `main` | mygo | 主要位置 |
|---|---|---|---|
| 起始页「使用提示」开关 | 固定显示 | 设置 → 界面 可关 | `app/lib/state/settings_state.dart`（`chat_tips`）、`app/lib/ui/chat/chat_screen.dart` |
| 界面「材质与文字」 | 无 | 不透明度 / 模糊 / 字体颜色三项 | `app/lib/state/appearance_state.dart`、`app/lib/ui/theme/*` |
| 循环动态壁纸（视频） | 无 | MP4/WebM 循环播放 | `app/lib/wallpaper/live_wallpaper.dart`、`app/lib/ui/wallpaper/video_wallpaper_editor_page.dart` |
| `.json` 动态壁纸 | 无 | 场景包格式 `.jsonwall`，白天/黄昏/晚上三套 | `app/lib/wallpaper/scene_{document,engine,view}.dart`、[docs/json-wallpaper.md](docs/json-wallpaper.md) |
| 外来 Live2D 模型 | 只认 `.moc3`（Cubism 3+） | 另支持 Cubism 2（`.moc` + `model.json`），运行库 `live2d.min.js` 随 App 注入 | `app/assets/companion/live2d.min.js`、`app/assets/companion/stage.js`、[docs/live2d/README.md](docs/live2d/README.md) |
| 「转换 Live2D 模型」向导 | 无 | App 内选 zip → 预览/配动作 → 生成宠物包或伙伴小屋包 | [`app/lib/ui/pets/live2d_convert_page.dart`](app/lib/ui/pets/live2d_convert_page.dart) |
| Live2D 宠物清晰度 | 内置素材 | 模型按屏幕密度渲染，贴图不再糊 | `app/lib/pets/live2d_kit.dart`、`app/lib/ui/pets/pet_live2d_view.dart` |
| 宠物悬浮窗大小 | 与聊天页共用「大小」 | 独立两档（`pet.overlay_size` / `pet.overlay_custom_height`） | `app/lib/pets/pet_prefs.dart` |
| 自定义角色图导入 | 无 | 宠物角色可换成本地图片 | `app/lib/pets/pet_library.dart` 等 |
| 余额小鲸鱼挂件 | 无 | 输入框上方可拖拽的余额挂件：头像/音效/台词/自定义图 | `app/lib/ui/chat/pendant/whale_pendant.dart`、[docs/design/pendant.md](docs/design/pendant.md) |
| 「让 AI 做一只宠物」入口 | 有 | **已移除（废案）**，换成「转换 Live2D 模型」；`/pet-theme` 技能保留并扩展 | `app/lib/ui/pets/pet_settings_page.dart` |
| `file_picker` | 13.4.x | 钉 `13.3.0` + `android_file_picker 2.1.6` | `app/pubspec.yaml` |
| 语音采集 | 停止时假定有录音 | `stop()` 幂等，无录音也安全收尾 | `app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/speech/CallCapture.kt` |
| 宠物技能托管 | Android 有 `pet-theme` | 补到 iOS / 鸿蒙两端 | `app/ios/Runner/EngineSkills.swift`、`app/ohos/entry/src/main/ets/runtime/ManagedSkillCore.ets` |

---

## 三、新增功能详解

### 1. 界面：材质与文字、起始页提示开关

- 「材质与文字」在 **设置 → 外观**，三项分别作用：不透明度与模糊只改玻璃面板/卡片，字体颜色只改文字（可跟随主题）。
- 起始页底部的使用提示（「生成中长按发送键，可以插话、排队或打断……」）可以在 **设置 → 界面** 关掉，默认开。
- 两项都接入了设置搜索索引，中英文文案同步。

涉及：`app/lib/state/appearance_state.dart`、`app/lib/ui/theme/{surfaces,glass,app_theme}.dart`、`app/lib/app.dart`、`app/lib/ui/settings/appearance/appearance_page.dart`、`app/lib/ui/settings/interface_page.dart`。

### 2. 壁纸：循环视频与 `.json` 场景

四种壁纸互斥（`enum WallpaperKind { gradient, image, video, json }`，持久化键 `wallpaper_kind`）：

- **循环动态壁纸**：本机 MP4/WebM（≤300 MB），可「填满 / 居中」，可调显示位置；Android 走 ExoPlayer。
- **`.json` 动态壁纸**：单个 `.json`（≤20 MB）或场景包（≤300 MB），按系统时间切白天/黄昏/晚上；格式见 [docs/json-wallpaper.md](docs/json-wallpaper.md)。
- 修掉了动态背景上下的黑边；模糊在构建壁纸时烘成一张图，每帧只画这张图，不做实时高斯模糊（`app/lib/wallpaper/wallpaper_render.dart`）。

### 3. Live2D：Cubism 2 兼容 + 转换向导

- 伴生舞台支持 Cubism 2 模型（`.moc` + `model.json`，含 `*.mtn` 动作），物理、姿势、表情与眨眼不执行并在文档里写明；Cubism 3+ 仍然是 `.moc3` 路线。运行库 `live2d.min.js` 由 App 注入，作者不用自带。
- 宠物页入口从「让 AI 做一只宠物」换成**「转换 Live2D 模型」**（`Live2dConvertPage`）：选 zip → 读出模型/贴图/动作/表情 → 按名字自动匹配各状态 → 可互换、可不实现、可只播一次 → 生成宠物包（装上即用）或伙伴小屋包（存到 Download 后在伙伴小屋安装）。
- 宠物包不再强制带 `poster.png`：转换器不写封面，模型第一次显示时 App 截下那一帧当封面（`app/lib/pets/live2d_kit.dart`）。

### 4. 宠物：悬浮窗与自定义角色

- App 外宠物悬浮窗的大小与聊天页里的宠物大小分开（`botsPetOverlaySize` / `botsPetOverlayCustomSize`），互不影响。
- 角色图可导入本地图片；修了点按卡顿（重复解析与重建）。
- `pet-theme` 技能补齐 iOS / 鸿蒙托管名单（Android 上游已有）。

### 5. 余额小鲸鱼挂件

输入框上方的小鲸鱼：拖到左侧后自动朝边，点一下说一句台词，长按左右键播按压/回弹音效。

- 三个内置选项：头像（`assets/pendant/whale_girl.png`）、音效（小黄鸭 `Ya1/Ya2`、音效一 `D1/D2`、静音）、气泡台词（一行一句，可编辑、可恢复默认）。
- 可换成自定义图片、自定义音频；能查余额（按密钥，显示「赠金 / 充值 / 余额不多了」），失焦或离线时只显示状态不报错。
- 位置、大小独立持久化（`app/lib/state/pendant_options.dart`），文档见 [docs/design/pendant.md](docs/design/pendant.md)。

### 6. 杂项

- `CallCapture.stop()` 改成幂等：没有正在录的会话时直接收尾，不再空引用崩溃（`SpeechGates.kt`、`SpeechPlugin.kt` 跟随调整）。
- 宠物页「让 AI 做一只宠物」的文案与测试一并删除，`pet_import_test.dart` 改为「点入口进转换页」。
- `file_picker` 钉在 `13.3.0`（`android_file_picker 2.1.6`）：13.4.0 的 Android 实现是 Kotlin 写法，当前 AGP/Kotlin 组合编不过（`FileUtils.kt` 里 `Unresolved reference`）。

---

## 四、被移除 / 替换的上游内容

| 上游内容 | mygo 的处理 | 原因 |
|---|---|---|
| 宠物页「让 AI 做一只宠物」入口（`botsPetMake`） | 删除，改为「转换 Live2D 模型」 | 入口只是把 `/pet-theme ` 写进输入框，引擎里没有这条命令；且该技能当时只认精灵素材，对外来 Live2D 模型没有下文 |
| 宠物包必须带 `poster.png` | 有模型首帧就够 | 外来模型通常没有封面 |
| `.moc`（Cubism 2）一律拒收 | 支持导入与显示 | 大量现成模型仍是 Cubism 2，转换门槛太高 |

**`/pet-theme` 技能本身没有删**：上游的精灵素材流程（`pet_theme_convert.py`、`pet_pack_check.py`，支持 clawd-on-desk、GIF/APNG/WebP、逐帧、Aseprite、单图）与本地补的 Live2D 流程（`live2d_pet_kit.py`）并存，写在 [app/assets/skills/pet-theme/SKILL.md](app/assets/skills/pet-theme/SKILL.md)。也就是说：页面上点的是向导，想边聊边让 AI 做，敲 `/pet-theme` 仍然可以。

---

## 五、项目结构

```
app/            Flutter 应用（lib/ 是 Dart，android/ ios/ ohos/ 是三端壳）
runtime/        引擎运行时与补丁（pins.json 锁版本）
packages/       随仓库分发的依赖
docs/           设计、指南、Live2D/宠物/插件文档
tooling/        校验与回放工具
```

新增文档：[docs/json-wallpaper.md](docs/json-wallpaper.md)、[docs/design/pendant.md](docs/design/pendant.md)、[docs/design/pets.md](docs/design/pets.md)（已按分支更新）、[docs/live2d/README.md](docs/live2d/README.md)（补 Cubism 2）。

---

## 六、构建

正式包用仓库外的脚本 `C:\tool\build-release.ps1`（Windows + Flutter SDK + Android SDK + 签名密钥）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\tool\build-release.ps1 -NoCopy -OutDir C:\tool\out
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Package` | `io.dsh.go` | 改 applicationId（只在构建期改，结束还原） |
| `-Version` | `1.2.1-beta` | versionName |
| `-Abi` | `arm64` | `arm64` / `x64` |
| `-Keystore` / `-KeyAlias` | `C:\tool\my-release-key.jks` / `my-key-alias` | 签名 |
| `-StorePassword` / `-KeyPassword` | 读 `key.properties` | 不落盘、不回显 |
| `-OutDir` / `-NoCopy` / `-BuildNumber` | — | 产物去向、是否拷贝、versionCode |
| `-DryRun` / `-SkipSourcePatches` | — | 只打印 / 不打源码补丁 |

脚本做什么：核对 `runtime/out` 产物 → 打 12 组内嵌补丁（壁纸、Live2D、起始页提示、材质与文字、材质测试、宠物页修复、宠物清晰度、宠物技能封面、模型转换、余额小鲸鱼、转换补强、鲸鱼气泡）→ 临时改 applicationId、写 `key.properties` → `flutter build apk` → `aapt2` / `apksigner` 核对包名、ABI、签名 → 判断 ONNX JNI 类是否保留 → `finally` 里逐字节还原所有临时改动。

> 2026-11-19 起，这 12 组改动**已经全部落进仓库**（提交 `fd2f459ef`），脚本再跑只会输出「已在仓库里，跳过」。若某次输出「N 处对不上（上游改过同一段）」，说明上游动了同一段代码，需要先手动合一次再跑，脚本故意不静默跳过。

产物：`app/build/app/outputs/apk/<abi>/release/app-<abi>-release.apk`。最近一次验证构建：`io.dsh.go` / `1.2.1-beta` / `arm64-v8a` / 222.5 MB / 签名 `CN=Silver Wolf` / ONNX JNI 检查通过 / 构建退出码 0。

---

## 七、开发与自检

```powershell
cd app
flutter pub get
flutter analyze          # 当前：34 issues，全部 info，0 error / 0 warning
flutter test             # 见下方环境说明
```

- **l10n 只改 `app/lib/l10n/parts/*.arb`**，然后 `python app/tool/l10n_merge.py`（生成 `gen/` 与 `app_{zh,en}.arb`）。
  `--check` 可验证：当前 `✓ 76 parts, 8462 keys`。
- **用户指南**只改 `docs/guide/`，然后 `python app/tool/guide_sync.py`；`--check` 当前 `38 files checked`。
- **测试字体**：golden 测试要 `/usr/share/fonts/noto-cjk/NotoSansCJK-*.ttc`（Linux 路径）。Windows 上可用
  `DSH_TEST_FONT_DIR=<目录>` 指向替代字体，但截图必有像素差，**golden 结果不能作为判定依据**。
- Windows 上另有三类固定的假失败：路径分隔符（期望 `/`、实际 `\`）、建符号链接 `errno 1314`、CRLF 检出导致的 SHA-256 不一致（LF 归一后与期望值一致）。
- 最近一次定向测试（`test/safe_mode test/runtime test/l10n test/launch test/phone test/pets`）：**1207 通过 / 122 失败**，失败全部落在上面几类环境原因里（golden 像素差为主）。

---

## 八、合并上游的流程（维护者备忘）

```powershell
git fetch upstream
git merge --no-ff upstream/main -m "Merge upstream/main into harmonyos"
```

1. 冲突按「本地功能优先，尽量保住上游」解；解完跑 `flutter analyze`，再看 l10n / guide 两个 `--check`。
2. 重跑一次构建脚本：全部「已在仓库里，跳过」才算干净；任何「N 处对不上」都要先按文档手合。
3. 上表里被 mygo 替换的上游内容（尤其「让 AI 做一只宠物」入口）需要再确认一次：`git grep -n botsPetMake -- app` 应为空。
4. 参考回滚点：标签 `pre-upstream-merge-20261119`。

---

## 九、许可

沿用上游。第三方组件与素材授权见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)、[ASSETS.md](ASSETS.md)。
