# dsh-go 余额小鲸鱼（聊天挂件）设计

## 0. 结论

输入框上沿站一只蓝发鲸娘，平时**只有角色**：不常驻显示余额。点她，头上冒出一个白底深蓝描边、带两个尾点的**思考气泡**，里面是余额、谷/峰时段和倒计时，**三秒后自己收起**。点这个余额气泡，换成另一个只装台词的窄气泡，随机说一句预设台词（可以在设置里改成自己的话）。点角色本身只会显示余额，不会蹦台词。

按住她会**压扁**并播放压扁音效，松手**弹回**并播放恢复音效——短按和长按都一样。按住还能拖到输入框上方任意位置，靠近左右边缘会**贴边吸附**（`x = 0` / `x = 1`，不留缝），角色图会按自己站在哪一边**翻转**，让被直切的那条边朝屏幕边缘。没有长按菜单，也不播放 GIF。

角色、音效、台词都能在设置 › 主题 › 余额小鲸鱼里换。数据全部来自 App 已有的 `balanceProvider`，**不发新请求**。

参照的外部实现是 [MeteorNOX/DeepSeek-Balance-Whale-Widget](https://github.com/MeteorNOX/DeepSeek-Balance-Whale-Widget)（DSH 的 Cordis 网页插件，v0.4.2）。dsh-Go 的原生界面不加载网页插件，所以这里是**原生 Flutter 实现**，不打包该插件。气泡几何、字号、音效时序与吸附比例取自插件的 `assets/whale-widget.js`。

## 1. 产品规则

1. **不挡事。** 挂件只占「鲸娘 + 气泡」那么大（`Align` + `HitTestBehavior.opaque` 的 GestureDetector 只包在孩子身上），其余区域照常可点：「回到底部」按钮、输入框上方的推荐胶囊都不受影响。
2. **余额不常驻。** 平时只有角色；点一下显示三秒（`_hold`），到点自己收起，不留在屏幕上。
3. **台词要两下。** 点角色 = 余额；点余额气泡 = 台词。这样误触不会蹦出一句话。
4. **贴边就是贴边。** 吸附时 `pendantX` 就是 0 或 1，角色框和屏幕边之间没有内边距。
5. **手势优先于翻页。** 在屏幕边缘拖她时，不能顺手把左滑页「快捷入口」/右滑页翻出来（见 §2）。
6. **默认贴左下。** 初始位置 `pendantX = 0.04`、`pendantY = 0`，右侧留给「回到底部」按钮和待确认胶囊（`chat_list.dart`，右下、输入框上方 12dp），和宠物默认站左 1/4 是同一个理由（`pets.md` §2）。
7. **和宠物同一个高度层。** 站在输入条上沿（`top - height`），正文和输入框都在它下面；气泡向上长，不会被输入框盖住。
8. **打字时让位。** `aside: true` 时下滑淡出并 `IgnorePointer`，不抢正在输入的注意力。
9. **没有 key 也不吵。** 气泡金额位置显示「未设置 Key」/「离线」这类短文案，不出红点、不弹提示。

## 2. 布局与层级

聊天页 `chat_screen.dart` 的 `CustomMultiChildLayout` 有 `_Slot.pendant`：

```dart
final pendant = layoutChild(_Slot.pendant, BoxConstraints(maxWidth: width, maxHeight: math.max(0, top)));
positionChild(_Slot.pendant, Offset(0, math.max(0, top - pendant.height)));
```

`top` 就是输入条的上沿（`size.height - composer.height`），和 `veilHeight` 用同一个数，所以鲸娘正好落在遮罩上沿。`settings.pendant == false` 时槽位放 `SizedBox.shrink()`，布局照跑，不占高度。

挂件内部：

```
LayoutBuilder(AvailableStrip)                     // 可拖动的范围：输入条上方整条
  AnimatedSlide / AnimatedOpacity / IgnorePointer  // aside（打字）让位
    Align(Alignment(x*2-1, 1-y*2))                 // pendantX / pendantY，0..1；贴边时正好压边
      Transform.translate(_drag)                   // 拖动中的实时位移
        MediaQuery(gestureSettings: touchSlop 3)
          TweenAnimationBuilder(squash)            // 压扁：scaleX 1.05 / scaleY 0.88
            Column(crossAxisAlignment: 靠边方向)
              气泡（显示时） / SizedBox.square(62, 鲸娘)
```

漂移被限制在 `AvailableStrip` 里（`_dragEnd` 收到的是整条可用区域的尺寸），所以拖不出聊天页，也不会钻进输入框。

**手势优先级**：聊天页外面是左右滑的翻页结构（左滑「快捷入口」、右滑另一页），它们的识别器会在 `kTouchSlop`（18dp）处开始赢。挂件照宠物的做法，在 `MediaQuery` 里把 `gestureSettings.touchSlop` 压到 **3dp**（`pet_stage.dart` 用 `PetMetrics.dragSlop / 2`，同一套理由与写法），自己的 `PanGestureRecognizer` 就永远比翻页早一步进入竞技场，横着拖鲸娘不会再翻页。

## 3. 交互

| 手势 | 行为 |
| --- | --- |
| 点角色 | 播放余额刷新 → 显示余额气泡 3 秒（`HapticFeedback.lightImpact`） |
| 点余额气泡 | 换成台词气泡，随机一句，再 3 秒收起（`selectionClick`） |
| 点台词气泡 | 再掷一条台词 |
| 按住（短按或长按都算） | 压扁动画 + 按下音效；松手弹回 + 松开音效 |
| 按住并移动 | 实时跟手；松手写 `pendantX/pendantY`，`x < 0.08` 吸到 0、`x > 0.92` 吸到 1 |
| 拖到哪一侧 | 角色图按 `pendantX < 0.5` 决定是否水平镜像（见 §8） |

短按与长按走同一个弹簧：`Listener` 的 `onPointerDown/onPointerUp/onPointerCancel` 直接驱动 `_squeeze(down:)`，所以按下就有反馈，不必等长按阈值。动画是 `TweenAnimationBuilder(duration: 220ms, curve: Curves.easeOutBack)`、`Matrix4.diagonal3Values(1 + 0.05*s, 1 - 0.12*s, 1)`、`alignment: Alignment.bottomCenter`（等于上游的 `transform-origin: 50% 100%`）。

## 4. 两个气泡

**余额气泡**（`_BalanceCard`，`150 × 98`，比上一版窄 58dp）：

1. 「DeepSeek 余额」标题（`pendantBalance`）；
2. 金额，`formatMoney`（`app/lib/ui/chat/balance_widgets.dart`），等宽数字；
3. 谷/峰药丸：谷 `Color(0xFF2E9E4F)`、峰用主题 `tertiary`，文字 `pendantValley` / `pendantPeak`；
4. 倒计时 `HH:MM:SS`（`FontFeature.tabularFigures`），到下一次切换。

余额气泡不显示「今日已用」：该数值需要本地记账，上游由 `accounting.mjs` 实现一套账本。

**台词气泡**（`_LineCard`，宽 168、高度自适应）：只有那句话，没有标题、没有金额、没有余额。最多 3 行。

两个气泡共用 `_BubbleFrame`：白底圆角 28 + `Border.all(ink, 3)` + 两个 `_Tail` 圆点，尾点按 `mirrored` 挂在靠角色那一侧。气泡是 Flutter 画的，不是位图，所以换角色图也不用换气泡。

## 5. 状态与数据

- 只读 `balanceProvider`（`app/lib/state/balance_state.dart`）：`status` 决定文案（`pendantChecking` / `pendantNoKey` / `pendantInvalidKey` / `pendantOffline`），有余额时用 `formatMoney`。
- **谷/峰**在 `app/lib/state/pendant_options.dart` 的 `pendantPriceWindow(DateTime)`：换算北京时间（`toUtc() + 8h`），周一至周五 **09:00–12:00、14:00–18:00** 是峰，其余时间（含整个周末）是谷；返回 `({bool valley, Duration untilFlip})`，`pendantCountdown` 格式化成 `HH:MM:SS`。实现是**算术**而不是逐分钟前探：倒计时每秒重算一次，旧写法要扫最多 8 天（实测 441 µs/次，新写法 0.91 µs/次，30,240 个时刻比对结果完全一致）。
- 时间源用 `BalanceController.now()`（测试可注入），不直接 `DateTime.now()`。
- 台词：`pendantDefaultLines`（33 条，取自上游 `assets/whale-widget.js` 的 50 句池，MIT），用户改过的存在 `pendantLines`（换行分隔）。台词池为空时回落到默认。
- 气泡存活时间 `_hold = 3s`：`_holdTimer` 到点收起；倒计时由 `_BalanceCard` 自己的 1 秒计时器刷新（只重建那一张卡，不再整棵子树每秒重建），卡片销毁即停。
- 手感开销（2026-11-19）：按下的「压扁」和拖动偏移各用 `ValueNotifier`（`_squashed`、`_dragOffset`）驱动局部重建，点一下不再重建气泡与余额卡；`_BalanceCard` 只在余额气泡打开时 `ref.watch(balanceProvider)`，别处刷新余额不再波及挂件；两个音效播放器用 `PlayerMode.lowLatency`（短 UI 音，默认模式每次按下都要准备一次媒体会话）。

## 6. 音效

`audioplayers`（`app/pubspec.yaml`，`^6.8.1`）。两套预设对应上游的 `PRESET_GROUPS`：

| 预设 | 按下 | 松开 |
| --- | --- | --- |
| `duck`（默认） | `assets/pendant/Ya1.mp3` | `assets/pendant/Ya2.mp3` |
| `fx1` | `assets/pendant/D1.mp3` | `assets/pendant/D2.mp3` |

播放器**第一次按下才创建**（`_player()`）：测试宿主没有音频插件，构造期建播放器会在测试结束后抛 `MissingPluginException`。播放失败只记一次 `_audioBroken` 然后静默，不打断点击。`pendantSound = off` 时完全不建播放器；自定义音频只在按下时播一次。

## 7. 设置与 l10n

设置 › 主题 › **余额小鲸鱼**（`app/lib/ui/settings/appearance/pendant_section.dart`，`SettingsSection(title: pendantTitle)`），五行：

| 行 | spot | 行为 |
| --- | --- | --- |
| 开关 | `Spots.pendant` | `pendant`（默认 true） |
| 角色 | `Spots.pendantArt` | 内置头像 / 自定义图片 → `FilePicker.pickFile(type: image)` 拷到 `<appSupport>/pendant/art-<ts>.<ext>` |
| 音效 | `Spots.pendantSound` | 小黄鸭 / 音效一 / 静音 / 自定义音频 → 拷到 `sound-<ts>.<ext>` |
| 台词 | `Spots.pendantLines` | 多行编辑，可恢复默认 |
| 复位位置 | `Spots.pendantReset` | `setPendantPlace(0.04, 0)` |

prefs key：`pendant_widget`、`pendant_art`、`pendant_art_path`、`pendant_sound`、`pendant_sound_path`、`pendant_lines`、`pendant_x`、`pendant_y`。自定义文件放在应用支持目录，卸载即清；路径失效时回落到内置头像/默认音效。

文案：`app/lib/l10n/parts/pendant_{zh,en}.arb`（28 条）+ `start_page_{zh,en}.arb` 的 `hubPendant` / `hubPendantHint` / `searchKwPendant`。

## 8. 素材与许可

内置素材放在 `app/assets/pendant/`：`head.png`（320×320 透明 PNG，人物贴画布右下角）、`Ya1.mp3`、`Ya2.mp3`、`D1.mp3`、`D2.mp3`。音效沿用上游素材；角色图是本分支自备的图片，从原画的透明底版本导出。

**翻转规则**：这张图的下边缘（不透明像素占 87 %）是直切的，人物贴在画布右下角。站在屏幕左侧时整张图水平镜像，帽饰与流苏换到另一侧；站到右侧时镜像取消。左右由 `pendantX < 0.5` 判断，只在 0/1 吸附后才有意义。自定义图片不镜像——用户给的图没有这条几何约束。

上游 `PROVENANCE.md` 明确：`assets/**` 与 `icon.png` **不适用 MIT**，按 as-is 提供、不再许可、只用于运行该插件，收到权利主张即替换。这些是本仓库里唯一的非 MIT 素材，改发布形态前先确认，或者直接换掉：

- 角色图：任意 1:1 透明 PNG，替换 `head.png`（代码只按正方形 `fit: contain` 画）；
- 音效：任意短 mp3，替换同名文件；或让用户在设置里选「自定义音频」自己挑。

台词来自 `whale-widget.js`（那部分是 MIT），已注明出处。

## 9. 涉及的文件

- `app/lib/ui/chat/pendant/whale_pendant.dart`（挂件：角色、两个气泡、压扁/弹回、拖动吸附、音效）
- `app/lib/state/pendant_options.dart`（预设常量、台词池、谷峰窗口与倒计时、角色图映射）
- `app/lib/state/settings_state.dart`（8 个字段与 setter）
- `app/lib/ui/chat/chat_screen.dart`（`_Slot.pendant`）
- `app/lib/ui/settings/appearance/pendant_section.dart`、`appearance_page.dart`
- `app/lib/ui/settings/interface_page.dart`（旧的开关已从这里移走）、`app/lib/ui/settings/index/spots.dart`（5 个 spot）
- `app/lib/l10n/parts/pendant_{zh,en}.arb`、`start_page_{zh,en}.arb`
- `app/assets/pendant/*`、`app/pubspec.yaml`
- `app/test/chat/pendant/whale_pendant_test.dart`

## 10. 验收

- 聊天页有消息、空状态各有一次：平时只有鲸娘，点得到、不盖「回到底部」和推荐胶囊。
- 点她 → 余额气泡 3 秒后自己消失；期间点气泡 → 换成只有台词的窄气泡，再点再换一句。
- 按住 → 压扁 + 音效；松手 → 弹回 + 音效（短按、长按都要有）。
- 按住拖到右边松手 → 贴右边、图翻转（直边朝右）；拖回左边 → 贴左边并翻转回来；杀掉进程重进，位置不变。
- 在屏幕边缘左右滑鲸娘 → 只拖动她，不翻页。
- 设置 › 主题 里关掉开关 → 挂件消失；换自定义图片/音频 → 立刻生效；改台词 → 点气泡显示自己的话。
- 打字（`aside`）时淡出，输入框获得焦点不被抢。
- 无 key / 离线时气泡显示短文案，不弹错。

## 11. 不做

- 「今日已用」：要本地记账（上游 `accounting.mjs`，含修订、断档补偿），这一版不引入。
- 峰谷**计价**（每 M token 的价格表）：只做时段提示，不做金额估算。
- 长按菜单（刷新余额 / 收起小鲸鱼）与长按播放的 GIF 表情：不提供；收起由设置里的开关完成。
- 任务结束 / 提问 / 授权提示音（`task-end-a.wav`、`ask-default.wav` 等）：属另一套事件，不在挂件里。
- 气泡 GIF 图库与气泡序列编辑器。
- 在 App 里运行网页插件：和 `plugin-platform.md` 的边界冲突。
