#!/usr/bin/env python3
"""Checks live2d_pet_kit against a synthetic Live2D model.

Run from app/ (standard library only — Pillow is optional in the kit, and the
textures here are 1x1 so it is never needed):

    python3 -I tool/test_live2d_pet_kit.py

No real model art is used: the fixture is a two-group model3.json with a
trailing comma, one unregistered .motion3.json, a sound file and an
expression, which is exactly the shape a community rip has.
"""
import io
import json
import os
import re
import shutil
import struct
import sys
import tempfile
import unittest
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import live2d_pet_kit as K              # noqa: E402


def png(width, height, rgba=(255, 0, 0, 255)):
    """A [width]x[height] PNG of one colour, as bytes."""
    raw = b''.join(b'\x00' + bytes(rgba) * width for _ in range(height))

    def chunk(kind, data):
        return (struct.pack('>I', len(data)) + kind + data
                + struct.pack('>I', zlib.crc32(kind + data) & 0xFFFFFFFF))

    header = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header)
            + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))


def motion(duration=1.5, loop=True):
    return {'Version': 3,
            'Meta': {'Duration': duration, 'Fps': 30, 'Loop': loop},
            'Curves': [{'Target': 'Parameter', 'Id': 'ParamAngleX',
                        'Segments': [0, 0, 1, duration, 10]}]}


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    mode = 'wb' if isinstance(data, bytes) else 'w'
    with open(path, mode, **({} if mode == 'wb' else {'encoding': 'utf-8'})) as handle:
        handle.write(data)


def fixture(root, cubism=3, trailing_comma=True):
    """A model folder; returns its path."""
    write(os.path.join(root, 'textures', 'tex_00.png'), png(1, 1))
    write(os.path.join(root, 'bgm.mp3'), b'ID3\x03\x00\x00\x00\x00\x00\x00')
    write(os.path.join(root, 'idle.motion3.json'), json.dumps(motion(2.0, True)))
    write(os.path.join(root, 'wave_a.motion3.json'), json.dumps(motion(0.8, False)))
    write(os.path.join(root, 'wave_b.motion3.json'), json.dumps(motion(1.1, False)))
    write(os.path.join(root, 'loose_extra.motion3.json'), json.dumps(motion(0.5, False)))
    write(os.path.join(root, 'smile.exp3.json'), json.dumps({'Version': 3, 'Parameters': []}))
    if cubism == 2:
        write(os.path.join(root, 'cat.moc'), b'MOC\x00')
        doc = {'version': 'Sample 1.0', 'model': 'cat.moc', 'textures': ['textures/tex_00.png'],
               'motions': {'Idle': [{'file': 'idle.motion3.json', 'sound': 'bgm.mp3'}],
                           'Wave': [{'file': 'wave_a.motion3.json'}, {'file': 'wave_b.motion3.json'}],
                           'Loose': [{'file': 'loose_extra.motion3.json'}]}}
        write(os.path.join(root, 'model.json'), json.dumps(doc))
        return root
    write(os.path.join(root, 'cat.moc3'), b'MOC3\x03\x00\x00\x00')
    doc = {'Version': 3, 'FileReferences': {
        'Moc': 'cat.moc3',
        'Textures': ['textures/tex_00.png'],
        'Expressions': [{'Name': 'Smile', 'File': 'smile.exp3.json'}],
        'Motions': {
            'Idle': [{'File': 'idle.motion3.json', 'Sound': 'bgm.mp3', 'FadeInTime': 0.2}],
            'Wave': [{'File': 'wave_a.motion3.json', 'FadeInTime': 0.1},
                     {'File': 'wave_b.motion3.json', 'FadeInTime': 0.1}],
        },
    }}
    text = json.dumps(doc, indent=2, ensure_ascii=False)
    if trailing_comma:
        # The comma a hand-edited descriptor usually has: after the last motion.
        text, count = re.subn(r'("FadeInTime": 0\.2)(\s*})(\s*\])', r'\1\2,\3', text)
        assert count == 1, text
    write(os.path.join(root, 'cat.model3.json'), text)
    return root


class ReportTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix='live2d-kit-')
        fixture(self.dir)

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_trailing_comma_is_reported_and_fixed(self):
        model = K.open_model(self.dir)
        self.assertEqual(model.cubism, 3)
        self.assertTrue(any('逗号' in note for note in model.notices))
        # The kit writes a clean descriptor: re-reading it finds no commas left.
        target = os.path.join(self.dir, 'clean.model3.json')
        K.write_json(target, model.doc)
        _doc, commas = K.read_json(target)
        self.assertEqual(commas, 0)
        with open(target, encoding='utf-8') as handle:
            json.load(handle)

    def test_motions_are_named_the_way_the_stage_plays_them(self):
        keys = [entry['key'] for entry in K.motion_catalogue(K.open_model(self.dir))]
        # One motion keeps its group name; several get _1/_2; a loose file its own name.
        self.assertEqual(keys, ['Idle', 'Wave_1', 'Wave_2', 'loose_extra'])

    def test_motion_metadata_is_read(self):
        entries = {e['key']: e for e in K.motion_catalogue(K.open_model(self.dir))}
        self.assertEqual(entries['Idle']['duration'], 2.0)
        self.assertTrue(entries['Idle']['loop'])
        self.assertFalse(entries['Wave_1']['loop'])

    def test_textures_and_moc_are_references(self):
        model = K.open_model(self.dir)
        self.assertEqual(model.references()['moc'], 'cat.moc3')
        self.assertEqual([rel for rel, _ in model.texture_sizes()], ['textures/tex_00.png'])

    def test_sound_and_unknown_files_are_listed(self):
        model = K.open_model(self.dir)
        self.assertIn('bgm.mp3', [rel for rel, _ in model.data_files()])
        self.assertEqual(model.dropped_files(), [])


class MappingTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix='live2d-kit-')
        fixture(self.dir)
        self.model = K.open_model(self.dir)
        self.motions = K.motion_catalogue(self.model)

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def skeleton(self, **states):
        mapping = K.mapping_skeleton(self.model, 'Test Pet')
        mapping['states'].update(states)
        return mapping

    def test_skeleton_lists_every_state_and_reaction(self):
        mapping = K.mapping_skeleton(self.model)
        self.assertEqual(sorted(mapping['states']), sorted(K.STATES))
        self.assertEqual(sorted(mapping['reactions']), sorted(K.REACTIONS))
        self.assertTrue(all(value is None for value in mapping['states'].values()))
        self.assertEqual(mapping['canvas'], [1024, 1024])

    def test_unknown_motion_is_refused(self):
        mapping = self.skeleton(idle='Idle', thinking='Nope')
        with self.assertRaises(K.KitError) as caught:
            K._check_mapping(self.model, mapping, self.motions)
        self.assertIn('Nope', str(caught.exception))

    def test_missing_state_key_is_refused(self):
        mapping = self.skeleton(idle='Idle')
        del mapping['states']['thinking']
        with self.assertRaises(K.KitError) as caught:
            K._check_mapping(self.model, mapping, self.motions)
        self.assertIn('thinking', str(caught.exception))

    def test_leaving_every_motion_out_is_refused(self):
        with self.assertRaises(K.KitError) as caught:
            K._check_mapping(self.model, self.skeleton(), self.motions)
        self.assertIn('--allow-motions-ignored', str(caught.exception))
        checked = K._check_mapping(self.model, self.skeleton(), self.motions, True)
        self.assertEqual(len(checked['unplayed_motions']), 4)

    def test_unmade_report_names_what_is_missing(self):
        checked = K._check_mapping(self.model, self.skeleton(idle='Idle'), self.motions)
        self.assertNotIn('idle', checked['unimplemented_states'])
        self.assertIn('thinking', checked['unimplemented_states'])
        self.assertIn('tapLeft', checked['unimplemented_reactions'])
        text = K.unmade_text(checked)
        self.assertIn('没实现的状态', text)
        self.assertIn('thinking', text)


class BuildTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix='live2d-kit-')
        self.model_dir = fixture(os.path.join(self.dir, 'model'))
        self.out = os.path.join(self.dir, 'out')

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def mapping(self, **overrides):
        model = K.open_model(self.model_dir)
        mapping = K.mapping_skeleton(model, 'Test Pet')
        mapping['canvas'] = [4, 4]
        mapping['states'].update({'idle': 'Idle', 'working': 'Wave_1'})
        mapping['reactions'].update({'tapLeft': 'Wave_2'})
        mapping['fallback'] = 'Idle'
        mapping.update(overrides)
        return model, mapping

    def build(self, mapping, model, **kwargs):
        checked = K._check_mapping(model, mapping, K.motion_catalogue(model))
        pack = os.path.join(self.out, 'pet.zip')
        checked, count, total = K.build_pet(model, mapping, pack, checked, **kwargs)
        return pack, checked

    def test_pet_pack_passes_the_gates(self):
        model, mapping = self.mapping()
        pack, checked = self.build(mapping, model)
        self.assertTrue(K.check_pack(pack, 'pet'))
        with zipfile_names(pack) as names:
            self.assertIn('pack.json', names)
            self.assertIn('character/cat.model3.json', names)
            self.assertFalse(any(name.endswith('.mp3') for name in names))
            self.assertFalse(any(name == 'poster.png' for name in names))
        packed = json.loads(zipfile_read(pack, 'pack.json'))
        self.assertEqual(packed['live2d']['states'], {'idle': 'Idle', 'working': 'Wave_1'})
        self.assertEqual(packed['live2d']['reactions'], {'tapLeft': 'Wave_2'})
        self.assertEqual(packed['live2d']['fallback'], 'Idle')
        self.assertEqual(packed['canvas'], {'w': 4, 'h': 4})
        self.assertEqual(packed['contentBox'], {'x': 0, 'y': 0, 'w': 4, 'h': 4})
        self.assertEqual(packed['anchor'], {'x': 2, 'baseline': 4})
        descriptor = json.loads(zipfile_read(pack, 'character/cat.model3.json'))
        for entries in descriptor['FileReferences']['Motions'].values():
            for entry in entries:
                self.assertNotIn('Sound', entry)
        # Idle, Wave_1 and Wave_2 are used; the unregistered file is the one that is not.
        self.assertEqual(checked['unplayed_motions'], ['loose_extra'])
        self.assertIn('thinking', checked['unimplemented_states'])

    def test_poster_must_match_the_canvas(self):
        model, mapping = self.mapping()
        good = os.path.join(self.dir, 'poster.png')
        write(good, png(4, 4))
        pack, _ = self.build(mapping, model, poster=good)
        with zipfile_names(pack) as names:
            self.assertIn('poster.png', names)
        bad = os.path.join(self.dir, 'bad.png')
        write(bad, png(8, 8))
        with self.assertRaises(K.KitError):
            self.build(mapping, model, poster=bad)

    def test_content_box_outside_the_canvas_is_refused(self):
        model, mapping = self.mapping()
        mapping['contentBox'] = [0, 0, 8, 8]
        with self.assertRaises(K.KitError):
            self.build(mapping, model)

    def test_room_pack_keeps_the_model_at_the_root(self):
        model = K.open_model(self.model_dir)
        pack = os.path.join(self.out, 'room.zip')
        count, total = K.build_room(model, pack, name='Test Pet')
        self.assertEqual(count, 9)
        self.assertTrue(K.check_pack(pack, 'room'))
        with zipfile_names(pack) as names:
            self.assertIn('cat.model3.json', names)
            self.assertIn('character.json', names)
            self.assertFalse(any(name.startswith('character/') for name in names))
        character = json.loads(zipfile_read(pack, 'character.json'))
        self.assertEqual(character, {'schema': 1, 'name': 'Test Pet', 'model': 'cat.model3.json'})


class Cubism2Test(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix='live2d-kit-')
        fixture(os.path.join(self.dir, 'model'), cubism=2)

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_legacy_model_is_detected_and_packed(self):
        model = K.open_model(os.path.join(self.dir, 'model'))
        self.assertEqual(model.cubism, 2)
        self.assertEqual([e['key'] for e in K.motion_catalogue(model)],
                         ['Idle', 'Wave_1', 'Wave_2', 'Loose'])
        pack = os.path.join(self.dir, 'room.zip')
        K.build_room(model, pack, name='Legacy')
        self.assertTrue(K.check_pack(pack, 'room'))
        descriptor = json.loads(zipfile_read(pack, 'model.json'))
        self.assertEqual(descriptor['motions']['Idle'][0]['sound'], 'bgm.mp3')


def zipfile_names(pack):
    import contextlib
    import zipfile

    @contextlib.contextmanager
    def opened():
        with zipfile.ZipFile(pack) as archive:
            yield archive.namelist()

    return opened()


def zipfile_read(pack, name):
    import zipfile
    with zipfile.ZipFile(pack) as archive:
        return archive.read(name).decode('utf-8')


if __name__ == '__main__':
    unittest.main()
