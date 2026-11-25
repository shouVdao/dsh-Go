# .json 动态壁纸开发指南

设置 › 主题 › 壁纸 里的 **.json 动态壁纸**是一个纯 Flutter 画的声明式场景：一个 `.json` 文件描述背景、图层和时间线，运行时不加载 WebView、不执行脚本、不支持 Wallpaper Engine 的 `.pkg`。同一份文件还能写多套场景，按**系统时间**在白天、黄昏、晚上之间自动切换。

场景可以只是一个文件，也可以打成一个**场景包**（`.jsonwall` / `.zip`）：包里放 `manifest.json` 和素材，某个时段的背景可以是一段**包内视频**，渐变、光斑、图片、粒子这些图层照旧叠在视频上面。

这份文档写给后面做壁纸的人：文件怎么放、字段怎么用、哪些写法会被拒绝、真机上怎么验证。代码在 `app/lib/wallpaper/`：

| 文件 | 管什么 |
| --- | --- |
| `scene_document.dart` | 格式模型 + 校验：`SceneDocument.parse`，所有报错都是中文，直接显示给用户 |
| `scene_engine.dart` | 绘制：`SceneEngine`（`ChangeNotifier`）按 depth 从远到近画图层、跑粒子；`paintBackground = false` 时让出背景给视频 |
| `scene_view.dart` | 运行时：`JsonWallpaperView`，一个 `Ticker` 驱动引擎，解码图片、按时段开关包内视频 |
| `live_wallpaper.dart` | 模型与导入：`JsonWallpaper`、`LiveWallpaperImport.pickJson` / `adopt`（单文件或解压场景包） |

## 1. 先跑起来

- 内置示例：`app/assets/wallpapers/aurora.json`（`JsonWallpaper.bundled = 'asset:assets/wallpapers/aurora.json'`）。没选过文件时，点 **.json 动态壁纸** 就显示它，所以第一个画面永远不是空白。
- 自己的文件：设置 › 主题 › 壁纸 › .json 动态壁纸 › **更换 .json 文件**，从系统文件选择器里挑一个 `.json`（≤20 MB）或一个场景包 `.jsonwall` / `.zip`（≤300 MB，见 §2 的「场景包」）。单文件会被复制成 `…/wallpaper/scene-<时间戳>.json`；场景包会被解压成 `…/wallpaper/scene-<时间戳>/`。换新的会删掉旧的；原文件之后挪走也不影响。
  - 选择器**不按扩展名过滤**：Android 的 `MimeTypeMap` 里没有 `jsonwall` 这个扩展名，按扩展名过滤时 `.jsonwall` 会被系统当成 `application/octet-stream` 灰掉、只剩 `.json` / `.zip` 可选。所以这里是任意文件，由 App 自己读文件头判断——zip 魔数（`PK\x03\x04`）就是场景包，其他按 UTF-8 的 `.json` 解析；既不是 zip 也不是 `.json` 的文件会提示「只支持 .json 文件或场景包（.jsonwall / .zip）」。换句话说：**包的扩展名随便叫**，`.jsonwall`、`.zip`、`.scene` 都行，只别改成看起来像 `.json` 的名字。
- 看效果：点 **预览**（示例对话盖在壁纸上），或者直接回首页。文件解析失败会在选择时弹出提示，例如「这个 .json 壁纸有问题：timeline.target 必须是 "图层id.属性"」——冒号后面是具体位置。
- 改内置示例：编辑 `app/assets/wallpapers/aurora.json` 后热重启；`pubspec.yaml` 里 `- assets/wallpapers/` 已经包含整个目录，新增文件不用改 pubspec。

## 2. 文件结构

顶层字段：

```json
{
  "schemaVersion": 1,
  "id": "aurora",
  "name": "极光天幕",
  "duration": 20,
  "loop": true,
  "render": { "fpsCap": 30 },
  "background": { "colors": ["#A8D8FF", "#D6ECFF", "#FFF4E0"], "stops": [0, 0.55, 1], "angle": 90 },
  "video": "assets/day.mp4",
  "videos": { "dusk": "assets/dusk.mp4", "night": { "src": "assets/night.mp4", "fit": "cover" } },
  "layers": [ ... ],
  "timeline": [ ... ],
  "tint": null,
  "periods": { "dusk": { ... }, "night": { ... } }
}
```

| 字段 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `schemaVersion` | int | 必填 | 当前为 **1**。写成 2 会被拒绝：`schemaVersion 2 高于本应用支持的 1，请升级应用`。写 0 或负数同样拒绝。 |
| `id` | string | `"scene"` | 标识，用于日志；不影响画面。 |
| `name` | string | `""` | 显示名，暂未展示在界面上，留作之后的作品列表。 |
| `duration` | number | `0` | 秒。**只是说明**：时间线自己按关键帧循环，不需要和它对齐。 |
| `loop` | bool | `true` | 说明字段；场景本来就是无限循环的。 |
| `render.fpsCap` | int | `30` | 24…60，超出会被夹回。低端机建议 24–30。 |
| `background` | 颜色或渐变 | — | 铺满屏幕的第一层，见下。有时段视频时这一层不画（视频就是背景）。 |
| `video` | 路径或对象 | 无 | 整个场景的背景视频，见「视频」。 |
| `videos` | 对象 | 无 | 按时段的背景视频，键是 `day` / `dusk` / `night`，优先于 `periods.<时段>.video`。 |
| `layers` | 数组 | `[]` | 图层，见 §3。视频在图层**下面**。 |
| `timeline` | 数组 | `[]` | 轨道，见 §4。 |
| `tint` | 颜色 | 无 | 盖在所有图层上的整屏色（带 alpha 才有意义），用来统一冷/暖调。 |
| `periods` | 对象 | 无 | 时段覆盖，见 §5。 |

### 视频

```json
"video": "assets/loop.mp4",
"videos": { "dusk": "assets/dusk.webm", "night": { "src": "assets/night.mp4", "fit": "cover", "opacity": 0.8 } }
```

- `src` 只能是**包内相对路径**或 `asset:`（App 自带的资源）。写成 `data:` 会报「不能内嵌视频，请把视频放进压缩包」——视频太大，不该塞进 JSON 文本里。
- 支持的容器：MP4 / MOV（`ftyp` 头）、WebM / MKV（EBML 头）。认不出就在导入时报「压缩包里有无法播放的视频」级别的问题，不会等到运行时黑屏。
- `fit`：`cover`（默认，填满不拉伸）、`contain`（整段可见，可能留边）、`fill`（拉伸）。`loop` 固定循环播放、`opacity` 0…1。
- 视频自动**静音**播放，App 切到后台暂停、回来继续；系统关闭动画时不播（只留第一帧）。
- 哪个时段用哪段视频的优先级：`videos.<时段>` → `periods.<时段>.video` → 根场景的 `video` → 没有视频（画 `background`）。

### 场景包

把 `manifest.json`（内容就是上面这个 JSON）和素材放一起，压成 zip，扩展名 `.jsonwall` 或 `.zip`：

```
scene.jsonwall
├── manifest.json
├── assets/
│   ├── day.mp4
│   ├── dusk.mp4
│   ├── night.mp4
│   └── sky.webp
```

- 导入时会**整包解压**到私有目录，然后按 manifest 里出现的每个相对路径逐个确认文件存在；少一个就拒绝并提示「压缩包里缺少 assets/dusk.mp4」，避免用的时候才发现是洞。
- 图片也可以用包内相对路径（`"src": "assets/sky.webp"`），不再强制 base64。
- 包里必须先有 `manifest.json`；如果没有，但根目录只有一个 `.json`，那个就当作 manifest。
- 上限：整包 300 MB、最多 500 个文件、单个文件解压后 120 MB、解压比超过 100:1 直接拒绝（防 zip 炸弹）。压缩包内带 `..`、绝对路径、空目录的条目一律拒绝。


### 颜色

`"#RRGGBB"` 或 `"#AARRGGBB"`，大小写都行。写别的会报 `背景色颜色格式不对`——报错里带字段名，按名字找就行。

### 渐变

三种写法都接受：

```json
"background": "#0F1D33"
"background": { "from": "#05070F", "to": "#17324F" }
"background": { "colors": ["#05070F", "#0F1D33", "#17324F"], "stops": [0, 0.5, 1], "angle": 100 }
```

`angle` 是角度：`0` 左→右，`90` 上→下，`180` 右→左。`type: "radial"` 配 `center: [x, y]`（0…1 的相对坐标）变径向渐变。`stops` 个数要和 `colors` 对上，不给就均匀分布。

### 区域（`area`）

图层的 `area` 是**相对屏幕的矩形**，写成 `[left, top, right, bottom]`，`0…1` 是整屏，允许超出到 `±4`：用来做「月亮有一半在屏幕外」「光斑从右下角透进来」这种效果。

```json
"area": [0.55, -0.05, 1.0, 0.45]
```

不写就是整屏 `[0, 0, 1, 1]`。

## 3. 图层

每个图层都有的字段：

| 字段 | 说明 |
| --- | --- |
| `id` | 必填，唯一。时间线用 `"<id>.<属性>"` 找到它。 |
| `kind` | `gradient` / `glow` / `image` / `particles` / `group`，别的值直接报错（报错里列出这五个）。 |
| `depth` | `0`（远）…`1.2`（近），按升序绘制。近的盖住远的。 |
| `opacity` | `0…1`，默认 `1`。 |
| `visible` | 布尔，默认 `true`；时间线可以把它当 `0/1` 来拨。 |
| `x` / `y` | 逻辑像素的静态偏移，时间线会在它之上累加。 |
| `scale` | `0.05…20`，以图层区域中心缩放。 |
| `rotation` | 角度，顺时针，以区域中心旋转。 |
| `area` | 见上。 |

### `gradient`：一块渐变

```json
{ "id": "sky", "kind": "gradient", "depth": 0, "area": [0, 0, 1, 1],
  "colors": ["#FF9A62", "#D4685F", "#3B2A5C"], "stops": [0, 0.45, 1], "angle": 100 }
```

字段同 `background`（`colors`/`from`/`to`/`stops`/`angle`/`type`/`center`）。

### `glow`：一团光

```json
{ "id": "sun", "kind": "glow", "depth": 0.2, "color": "#FFE7A3",
  "falloff": 0.55, "opacity": 0.7, "area": [0.55, -0.12, 1.2, 0.5] }
```

`falloff` 是 `0.05…1`：越接近 1 收得越快（边缘越硬），越小越糊。整块是纯径向渐变，别叠几十层——每层都是一次 `drawRect`，成本按面积算。

### `image`：一张图

```json
{ "id": "mountain", "kind": "image", "depth": 0.4, "area": [0, 0.35, 1, 1],
  "src": "asset:assets/wallpapers/mountain.webp", "fit": "cover", "tint": "#22334466" }
```

- `src` 接受三种写法：
  - `data:image/webp;base64,....`：整张图内嵌在 JSON 里，适合小装饰（同屏贴图总数受文件 20 MB 限制）。base64 会膨胀约 1/3，所以 1 MB 的图在文件里约 1.37 MB。
  - `asset:assets/wallpapers/xxx.webp`：指向 App 自带资源，只有随 App 一起打包的壁纸才能用。
  - `assets/sky.webp`：**场景包内**的相对路径，包在 §2「场景包」里。
  - 写绝对路径（`/sdcard/...`、`C:/...`）或用 `..` 往上跳一律失败——壁纸文件来自系统文件选择器，不能借它读任意文件。
- 图片解码时长边超过 **2048 px** 会自动缩到 2048，别塞 4K 原图。
- `fit`：`cover`（默认，铺满裁剪）、`contain`（完整放进区域）、`fill`（拉伸）。
- `tint`：以 `srcATop` 方式给图片上色（`#AARRGGBB`，alpha 决定强度）。

### `particles`：一片粒子

```json
{
  "id": "stars", "kind": "particles", "depth": 0.8,
  "count": 300, "colors": ["#FFFFFF", "#BCD4FF"],
  "area": [0, 0, 1, 0.6], "size": [0.8, 2.2], "speed": [1, 5],
  "lifetime": [10, 22], "angle": [0, 360], "gravity": 0, "drag": 0,
  "fade": [0.1, 0.35], "opacity": 0.9
}
```

| 字段 | 说明 |
| --- | --- |
| `count` | 1…800（单层）。整份文件的上限是 2000 颗粒子。 |
| `colors` | 颜色数组，按粒子年龄插值；也可以用 `color` 单个颜色。 |
| `area` | 发射区域，也是粒子飞出多远就重生的边界。 |
| `size` / `speed` / `lifetime` / `angle` / `fade` | 都是 `[最小, 最大]`，写单个数字表示固定值。`angle` 是飞出方向（度），`fade` 是进场/退场各占寿命的比例。 |
| `gravity` | 每秒加在 y 上的速度（负值向上飘）。 |
| `drag` | `0…4`，每秒速度衰减系数，越大越快停下来。 |

粒子的实现是一个 `Float32List` 结构数组 + 一次 `drawPoints`，所以 `count` 大一点也比同数量的 `drawCircle` 便宜得多；但还是别把 2000 全堆在一屏亮处，低端机 30 fps 会掉。

### `group`：一组

```json
{ "id": "hills", "kind": "group", "depth": 0.5, "children": [ ... ] }
```

`children` 里的图层跟着组的 `opacity` / `x` / `y` / `scale` / `rotation` 一起动。最多四层嵌套（再深会被拒绝）。

> 没有 `shader`、`lottie`、`video` 图层：着色器需要 `FragmentProgram` 白名单（还没做），视频请用「循环动态壁纸」。写这些 `kind` 会报错并列出可用的五种。

## 4. 时间线

一条轨道 = 一个属性 + 一串关键帧：

```json
{ "target": "moon.opacity", "mode": "loop", "keys": [[0, 0.4], [12, 0.7, "easeInOut"], [24, 0.4]] }
```

- `target`：`"<图层 id>.<属性>"`。可用属性（别的不认）：`opacity`、`scale`、`x`、`y`、`rotation`、`visible`、`speed`（粒子整体速度倍率）、`count`（粒子数量倍率）。
- `keys`：`[时间(秒), 数值, 缓动?]`，时间必须递增。缓动写在这一段的**起点**上。
- `mode`：
  - `loop`（默认）：按首尾时间差循环，`[0,…]` 到 `[24,…]` 就是每 24 秒一轮。时间超出末尾会绕回开头。
  - `clamp`：走到最后一帧就停住。
  - `pingpong`：走到末尾再倒着走回来。
- 缓动名：`linear`、`easeIn`、`easeOut`、`easeInOut`、`easeInCubic`、`easeOutCubic`、`easeInOutCubic`、`easeOutBack`，或者四元数组 `[x1, y1, x2, y2]` 自定义 `Cubic`（同 `Curves.easeInOut` 那套控制点）。
- 同一图层的多条轨道互不影响；没有轨道的属性就用静态值。
- 整份文件最多 400 条轨道、200 个图层；超了在解析阶段就拒绝，不会画到一半才崩。

呼吸感的小技巧：同一个属性写两条时间不同的轨道（比如 `sun.opacity` 和 `sun.scale` 周期不一致），比一条完美循环更耐看。

## 5. 跟着系统时间走

`periods` 里可以写 `day`、`dusk`、`night` 三套场景：

```json
"periods": {
  "dusk": { "background": { "colors": ["#FF9A62", "#D4685F", "#3B2A5C"] },
            "layers": [ ... ], "timeline": [ ... ] },
  "night": { "tint": "#1A2A4D55", "layers": [ ... ] }
}
```

- **只覆盖写到的键**，没写的（比如 `layers`）继承根场景。示例里 `aurora` 的 `night` 就复用了白天的图层列表，只换了配色和时间线。
- 时段（`ScenePeriod.of`）：**07:00–16:00 白天**，**05:00–07:00 与 16:00–19:00 黄昏**，**19:00–05:00 晚上**。`periods` 里缺哪个时段就用根场景（根场景就是白天那一套）。
- 黄昏有两个窗口是故意的：05:00–07:00 是日出，和 16:00–19:00 的日落共用一套黄昏配色，省得再写第四套。想让日出和日落不一样，就在窗口里自己按小时做判断——现阶段不支持。
- 运行时每帧看一眼时钟，跨过边界就把引擎切到对应场景（同一个引擎内切换，不重建页面、不掉帧）。设置页那行「跟随系统时间」显示的就是当前时段；想验证某套配色，把系统时间调到对应区间即可，不用改文件。
- 留给后续扩展：三套之外想加「深夜 / 雨天」之类，在 `ScenePeriod` 里加枚举 + 一个时间窗口，解析那边不用动。

## 6. 性能与预算

| 项 | 上限 / 建议 |
| --- | --- |
| 单文件大小 | 20 MB（`JsonWallpaper.maxBytes`，导入时超过就直接拒绝）；大图请用 `asset:`，别把 20 MB 全塞成 base64。20 MB 的文本第一次载入要多花一两百毫秒，别把上限当预留量用。 |
| 场景包 | 整包 300 MB（`maxPackageBytes`）、最多 500 个文件（`maxPackageFiles`）、单个文件解压后 120 MB（`maxPackageEntryBytes`）、解压比 ≤ 100:1。 |
| 视频 | 每段都要能循环播放，建议 H.264 MP4（兼容性最好）或 VP9 WebM，1080p 以内、码率 4–8 Mbps 就够铺满手机屏；一段 30 秒的 1080p 视频大约 15–30 MB。 |
| 图层 | 200（全局），同屏实际可见建议 ≤ 10。 |
| 粒子 | 单层 800，全局 2000；中端机 30 fps 建议 ≤ 600 / 层。 |
| 时间线 | 400 条轨道。 |
| 帧率 | `fpsCap` 24–60，默认 30。低端机 24–30。 |
| 图片 | 长边 ≤ 2048（超出自动缩），优先 WebP。 |
| 绘制 | 每帧只对发生变化的属性取值；渐变和光斑走预建 shader 缓存，不在每帧新建 `Paint`。 |

系统关闭动画（开发者选项里的「移除动画」）时，`JsonWallpaperView` 会停掉 `Ticker`，只画静止的一帧，视频也不播；App 切到后台同样暂停。写壁纸时不用管这两种情况。

### 输入条上那条遮罩（`BackdropVeil`）

**视频壁纸不重画背景**：`AppBackdrop` 默认让 `BackdropVeil` 把 `live` 层按整页大小再画一遍再套遮罩（`.json` 场景便宜，可以这么干）。视频不能这么做——那是每帧一张整页大小的离屏图层，手机上会把光栅线程拖死（实测拖动挂件后 15 秒内掉到 0 fps）。所以 `WallpaperBackdrop` 对 `WallpaperKind.video` 传 `liveBand: false`，遮罩改画 `AppBackdrop.bandAlpha = 0.9` 的本页底色渐变。

**烘焙只做最新那一次**：`WallpaperRenderer.bake()` 带 generation token，排队中的旧请求在解码前就被丢掉（`_generation`），所以拖动滑杆、改尺寸不会把一分钟的全屏烘焙排进队列。

## 7. 会被拒绝的写法

| 报错（中文，直接弹给用户） | 原因 |
| --- | --- |
| `schemaVersion 2 高于本应用支持的 1，请升级应用` | 文件比 App 新。 |
| `根节点必须是 JSON 对象` | 文件是数组 / 字符串，或者根本不是 JSON。 |
| `JSON 无法解析：…` | 语法错误，冒号后是解析器给的位置线索。 |
| `timeline.target 必须是 "图层id.属性"` | `target` 里没有 `.`，或者图层 id 是空的。 |
| `timeline.target 的属性无法识别：…（可用 opacity / scale / …）` | 属性名拼错，报错里列了全部可用值。 |
| `sky.src 缺失` | 图层少了 `src`。 |
| `sky.src 只支持 asset: 或压缩包内的相对路径，收到 http://…` | 用了别的 scheme（`file:`、`http:`、`C:/`）。 |
| `sky.src 不能是绝对路径：/sdcard/sky.png` | 绝对路径不允许。 |
| `sky.src 不能用 .. 或空目录：../sky.png` | 想跳出场景包。 |
| `sky.src 只支持 .png / .jpg / .jpeg / .webp，收到 sky.gif` | 扩展名不在白名单。 |
| `video 不能内嵌视频，请把视频放进压缩包` | 视频写成了 `data:`。 |
| `layer.kind 无法识别：shader（可用 gradient / glow / image / particles / group）` | `kind` 写错，或用了还没实现的 `shader` / `lottie`。视频不是图层，是场景背景，见 §2「视频」。 |
| `layer.id 重复：stars` | 两个图层用了同一个 id。 |
| `sun.area 必须是 [left, top, right, bottom]（0…1 的相对坐标）` | `area` 不是四个数。 |
| `ease 无法识别：bounce` | 缓动名写错，或者自定义曲线不是四个数。 |
| `图层总数超过 200` / `粒子总数超过 2000` / `timeline 超过 400 条` | 超过 §6 的预算。 |
| `group 嵌套太深（最多 4 层）` | `group` 里再套 `group` 超过四层。 |
| `压缩包打不开：…` | zip 头坏了，或者根本不是 zip。 |
| `压缩包里有非法路径：../evil.mp4` | 条目想写进包外（zip slip）。 |
| `包里的 assets/day.mp4 超过 120 MB` / `解压后超过 300 MB` / `压缩比异常，拒绝解压` | 超过 §6 的包预算。 |
| `压缩包里的文件太多（最多 500 个）` | 条目太多。 |
| `压缩包里没有 manifest.json` | 既没有 `manifest.json`，根目录也没有唯一一个 `.json`。 |
| `压缩包里缺少 assets/dusk.mp4` | manifest 引用的文件包里没有。 |
| `只支持 .json 文件或场景包（.jsonwall / .zip）` | 选了一个既不是 zip、扩展名也不是 `.json` 的文件（选择器不过滤扩展名，见 §1）。 |

未知的**顶层字段**会被忽略（方便以后升级格式），所以拼错字段名不一定报错——表现是「设了没效果」。遇到这种，先看字段名拼写，再对照这份表。

## 8. 做一款新壁纸的路径

1. 复制 `app/assets/wallpapers/aurora.json` 当骨架，保留 `schemaVersion`、`background`、一个 `glow`、一层 `particles`。
2. 先只调 `background` 的配色，确认四个时段（含根场景）的明暗都能压住白字——壁纸上的文字对比度是自动守护的，但底色太花会显得脏。
3. 加 `timeline`：先 `opacity` 呼吸，再 `scale` 缓慢推拉，最后才上 `x` / `y` 漂移。
4. 加 `periods.dusk` / `periods.night`，只写要变的键，其余继承。
5. 想放视频：建一个目录，把 `manifest.json` 和 `assets/*.mp4` 放进去，用 `videos` 把三个时段各指一段视频，然后整个目录压成 zip，扩展名改成 `.jsonwall`。
6. 把文件放进 `assets/wallpapers/`（随 App 打包），或者在设置里用「更换 .json 文件」直接试自己的文件（场景包也从这里导入）。
7. 真机验证：首页、对话、抽屉各看一眼；切后台再回来；把系统时间调到黄昏、晚上各看一次；低端机看 fps（`flutter run --profile`）。

## 9. 真机验证清单

- 首页、对话页、抽屉：壁纸在，文字清楚，输入条上方的渐隐带没有盖住视频/画面（`BackdropVeil` 在 live 模式下改画半透明色带，不是重绘背景）。
- 预览页能打开、点任意位置返回。
- 换一份坏文件：提示里带字段位置，且旧壁纸还在（不会白屏）。
- 换一个场景包：`更换 .json 文件` 下面显示「场景包」；首页那张壁纸里能看到包内视频在动，渐变/粒子叠在视频上面。
- 视频时段：把系统时间调到白天 / 黄昏 / 晚上，背景视频跟着换；同一时段内不重复创建播放器（切后台再回来不应黑屏）。
- 系统时间 05:00 / 07:00 / 16:00 / 19:00 前后各跨一次边界：场景和视频自动换，不闪、不重建页面。
- 切后台 30 秒回来：画面继续动，视频继续播，没有从 0 重来。
- 关闭系统动画：画面静止（视频留第一帧）但完整。
