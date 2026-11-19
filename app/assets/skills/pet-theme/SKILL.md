---
# dsh-go:managed — delete this line to keep your own edits.
name: pet-theme
description: 把外来的 Live2D 模型（.model3.json / model.json+.moc，含社区整包的 moc3、贴图、动作、表情）或精灵素材做成 dsh-go 能导入的宠物包、伙伴小屋包；会先盘点模型自带动作，按状态给出候选、逐个演示给用户挑、支持一键通过或逐条替换。用于「把这个 Live2D 模型做成宠物」「这个模型能用在伙伴小屋吗」「这个能导入吗」和 /pet-theme。
---

# 做一只宠物

把一份外来素材变成 dsh-go 能导入的 zip：宠物包（`设置 → 宠物 → 导入`）或伙伴小屋包
（`设置 → 伙伴小屋 → 导入`）。脚本都在 `scripts/` 下，只用 `python3`。

先看素材属于哪一种，两条路只选一条：

- **Live2D 模型**：目录或 zip 里有 `*.model3.json`（Cubism 3/4/5），或 `model.json` + `.moc`（Cubism 2）
  → 走下面的「Live2D」流程，脚本 `live2d_pet_kit.py`。
- **精灵素材**：clawd-on-desk 主题、GIF/APNG/WebP/PNG、逐帧目录、Aseprite 导出、单张图
  → 跳到最后的「精灵素材」流程，脚本 `pet_theme_convert.py`。

## Live2D

外来模型多半是整包搬运：moc3 很大、贴图 4096、动作名字是日文/拼音、描述文件末尾还带逗号。
App 自己不会修这些，读不进去就整包失败，所以**一律先过这个脚本**，不要手改模型文件。

### 1. 先盘点

    python3 <scripts>/live2d_pet_kit.py report --input <目录或zip> \
        --json /tmp/live2d-report.json --write-mapping /tmp/mapping.json --name <名字>

它会打印：模型类型（Cubism 2/3）、文件数与总大小、贴图尺寸、动作表、表情表，以及
描述文件里的问题（例如末尾多余逗号，脚本会现场修好，不写回原目录）。

**动作表就是你能用的全部素材**，键名是舞台真正播放时用的名字，必须原样写进 mapping：

- 一组只有一个动作 → 用组名，例如 `CAT_motion_lock`
- 一组有多个动作 → 组名加序号，例如 `Tap_1`、`Tap_2`
- 没登记在描述文件里的 `xxx.motion3.json` → 用文件名 `xxx`（上限 64 个）

把动作表原样贴给用户看：动作名、时长、是否循环、动的是表情/参数还是物理。
如果 report 说「没用上的动作」，后面必须解释为什么。

### 2. 先出小屋包，让用户真的看到动作

宠物包在聊天里只按状态播放，用户没法逐个试。伙伴小屋的「动作和表情」页可以：

    python3 <scripts>/live2d_pet_kit.py room --input <目录或zip> \
        --out /sdcard/Download/DSH-Go/<id>-room.zip --name <名字>

让用户导入小屋包，进「设置 → 伙伴小屋 → 动作和表情」逐个点 ▶ 试播（还可以「改个叫法」），
然后回来告诉你：哪个动作像发呆、哪个像打字、哪个像睡觉。**这一步不要跳过**——
模型里明明有动作却没用上，正是用户最不满意的做法。

也可以直接用 report 里按名字/参数猜出来的建议表，但必须让用户看过再定。

### 3. 填 mapping（关键产物）

`/tmp/mapping.json` 里 11 个状态 + 5 个事件都必须在，做不到写 `null`，不能删键：

- 状态：`idle` `thinking` `working` `juggling` `sweeping` `notification`
  `attention` `error` `carrying` `sleeping` `waking`（`idle` 必须有值，别的可以 null）
- 事件：`tapLeft` `tapRight` `tickle` `annoyed` `drag`
- `fallback`：状态没人接时播放的动作，通常填 `idle` 的那个
- `canvas` / `contentBox` / `anchor`：封面与站位的坐标系。缺省 canvas `[1024,1024]`、
  contentBox 整张画布、anchor 底边中心；要贴合身体请用户给一张清晰截图，或先出包让他看效果再调。

模型只有一个动作组时，所有状态只能共用它——**要明说**，不要假装每个状态都不一样。

### 4. 把映射表摆给用户，等一句「全部通过」

用表格给结论，一行一个状态，写清用了哪个动作、为什么：

    状态        动作              理由
    idle        CAT_motion_lock   唯一的循环动作
    thinking    —（null）         没有能表达思考的动作
    ...

然后问：

- 一键通过：回「全部通过」，直接出包。
- 逐条改：回「thinking 用 Tap_1」「把 sleeping 和 working 的动作互换」，改完再出包。
- 互换是**换两个状态的键值**，不是新增动作；改完把新表再贴一遍让他确认。

### 5. 出包并校验

    python3 <scripts>/live2d_pet_kit.py pet --input <目录或zip> \
        --out /sdcard/Download/DSH-Go/<id>.zip --mapping /tmp/mapping.json \
        [--poster <封面.png>] [--texture-max 2048]

- 贴图默认缩到 2048：手机显存有限（4096 的 14 张贴图要占 896 MB），宠物只有几十 dp 大，
  2048 已经过剩。用户明确要原图才加 `--texture-max 0`。
- 没有封面就不要给 `--poster`：App 第一次显示时会自己从模型截一张；
  要用现成图必须先按 canvas 尺寸准备好，脚本会拒绝尺寸不符的封面。
- 描述文件里的 `sound` 会去掉（宠物不播声音），moc 与贴图原样搬运。
- 命令最后会打印「没实现的状态 / 没实现的事件 / 没用上的动作」，并提醒你转述——
  **必须原样告诉用户**，这是他要求每次都返回的东西。
- 脚本自带校验，末尾必须看到 `PASS`；`check --pack <zip>` 可以单独再验一遍。

### 6. 收尾

告诉用户：包在哪、导哪、哪些状态没有动作、封面缺不缺、以及这是自用转换
（第三方模型尤其同人作品不要打包进发行版或市场）。Cubism 2 能装但降级：
没有物理、表情少，动作只认 `motions` 里登记的。

## 精灵素材

支持（按目录内容自动识别，一个目录只放一种）：

- clawd-on-desk 主题：theme.json + assets/
- 图片：GIF / APNG / WebP / PNG，一个文件一个动画；文件名自动认状态
  （idle、thinking、working、error、done、sleep、walk、poke、drag、tickle 等中英文）
- 逐帧目录：walk/01.png、hello_01.png，目录或前缀即动画名
- Aseprite 导出：JSON + 图集 PNG，按 frameTags 分动画
- 单张图片：做一只静态待机

没认出来的动画自动进待机小剧场，不会浪费。

    python3 <scripts>/pet_theme_convert.py --input <目录> --out /tmp/pet-pack --id <id> \
        --input-name <名字> [--source <链接>]
    python3 <scripts>/pet_pack_check.py /tmp/pet-pack/<id> --compat-reactions   # 必须 PASS
    cd /tmp/pet-pack/<id> && python3 -m zipfile -c <输出路径>/<id>.zip pack.json *.png

像素画（小图、硬边）自动保持尺寸锐利绘制；其它素材自动用 144 画布平滑绘制，想强制锐利加 `--crisp`。

## 边界

- 一个目录只识别一种素材，混放请分开；整张精灵表请先拆帧或导出 Aseprite JSON。
- 不手改模型文件（moc3 / model3.json / 贴图），不改生成的 pack.json，不跳过校验。
- 动作键必须来自 report 的动作表；填了不存在的名字，脚本会拒绝并列出可用动作。
- 真做不到全部映射时才用 `--allow-motions-ignored`，且必须在回复里说明为什么不用。
- 摘要里要说清「没实现的状态 / 事件」；不要为了显得完整而编造动作。
- 不把用户素材上传，不写进仓库。
