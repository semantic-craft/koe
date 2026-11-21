import json
import shutil
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import wave
import zlib


def png():
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    header = struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) + chunk(b'IDAT', zlib.compress(bytes(4))) + chunk(b'IEND', b'')


class EvidenceTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        for platform in ('ios', 'android'):
            for phase, pages, names in (
                ('live', 'settings project capture playback mini-player detail actions answer source-focused trash purged',
                 'configure_speech configure_provider create_note set_record_project start_capture_mode capture_action capture_action playback seek edit_segment_text rename_speaker add_highlight export_workspace_markdown review_item review_item review_item review_item review_item review_item set_ask_scope ask open_source set_record_archived trash_record restore_record trash_record purge_record'),
                ('device', 'device', 'device_release'),
                ('device-link', 'synced-detail', 'select_record'),
                ('restart', 'restart', 'sync_app_metadata'),
            ):
                out = self.root / platform / phase
                (out / 'maestro_debug').mkdir(parents=True)
                for page in pages.split():
                    (out / 'maestro_debug' / (page + '.png')).write_bytes(png())
                entries = [dict(kind='command', name=name, generation=1, section='today',
                                timestampEpochMs=1, hasError=False) for name in names.split()]
                if phase == 'live':
                    transitions = ['microphone_started', 'microphone_paused', 'resume_microphone',
                                   'microphone_started', 'microphone_stopped']
                    entries += [dict(entries[0], kind='event', name=name) for name in transitions]
                (out / 'koe-trace.json').write_text(json.dumps(entries))
                (out / ('syslog.txt' if platform == 'ios' else 'logcat.txt')).write_text(
                    ('2026-11-21' if platform == 'ios' else '11-21') + ' 12:00:00.000 Koe host launched\n')
            workspace = out / 'workspace'
            (workspace / 'audio').mkdir(parents=True)
            self.state = {'ask': {'scope': 'note-1', 'messages': [{'role': 'user', 'text': 'M9Revised', 'sources': []},
                                               {'role': 'assistant', 'text': 'M9Revised [S1]', 'sources': [{'record_id': 'note-1'}]}]},
                          'provider': {'model': 'deepseek-v4-pro', 'speech_engine': 'cloud'}, 'records': [
                {'id': 'note-1', 'project': 'M9Project', 'title': 'M9Note', 'highlighted_segments': [1], 'segments': [
                    {'id': 1, 'text': 'M9Revised', 'original_text': 'M9Note'}]},
                {'id': 'archive-4', 'title': 'M9Archive', 'archived': True},
                {'id': 'synced-3', 'title': 'M9Synced', 'segments': [{'speaker': 'Bob'}, {'speaker': 'Bob'}]},
                {'id': 'mic-2', 'origin': 'microphone', 'duration_ms': 1000}]}
            self.state['items'] = [dict(kind=kind, text=text, review=review) for kind in ('task', 'memory')
                                   for text, review in [('核对会议纪要', 'accepted'), ('整理项目文档', 'proposed')]]
            (workspace / 'product-workspace.json').write_text(json.dumps(self.state))
            live = self.root / platform / 'live/workspace'
            live.mkdir()
            (live / 'product-workspace.json').write_text(json.dumps(self.state))
            with wave.open(str(workspace / 'audio/mic-2.wav'), 'wb') as audio:
                audio.setparams((1, 2, 8000, 0, 'NONE', 'not compressed'))
                audio.writeframes(bytes(16000))
            (live / 'audio').mkdir()
            shutil.copyfile(workspace / 'audio/mic-2.wav', live / 'audio/mic-2.wav')

    def verify(self):
        return subprocess.run([sys.executable, str(Path(__file__).with_name('verify_mobile_e2e.py')), str(self.root)],
                              capture_output=True, text=True)

    def test_complete_and_corrupted_bundles(self):
        good = self.verify()
        self.assertEqual(good.returncode, 0, good.stderr)
        base = self.root / 'android'
        device = json.loads((base / 'device/koe-trace.json').read_text())
        device[0]['hasError'] = True
        live_trace = json.loads((base / 'live/koe-trace.json').read_text())
        for rel, data in (
            ('live/maestro_debug/capture.png', png()[:-9]),
            ('live/koe-trace.json', b'[]'),
            ('live/koe-trace.json', json.dumps([e for e in live_trace if e['name'] != 'resume_microphone']).encode()),
            ('device/koe-trace.json', json.dumps(device).encode()),
            ('restart/logcat.txt', b'11-21 12:00:00.000 FATAL EXCEPTION: main'),
            ('restart/logcat.txt', b'--------- beginning of main'),
            ('device-link/maestro_debug/synced-detail.png', png()[:-1]),
            ('live/workspace/product-workspace.json', b'{"records":[]}'),
            ('restart/workspace/product-workspace.json', b'{"records":[]}'),
            ('restart/workspace/audio/mic-2.wav', b'RIFF' + bytes(4) + b'WAVE' + bytes(64)),
        ):
            path = base / rel
            original = path.read_bytes()
            with self.subTest(path=rel):
                path.write_bytes(data)
                self.assertNotEqual(self.verify().returncode, 0)
            path.write_bytes(original)


if __name__ == '__main__':
    unittest.main()
