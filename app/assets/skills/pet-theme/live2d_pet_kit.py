#!/usr/bin/env python3
"""Turns a Live2D model into a dsh-Go pet pack or companion-room pack.

    python3 live2d_pet_kit.py report --input <dir|zip> [--json <path>] [--write-mapping <path>]
    python3 live2d_pet_kit.py room   --input <dir|zip> --out <zip> [--name <name>] [--keep-sound]
    python3 live2d_pet_kit.py pet    --input <dir|zip> --out <zip> --mapping <mapping.json> [--poster <png>]
    python3 live2d_pet_kit.py check  --pack <zip> [--kind pet|room]

`report` is what the AI reads first: it lists the model's own motions under the
names the stage plays them by (a group with one motion is the group name, a
group with several is `group_1`, `group_2`, an unlisted `.motion3.json` is its
file name without the suffix — the same names the room's 「动作和表情」 page
shows), their length, whether they loop, and which parameters they move, with a
guess at the pet state each one fits.

`mapping.json` is the AI's answer and must name every state the pet has and
every reaction, `null` for the ones the model cannot play: the build then prints
them back as the 「没实现」 list the AI has to tell the user about. `pet` refuses
a mapping that ignores the model's motions when it has some.

Nothing here needs a GPU: the poster is optional (the app draws one from the
model on first show), so the model's files are only read, never rendered.
Standard library; Pillow only for --texture-max.
"""
import argparse
import json
import os
import re
import shutil
import struct
import sys
import tempfile
import zipfile
from pathlib import Path

# The states every pet has, and the reactions it can play (docs/pets/README.md).
STATES = (
    'idle', 'thinking', 'working', 'juggling', 'sweeping', 'notification',
    'attention', 'error', 'carrying', 'sleeping', 'waking',
)
# States that loop while they last; the rest are one-shot.
LOOPING = (
    'idle', 'thinking', 'working', 'juggling', 'sweeping', 'notification',
    'carrying', 'sleeping',
)
REACTIONS = ('tapLeft', 'tapRight', 'tickle', 'annoyed', 'drag')

# What the app accepts inside a pack (pet_pack_rules.g.dart, docs/live2d/README.md).
DATA_EXT = ('.json', '.moc3', '.moc', '.mtn', '.png', '.jpg', '.jpeg', '.webp',
            '.wav', '.mp3', '.txt', '.md')
SOUND_EXT = ('.mp3', '.wav')
PET_ARCHIVE_CAP = 64 * 1024 * 1024
PET_ENTRY_CAP = 256
PET_JSON_CAP = 256 * 1024
PET_SHEET_BYTE_CAP = 8 * 1024 * 1024
PET_SHEET_SIDE_CAP = 4096
PET_SHEET_DECODED_CAP = 16 * 1024 * 1024
LIVE2D_FILES_CAP = 1000
LIVE2D_FILE_CAP = 32 * 1024 * 1024
LIVE2D_TOTAL_CAP = 200 * 1024 * 1024
ROOM_TOTAL_CAP = 400 * 1024 * 1024
ROOM_FILES_CAP = 4000
TEXTURE_DEFAULT_MAX = 2048

# A name that reads as a gesture, by what a model's author called it.
HINTS = (
    ('idle', re.compile(r'idle|待机|呼吸|stand|loop', re.I), '待机循环'),
    ('thinking', re.compile(r'think|思考|想|hmm|\bplan', re.I), '思考'),
    ('working', re.compile(r'work|工作|打字|type|write|busy|study|学习', re.I), '工作'),
    ('juggling', re.compile(r'juggl|杂耍|ball|抛', re.I), '杂耍'),
    ('sweeping', re.compile(r'sweep|扫|clean|dust', re.I), '扫地'),
    ('notification', re.compile(r'note|通知|消息|message|bell|ring', re.I), '通知'),
    ('attention', re.compile(r'hello|hi|你好|wave|挥手|greet|打招呼|attention|敬礼', re.I), '打招呼'),
    ('error', re.compile(r'error|错|fail|拒绝|sad|难过|cry|哭', re.I), '出错'),
    ('carrying', re.compile(r'carry|拿|hold|抱|grab', re.I), '搬运'),
    ('sleeping', re.compile(r'sleep|睡|nap|doze|zzz', re.I), '睡觉'),
    ('waking', re.compile(r'wake|醒|stretch|伸懒腰|yawn|哈欠', re.I), '醒来'),
    ('tapLeft', re.compile(r'tap.?body|taphead|touch|摸|碰|poke|戳', re.I), '被戳'),
    ('tapRight', re.compile(r'tap.?body|taphead|touch|摸|碰|poke|戳', re.I), '被戳'),
    ('tickle', re.compile(r'tickle|挠|痒|laugh|笑', re.I), '挠痒'),
    ('annoyed', re.compile(r'angry|生气|annoy|怒|pout|鼓脸|shy|害羞', re.I), '不高兴'),
    ('drag', re.compile(r'drag|拖|fly|飞|float|飘|swing', re.I), '被拖动'),
)

# Physics-only curves: a motion that moves nothing else is a prop swaying, not
# a gesture the person would recognise.
PROP_PARAMS = re.compile(r'^(Param)?(Hair|Tail|Skirt|Ribbon|Breath|Cheek|Physics|4\d+)', re.I)


class KitError(Exception):
    """Something the AI has to fix or tell the user about."""


# ── JSON that exporters get slightly wrong ──────────────────────────────

def strip_trailing_commas(text):
    """`{"a": 1,}` → `{"a": 1}`; returns the text and how many it removed."""
    fixed, count = re.subn(r',(\s*[}\]])', r'\1', text)
    return fixed, count


def read_json(path):
    """Parse a JSON file from an exporter: BOM and trailing commas forgiven."""
    raw = Path(path).read_bytes()
    if raw[:3] == b'\xef\xbb\xbf':
        raw = raw[3:]
    text = raw.decode('utf-8', 'replace')
    fixed, commas = strip_trailing_commas(text)
    try:
        return json.loads(fixed), commas
    except json.JSONDecodeError as error:
        raise KitError('%s 不是合法 JSON：%s' % (Path(path).name, error)) from None


def write_json(path, data):
    Path(path).write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n',
                          encoding='utf-8', newline='\n')


# ── The model ───────────────────────────────────────────────────────────

def _shallow(names):
    """Shallowest of [names], then alphabetical: the descriptor rule the installers use."""
    return sorted(names, key=lambda n: (n.count('/'), n))[0]


def _png_size(data):
    if data[:8] != b'\x89PNG\r\n\x1a\n' or data[12:16] != b'IHDR':
        return None
    return struct.unpack('>II', data[16:24])


class Model:
    """A Live2D model folder: its descriptor, files, motions and expressions."""

    def __init__(self, root, descriptor, doc, cubism, notices):
        self.root = Path(root)
        self.descriptor = descriptor
        self.doc = doc
        self.cubism = cubism
        self.notices = list(notices)

    @property
    def name(self):
        return Path(self.descriptor).name.replace('.model3.json', '').replace('.json', '')

    def files(self):
        """Every file the pack would carry, relative to the model folder."""
        for path in sorted(self.root.rglob('*')):
            if not path.is_file():
                continue
            rel = path.relative_to(self.root).as_posix()
            if rel.split('/')[0] in ('__MACOSX',) or rel.endswith('/.DS_Store'):
                continue
            yield rel, path.stat().st_size

    def data_files(self):
        return [(rel, size) for rel, size in self.files() if Path(rel).suffix.lower() in DATA_EXT]

    def dropped_files(self):
        return [rel for rel, _ in self.files() if Path(rel).suffix.lower() not in DATA_EXT]

    def texture_sizes(self):
        out = []
        for rel, _ in self.files():
            if Path(rel).suffix.lower() != '.png':
                continue
            if not re.search(r'(texture|tex)', rel, re.I):
                continue
            size = _png_size((self.root / rel).read_bytes()[:32])
            if size:
                out.append((rel, size))
        return out

    def references(self):
        """What the descriptor points at, by role, for the checks and the report."""
        refs = self.doc.get('FileReferences') or {}
        out = {'moc': refs.get('Moc') or refs.get('MocFile') or '', 'textures': list(refs.get('Textures') or [])}
        if not out['moc']:
            moc = [rel for rel, _ in self.files() if rel.lower().endswith(('.moc3', '.moc'))]
            if moc:
                out['moc'] = _shallow(moc)
        return out


def _extract_zip(src, into):
    with zipfile.ZipFile(src) as archive:
        names = [n for n in archive.namelist() if not n.endswith('/')]
        if any(n.startswith('__MACOSX/') or n.split('/')[-1] == '.DS_Store' for n in names):
            names = [n for n in names if not (n.startswith('__MACOSX/') or n.split('/')[-1] == '.DS_Store')]
        tops = {n.split('/')[0] for n in names}
        strip = ''
        if len(tops) == 1 and all('/' in n for n in names):
            strip = tops.pop() + '/'
        for name in names:
            target = Path(into) / name[len(strip):].replace('\\', '/')
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(archive.read(name))


def open_model(src):
    """Load [src] (a model folder or a zip of one) into a [Model]."""
    src = Path(src)
    if not src.exists():
        raise KitError('找不到 %s' % src)
    if src.is_dir():
        root = src
    else:
        tmp = tempfile.mkdtemp(prefix='live2d-model-')
        _extract_zip(src, tmp)
        root = Path(tmp)
    names = [p.relative_to(root).as_posix() for p in root.rglob('*') if p.is_file()]
    modern = [n for n in names if n.lower().endswith('.model3.json')]
    legacy = [n for n in names if n.lower().endswith('model.json') and not n.lower().endswith('.model3.json')]
    if modern:
        descriptor, cubism = _shallow(modern), 3
    elif legacy and any(n.lower().endswith('.moc') for n in names):
        descriptor, cubism = _shallow(legacy), 2
    else:
        raise KitError('这里没有 Live2D 模型：缺 *.model3.json（Cubism 3 以上）或 model.json + .moc（Cubism 2）')
    doc, commas = read_json(root / descriptor)
    notices = []
    if commas:
        notices.append('%s 末尾有 %d 处多余的逗号（App 会读不进去），已修好' % (descriptor, commas))
    return Model(root, descriptor, doc, cubism, notices)


# ── What the model can do ───────────────────────────────────────────────

def _motion_meta(root, rel):
    """Duration, loop and the parameters a motion3 moves; zeros when unreadable."""
    meta = {'duration': 0.0, 'loop': False, 'curves': 0, 'params': [], 'parts': 0, 'ok': False}
    path = Path(root) / rel
    if not path.exists():
        return meta
    try:
        doc, _ = read_json(path)
    except KitError:
        return meta
    head = doc.get('Meta') or {}
    meta['duration'] = float(head.get('Duration') or 0)
    meta['loop'] = bool(head.get('Loop'))
    for curve in doc.get('Curves') or []:
        if not isinstance(curve, dict):
            continue
        meta['curves'] += 1
        if curve.get('Target') == 'Parameter' and curve.get('Id'):
            meta['params'].append(str(curve['Id']))
        elif curve.get('Target') == 'Part':
            meta['parts'] += 1
    meta['ok'] = True
    return meta


def motion_catalogue(model):
    """The model's motions under the names the stage plays them by."""
    out = []
    if model.cubism == 2:
        groups = (model.doc.get('motions') or {})
        for group, entries in groups.items():
            if not isinstance(entries, list):
                continue
            seen = 0
            for entry in entries:
                if not isinstance(entry, dict):
                    continue
                data = model.doc.get('motions', {})[group]
                file = entry.get('file') or entry.get('File')
                if not file:
                    continue
                seen += 1
                key = group if len(entries) == 1 else '%s_%d' % (group, seen)
                out.append({'key': key, 'group': group, 'index': seen - 1, 'file': file,
                            'duration': 0.0, 'loop': False, 'curves': 0, 'params': [],
                            'parts': 0, 'sound': entry.get('sound') or entry.get('Sound') or '',
                            'source': 'group'})
        return out
    refs = model.doc.get('FileReferences') or {}
    groups = refs.get('Motions') or {}
    listed = set()
    for group, entries in groups.items():
        if not isinstance(entries, list) or not entries:
            continue
        for index, entry in enumerate(entries):
            file = entry.get('File') if isinstance(entry, dict) else None
            if not file:
                continue
            listed.add(file.replace('\\', '/'))
            key = group if len(entries) == 1 else '%s_%d' % (group, index + 1)
            meta = _motion_meta(model.root, file)
            out.append({'key': key, 'group': group, 'index': index, 'file': file,
                        'duration': meta['duration'], 'loop': meta['loop'], 'curves': meta['curves'],
                        'params': meta['params'], 'parts': meta['parts'],
                        'sound': (entry.get('Sound') or '') if isinstance(entry, dict) else '',
                        'source': 'group'})
    # Motions the descriptor forgot: the stage offers them by file name, so the
    # pack can use them too (EXTRA_FILES_MAX = 64 in stage.js).
    extras = []
    for rel, _ in model.data_files():
        if not rel.lower().endswith('.motion3.json'):
            continue
        if rel.replace('\\', '/') in listed:
            continue
        extras.append(rel)
    for rel in sorted(extras)[:64]:
        meta = _motion_meta(model.root, rel)
        out.append({'key': Path(rel).name[: -len('.motion3.json')], 'group': '', 'index': 0, 'file': rel,
                    'duration': meta['duration'], 'loop': meta['loop'], 'curves': meta['curves'],
                    'params': meta['params'], 'parts': meta['parts'], 'sound': '', 'source': 'extra'})
    return out


def expression_catalogue(model):
    """The model's expressions: listed by the descriptor, then any extra .exp3.json."""
    out = []
    if model.cubism == 2:
        for name, file in (model.doc.get('expressions') or {}).items():
            if isinstance(file, str):
                out.append({'key': name, 'name': name, 'file': file})
        return out
    refs = model.doc.get('FileReferences') or {}
    listed = set()
    for entry in refs.get('Expressions') or []:
        if not isinstance(entry, dict) or not entry.get('File'):
            continue
        listed.add(str(entry['File']).replace('\\', '/'))
        name = str(entry.get('Name') or Path(str(entry['File'])).name)
        out.append({'key': name, 'name': name, 'file': entry['File']})
    extras = [rel for rel, _ in model.data_files()
              if rel.lower().endswith('.exp3.json') and rel.replace('\\', '/') not in listed]
    for rel in sorted(extras)[:64]:
        name = Path(rel).name[: -len('.exp3.json')]
        out.append({'key': name, 'name': name, 'file': rel})
    return out


def _gesture(entry):
    """Whether a motion reads as a gesture, and how strongly."""
    if not entry.get('curves'):
        return False, '读不出动画内容'
    params = entry.get('params') or []
    moved = [p for p in params if not PROP_PARAMS.match(p)]
    if not params and not entry.get('parts'):
        return False, '没动任何参数'
    if not moved and not entry.get('parts'):
        return False, '只动物理/道具参数（%s）' % '、'.join(params[:3])
    if entry.get('duration', 0) < 0.25:
        return False, '只有 %.2fs' % entry['duration']
    return True, '%d 条曲线，%.2fs' % (entry['curves'], entry.get('duration', 0))


def suggestions(model, motions):
    """Per state and reaction: the motions whose name reads like it."""
    out = {name: [] for name in STATES + REACTIONS}
    for entry in motions:
        label = '%s %s' % (entry.get('group') or '', Path(entry.get('file') or '').name)
        gesture, why = _gesture(entry)
        for state, pattern, _ in HINTS:
            if pattern.search(label) and state in out:
                out[state].append({'key': entry['key'], 'why': why, 'gesture': gesture})
    return out


# ── Report ──────────────────────────────────────────────────────────────

def _size(n):
    for unit in ('B', 'KB', 'MB', 'GB'):
        if n < 1024 or unit == 'GB':
            return ('%.0f %s' % (n, unit)) if unit == 'B' else ('%.1f %s' % (n, unit))
        n /= 1024.0


def _motion_line(index, entry):
    length = '%.2fs' % entry['duration'] if entry['duration'] else '时长未知'
    loop = '循环' if entry['loop'] else '一次'
    origin = '组内第 %d 个' % (entry['index'] + 1) if entry['source'] == 'group' and entry['group'] else (
        'model3.json 没登记' if entry['source'] == 'extra' else '')
    params = '、'.join(sorted(set(entry['params']))[:4]) or '无参数曲线'
    return '  %2d. %-22s %-9s %-4s %s%s' % (
        index, entry['key'], length, loop, params,
        ('（%s）' % origin) if origin else '')


def report_text(model):
    lines = []
    refs = model.references()
    textures = model.texture_sizes()
    motions = motion_catalogue(model)
    expressions = expression_catalogue(model)
    data = model.data_files()
    total = sum(size for _, size in data)
    lines.append('模型：%s（Cubism %d）' % (model.descriptor, model.cubism))
    lines.append('文件：%d 个，%s' % (len(data), _size(total)))
    if textures:
        side = max(max(size) for _, size in textures)
        lines.append('贴图：%d 张，最大 %d×%d' % (len(textures), side, side))
    if refs['moc']:
        lines.append('模型文件：%s' % refs['moc'])
    for notice in model.notices:
        lines.append('已修：%s' % notice)
    dropped = model.dropped_files()
    if dropped:
        lines.append('带不走的文件（%d 个，App 不认这些格式）：%s' % (
            len(dropped), '、'.join(dropped[:6]) + ('…' if len(dropped) > 6 else '')))
    if not motions:
        lines.append('动作：模型没有带任何动作（没有 .motion3.json，也没有登记）')
    else:
        lines.append('动作：%d 个（下面的名字就是 App 里「动作和表情」的按钮名，也是 states 里要填的值）' % len(motions))
        for index, entry in enumerate(motions, 1):
            lines.append(_motion_line(index, entry))
    if expressions:
        lines.append('表情：%d 个 — %s' % (
            len(expressions), '、'.join(item['name'] for item in expressions[:12])
            + ('…' if len(expressions) > 12 else '')))
    else:
        lines.append('表情：没有')
    hints = suggestions(model, motions)
    wanted = [(name, hints[name]) for name in STATES + REACTIONS if hints[name]]
    if wanted:
        lines.append('按名字猜的用途（要你确认，不要照抄）：')
        for name, items in wanted:
            lines.append('  %-12s ← %s' % (name, '、'.join('%s（%s）' % (i['key'], i['why']) for i in items)))
    lines.append('')
    lines.append('下一步：把每个状态和事件填进 mapping.json（填 null 就是模型做不到）。')
    lines.append('缺的一定要告诉用户：%s' % '、'.join(STATES + REACTIONS))
    return '\n'.join(lines)


def mapping_skeleton(model, name=None):
    """A mapping the AI fills in: every state and reaction, all null."""
    return {
        'id': re.sub(r'[^a-z0-9_-]+', '-', (name or model.name).lower()).strip('-') or 'live2d-pet',
        'name': name or model.name,
        'canvas': [1024, 1024],
        'contentBox': None,
        'anchor': None,
        'states': {state: None for state in STATES},
        'reactions': {reaction: None for reaction in REACTIONS},
        'fallback': None,
        'notes': '',
    }


# ── Building ────────────────────────────────────────────────────────────

def _check_mapping(model, mapping, motions, allow_motions_ignored=False):
    keys = {entry['key'] for entry in motions}
    states = mapping.get('states')
    reactions = mapping.get('reactions')
    if not isinstance(states, dict) or not isinstance(reactions, dict):
        raise KitError('mapping 里必须有 states 和 reactions 两个对象')
    missing = [state for state in STATES if state not in states]
    if missing:
        raise KitError('mapping.states 少了：%s（做不到就写 null，但不能不写）' % '、'.join(missing))
    missing = [r for r in REACTIONS if r not in reactions]
    if missing:
        raise KitError('mapping.reactions 少了：%s（做不到就写 null）' % '、'.join(missing))
    for state, value in states.items():
        if state not in STATES:
            raise KitError('mapping.states 里有 App 不认识的状态：%s' % state)
        if value is not None and value not in keys:
            raise KitError('状态 %s 填的动作 %r 不在模型里。可用的动作：%s' % (state, value, '、'.join(sorted(keys)) or '（没有）'))
    for reaction, value in reactions.items():
        if reaction not in REACTIONS:
            raise KitError('mapping.reactions 里有 App 不认识的事件：%s' % reaction)
        if value is not None and value not in keys:
            raise KitError('事件 %s 填的动作 %r 不在模型里。可用的动作：%s' % (reaction, value, '、'.join(sorted(keys)) or '（没有）'))
    fallback = mapping.get('fallback')
    if fallback is not None and fallback not in keys:
        raise KitError('fallback 填的动作 %r 不在模型里' % fallback)
    played = [v for v in states.values() if v] + [v for v in reactions.values() if v] + ([fallback] if fallback else [])
    if motions and not played and not allow_motions_ignored:
        raise KitError('模型里有 %d 个动作，你一个都没用上。要么映射，要么加 --allow-motions-ignored 并告诉用户为什么全不用' % len(motions))
    return {
        'unplayed_motions': sorted(keys - set(played)),
        'unimplemented_states': [state for state in STATES if not states.get(state)],
        'unimplemented_reactions': [r for r in REACTIONS if not reactions.get(r)],
    }


def unmade_text(checked):
    lines = ['没实现的状态：%s' % ('、'.join(checked['unimplemented_states']) or '无'),
             '没实现的事件：%s' % ('、'.join(checked['unimplemented_reactions']) or '无'),
             '没用上的动作：%s' % ('、'.join(checked['unplayed_motions']) or '无')]
    return '\n'.join(lines)


def _copy_character(model, into, keep_sound, texture_max):
    """Write the model under [into]/character, returning the descriptor's relative name."""
    written = 0
    total = 0
    shrunk = []
    for rel, size in model.data_files():
        suffix = Path(rel).suffix.lower()
        if not keep_sound and suffix in SOUND_EXT:
            continue
        target = Path(into) / 'character' / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        if texture_max and suffix == '.png' and re.search(r'(texture|tex)', rel, re.I):
            size = _shrink_png(model.root / rel, target, texture_max)
            if size is None:
                shutil.copyfile(model.root / rel, target)
                size = target.stat().st_size
            else:
                shrunk.append((rel, size))
        else:
            shutil.copyfile(model.root / rel, target)
            size = target.stat().st_size
        written += 1
        total += size
        if size > LIVE2D_FILE_CAP:
            raise KitError('%s 有 %s，超过单个文件 32 MB 的上限' % (rel, _size(size)))
    if written > LIVE2D_FILES_CAP:
        raise KitError('角色有 %d 个文件，超过 %d 个的上限' % (written, LIVE2D_FILES_CAP))
    if total > LIVE2D_TOTAL_CAP:
        raise KitError('角色文件共 %s，超过 200 MB 的上限' % _size(total))
    return written, total, shrunk


def _shrink_png(src, dst, limit):
    """Downscale a texture to [limit] per side; returns bytes written or None."""
    try:
        from PIL import Image
    except ImportError:
        return None
    with Image.open(src) as image:
        image.load()
        if max(image.size) <= limit:
            shutil.copyfile(src, dst)
            return dst.stat().st_size
        scale = limit / float(max(image.size))
        size = (max(1, round(image.size[0] * scale)), max(1, round(image.size[1] * scale)))
        image.resize(size, Image.LANCZOS).save(dst, 'PNG', optimize=True)
    return dst.stat().st_size


def _pet_descriptor(model, keep_sound):
    """The model3.json a pack carries: references kept, sounds optional."""
    doc = json.loads(json.dumps(model.doc))
    if model.cubism == 2:
        if not keep_sound:
            for entries in (doc.get('motions') or {}).values():
                for entry in entries if isinstance(entries, list) else []:
                    if isinstance(entry, dict):
                        entry.pop('sound', None)
                        entry.pop('Sound', None)
        return doc
    refs = doc.setdefault('FileReferences', {})
    for entries in (refs.get('Motions') or {}).values():
        for entry in entries if isinstance(entries, list) else []:
            if isinstance(entry, dict) and not keep_sound:
                entry.pop('Sound', None)
    return doc


def build_pet(model, mapping, out, checked, poster=None, keep_sound=False,
              texture_max=TEXTURE_DEFAULT_MAX):
    canvas = mapping.get('canvas') or [1024, 1024]
    if (not isinstance(canvas, list) and not isinstance(canvas, tuple)) or len(canvas) != 2:
        raise KitError('mapping.canvas 要写成 [宽, 高]')
    width, height = int(canvas[0]), int(canvas[1])
    if width <= 0 or height <= 0:
        raise KitError('mapping.canvas 的宽高要大于 0')
    box = mapping.get('contentBox')
    if box is None:
        box = [0, 0, width, height]
    if not isinstance(box, list) or len(box) != 4:
        raise KitError('mapping.contentBox 要写成 [x, y, 宽, 高] 或 null')
    x, y, w, h = (int(v) for v in box)
    if w <= 0 or h <= 0 or x < 0 or y < 0 or x + w > width or y + h > height:
        raise KitError('contentBox %r 超出了 canvas %d×%d' % (box, width, height))
    anchor = mapping.get('anchor')
    if anchor is None:
        anchor = [width // 2, y + h]
    if not isinstance(anchor, list) or len(anchor) != 2:
        raise KitError('mapping.anchor 要写成 [脚中心 x, 脚底 y] 或 null')
    anchor_x, baseline = int(anchor[0]), int(anchor[1])
    if not (0 <= baseline <= height):
        raise KitError('anchor 的 baseline 要在画布高度以内')

    staging = Path(tempfile.mkdtemp(prefix='live2d-pet-'))
    try:
        files, total, shrunk = _copy_character(model, staging, keep_sound, texture_max)
        descriptor = model.descriptor
        target = staging / 'character' / descriptor
        target.parent.mkdir(parents=True, exist_ok=True)
        write_json(target, _pet_descriptor(model, keep_sound))
        pack = {
            'schema': 1,
            'id': mapping.get('id') or model.name,
            'name': mapping.get('name') or model.name,
            'type': 'live2d',
            'canvas': {'w': width, 'h': height},
            'anchor': {'x': anchor_x, 'baseline': baseline},
            'contentBox': {'x': x, 'y': y, 'w': w, 'h': h},
            'live2d': {
                'model': descriptor,
                'poster': 'poster.png',
                'states': {state: value for state, value in mapping['states'].items() if value},
                'reactions': {key: value for key, value in mapping['reactions'].items() if value},
            },
        }
        if mapping.get('fallback'):
            pack['live2d']['fallback'] = mapping['fallback']
        if mapping.get('author'):
            pack['author'] = mapping['author']
        if mapping.get('license'):
            pack['license'] = mapping['license']
        if mapping.get('source'):
            pack['source'] = mapping['source']
        write_json(staging / 'pack.json', pack)
        if poster:
            _copy_poster(Path(poster), staging / 'poster.png', width, height)
        _write_zip(out, [(staging / 'pack.json', 'pack.json')]
                   + ([(staging / 'poster.png', 'poster.png')] if poster else [])
                   + [((staging / 'character' / rel), 'character/' + rel)
                      for rel, _ in model.data_files()
                      if (staging / 'character' / rel).exists()])
        checked = dict(checked)
        checked['textures_shrunk'] = shrunk
        return checked, files, total
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def _copy_poster(src, dst, width, height):
    if not src.exists():
        raise KitError('找不到封面 %s' % src)
    data = src.read_bytes()
    size = _png_size(data)
    if size is None:
        raise KitError('封面必须是 PNG（%s 不是）' % src.name)
    if size != (width, height):
        raise KitError('封面是 %d×%d，但要和画布 %d×%d 一致' % (size[0], size[1], width, height))
    if len(data) > PET_SHEET_BYTE_CAP:
        raise KitError('封面 %s，超过 8 MB' % _size(len(data)))
    shutil.copyfile(src, dst)


def build_room(model, out, name=None, keep_sound=True):
    staging = Path(tempfile.mkdtemp(prefix='live2d-room-'))
    total = 0
    count = 0
    try:
        entries = []
        for rel, size in model.data_files():
            if not keep_sound and Path(rel).suffix.lower() in SOUND_EXT:
                continue
            target = staging / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(model.root / rel, target)
            entries.append((target, rel))
            total += size
            count += 1
        if count > ROOM_FILES_CAP:
            raise KitError('角色有 %d 个文件，超过 %d 个的上限' % (count, ROOM_FILES_CAP))
        if total > ROOM_TOTAL_CAP:
            raise KitError('角色文件共 %s，超过 400 MB 的上限' % _size(total))
        descriptor_out = staging / model.descriptor
        write_json(descriptor_out, _pet_descriptor(model, keep_sound=True))
        if name:
            character = {'schema': 1, 'name': name, 'model': model.descriptor}
            write_json(staging / 'character.json', character)
            entries.append((staging / 'character.json', 'character.json'))
        _write_zip(out, entries)
        return count, total
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def _write_zip(out, entries):
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists():
        out.unlink()
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path, name in entries:
            if not Path(path).exists():
                continue
            info = zipfile.ZipInfo(name.replace('\\', '/'), date_time=(2024, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, Path(path).read_bytes())


# ── Checking what was built ─────────────────────────────────────────────

def check_pack(pack, kind):
    """The app's gates for a built zip; returns lines, raises on a failure."""
    pack = Path(pack)
    if not pack.exists():
        raise KitError('找不到 %s' % pack)
    problems = []
    lines = []
    size = pack.stat().st_size
    if size > PET_ARCHIVE_CAP:
        problems.append('包 %s，超过 64 MB' % _size(size))
    with zipfile.ZipFile(pack) as archive:
        infos = [i for i in archive.infolist() if not i.is_dir()]
        names = [i.filename for i in infos]
        expanded = sum(i.file_size for i in infos)
        if expanded > PET_ARCHIVE_CAP:
            problems.append('解压后 %s，超过 64 MB' % _size(expanded))
        if len(infos) > PET_ENTRY_CAP:
            problems.append('%d 个条目，超过 256' % len(infos))
        unsafe = [n for n in names if n.startswith('/') or '..' in n.split('/') or '\\' in n]
        if unsafe:
            problems.append('路径不安全：%s' % unsafe[0])
        for info in infos:
            suffix = Path(info.filename).suffix.lower()
            if suffix not in DATA_EXT:
                problems.append('不能带 %s' % info.filename)
                continue
            if kind == 'pet' and info.filename.startswith('character/'):
                if info.file_size > LIVE2D_FILE_CAP:
                    problems.append('%s 有 %s，单个文件上限 32 MB' % (info.filename, _size(info.file_size)))
        if kind == 'pet':
            if 'pack.json' not in names:
                problems.append('缺 pack.json')
            else:
                raw = archive.read('pack.json')
                if len(raw) > PET_JSON_CAP:
                    problems.append('pack.json 超过 256 KB')
                try:
                    pack_json = json.loads(raw.decode('utf-8'))
                except ValueError as error:
                    problems.append('pack.json 读不出来：%s' % error)
                    pack_json = None
                if pack_json:
                    problems.extend(_check_pet_json(pack_json, names, archive))
        else:
            models = [n for n in names if n.lower().endswith(('.model3.json', 'model.json'))]
            if not models:
                problems.append('包里没有模型描述文件')
            lines.append('模型描述：%s' % (models[0] if models else '缺'))
    lines.insert(0, '包：%d 个文件，%s（解压后 %s）' % (len(infos), _size(size), _size(expanded)))
    if problems:
        raise KitError('校验没过：\n  - ' + '\n  - '.join(problems))
    return lines


def _check_pet_json(pack_json, names, archive):
    problems = []
    if pack_json.get('schema') != 1:
        problems.append('schema 要写 1')
    if not isinstance(pack_json.get('id'), str) or not pack_json['id'].strip():
        problems.append('缺 id')
    if pack_json.get('type') != 'live2d':
        problems.append('type 要写 live2d')
    canvas = pack_json.get('canvas') or {}
    width, height = canvas.get('w'), canvas.get('h')
    if not isinstance(width, int) or not isinstance(height, int) or width <= 0 or height <= 0:
        problems.append('canvas 要写 {w, h}')
        width = height = 0
    box = pack_json.get('contentBox') or {}
    if not all(isinstance(box.get(k), int) for k in ('x', 'y', 'w', 'h')):
        problems.append('contentBox 要写 {x, y, w, h}')
    anchor = pack_json.get('anchor') or {}
    if not isinstance(anchor.get('x'), int) or not isinstance(anchor.get('baseline'), int):
        problems.append('anchor 要写 {x, baseline}')
    live2d = pack_json.get('live2d') or {}
    model = live2d.get('model')
    if not isinstance(model, str) or not model:
        problems.append('live2d.model 缺')
        model = ''
    elif 'character/' + model not in names:
        problems.append('live2d.model 指向的 %s 不在包里' % model)
    states = live2d.get('states') or {}
    if 'idle' not in states:
        problems.append('states 里必须有 idle')
    for state, value in states.items():
        if state not in STATES:
            problems.append('states 里有 App 不认识的状态 %s' % state)
        if not isinstance(value, str) or not value:
            problems.append('states.%s 要是动作名' % state)
    for reaction, value in (live2d.get('reactions') or {}).items():
        if reaction not in REACTIONS:
            problems.append('reactions 里有 App 不认识的 %s' % reaction)
        if not isinstance(value, str) or not value:
            problems.append('reactions.%s 要是动作名' % reaction)
    poster = live2d.get('poster') or 'poster.png'
    if poster in names:
        data = archive.read(poster)
        if len(data) > PET_SHEET_BYTE_CAP:
            problems.append('封面超过 8 MB')
        size = _png_size(data)
        if size is None:
            problems.append('封面不是 PNG')
        else:
            if width and size != (width, height):
                problems.append('封面 %d×%d 和画布 %d×%d 不一致' % (size[0], size[1], width, height))
            if max(size) > PET_SHEET_SIDE_CAP:
                problems.append('封面边长超过 4096')
            if size[0] * size[1] * 4 > PET_SHEET_DECODED_CAP:
                problems.append('封面解压后超过 16 MB')
    elif poster:
        # Not an error: the app draws one from the model on first show.
        pass
    return problems


# ── Command line ────────────────────────────────────────────────────────

def cmd_report(args):
    model = open_model(args.input)
    text = report_text(model)
    print(text)
    if args.json:
        motions = motion_catalogue(model)
        data = {
            'descriptor': model.descriptor,
            'cubism': model.cubism,
            'files': [{'path': rel, 'bytes': size} for rel, size in model.data_files()],
            'textures': [{'path': rel, 'width': size[0], 'height': size[1]} for rel, size in model.texture_sizes()],
            'motions': motions,
            'expressions': expression_catalogue(model),
            'suggestions': suggestions(model, motions),
            'notices': model.notices,
        }
        write_json(args.json, data)
        print('\n（机器可读的报告写到 %s）' % args.json)
    if args.write_mapping:
        skeleton = mapping_skeleton(model, args.name)
        write_json(args.write_mapping, skeleton)
        print('（mapping 模板写到 %s：每个状态和事件都要填，做不到写 null）' % args.write_mapping)
    return 0


def cmd_room(args):
    model = open_model(args.input)
    count, total = build_room(model, args.out, name=args.name, keep_sound=args.keep_sound)
    lines = check_pack(args.out, 'room')
    print('伙伴小屋包：%s' % args.out)
    print('  %d 个文件，%s' % (count, _size(total)))
    for line in lines:
        print('  ' + line)
    print('  PASS')
    return 0


def cmd_pet(args):
    model = open_model(args.input)
    motions = motion_catalogue(model)
    mapping, _ = read_json(args.mapping)
    checked = _check_mapping(model, mapping, motions, args.allow_motions_ignored)
    checked, count, total = build_pet(
        model, mapping, args.out, checked, poster=args.poster, keep_sound=args.keep_sound,
        texture_max=args.texture_max)
    lines = check_pack(args.out, 'pet')
    print('宠物包：%s' % args.out)
    print('  %d 个文件，%s' % (count, _size(total)))
    for line in lines:
        print('  ' + line)
    pack_json = json.loads('{}')
    print('  states：%s' % '、'.join('%s←%s' % (s, v) for s, v in mapping['states'].items() if v))
    print('  reactions：%s' % '、'.join('%s←%s' % (r, v) for r, v in mapping['reactions'].items() if v))
    shrunk = checked.get('textures_shrunk') or []
    if shrunk:
        print('  贴图缩到 %d 以内：%s' % (args.texture_max, '、'.join(Path(rel).name for rel, _ in shrunk)))
    print('  PASS')
    print('')
    print(unmade_text(checked))
    if checked['unimplemented_states'] or checked['unimplemented_reactions']:
        print('')
        print('上面这些没实现，必须原样告诉用户，不要只说做成了。')
    return 0


def cmd_check(args):
    lines = check_pack(args.pack, args.kind)
    for line in lines:
        print(line)
    print('PASS')
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description='Live2D 模型 → dsh-Go 宠物包 / 伙伴小屋包')
    subs = parser.add_subparsers(dest='command', required=True)

    report = subs.add_parser('report', help='看模型里有什么：动作、表情、贴图、能对上哪些状态')
    report.add_argument('--input', required=True, help='模型文件夹或它的 zip')
    report.add_argument('--json', help='把同样的内容写成 JSON 给机器读')
    report.add_argument('--write-mapping', help='写一份要填的 mapping.json')
    report.add_argument('--name', help='角色名（写进 mapping 模板）')
    report.set_defaults(func=cmd_report)

    room = subs.add_parser('room', help='打伙伴小屋包：先让用户在「动作和表情」里逐条试播')
    room.add_argument('--input', required=True)
    room.add_argument('--out', required=True, help='输出 zip')
    room.add_argument('--name', help='角色名')
    room.add_argument('--keep-sound', action='store_true', default=True)
    room.add_argument('--drop-sound', dest='keep_sound', action='store_false')
    room.set_defaults(func=cmd_room)

    pet = subs.add_parser('pet', help='打宠物包：状态 → 动作按 mapping.json 写进 pack.json')
    pet.add_argument('--input', required=True)
    pet.add_argument('--out', required=True)
    pet.add_argument('--mapping', required=True, help='填好的 mapping.json')
    pet.add_argument('--poster', help='可选的封面 PNG（必须和 canvas 同尺寸；不给就由 App 第一次显示时截）')
    pet.add_argument('--keep-sound', action='store_true', default=False)
    pet.add_argument('--texture-max', type=int, default=TEXTURE_DEFAULT_MAX,
                     help='贴图最长边缩到多少（默认 2048；0 = 原样）')
    pet.add_argument('--allow-motions-ignored', action='store_true',
                     help='模型有动作却一个都不用：必须说明原因')
    pet.set_defaults(func=cmd_pet)

    check = subs.add_parser('check', help='按 App 的规则验一遍打好的 zip')
    check.add_argument('--pack', required=True)
    check.add_argument('--kind', choices=('pet', 'room'), default='pet')
    check.set_defaults(func=cmd_check)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except KitError as error:
        print('失败：%s' % error, file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
