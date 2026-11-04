import json
import hashlib
from datetime import datetime, timedelta, timezone
from pathlib import Path
import select
import shutil
import subprocess
import sys
import tempfile
import unittest


SERVER = Path(__file__).with_name('server.py')


def manifest():
    return {
        'format': 'koe-material-pack', 'version': 1,
        'exportedAt': '2026-11-04T10:00:00Z',
        'material': {'contentHash': 'a' * 64, 'title': '合成测试', 'source': 'device'},
        'audio': {'included': False},
        'transcript': {'text': '说话人 1：仅先试用。', 'revision': 2,
                       'segments': [{'text': '仅先试用。', 'startMs': 0, 'endMs': 2000, 'speaker': '1'}],
                       'speakerAliases': {'2': '小林'}, 'segmentSpeakers': {'0': '2'}},
    }


def write_pack(path, value):
    body = json.dumps(value, ensure_ascii=False).encode()
    path.write_bytes(b'KOEPACK1\n' + str(len(body)).encode() + b'\n' + body)


class Client:
    def __init__(self, directory, live=False):
        self.process = subprocess.Popen(
            [sys.executable, str(SERVER), '--live-directory' if live else '--directory', str(directory)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.sequence = 0

    def send(self, message):
        self.process.stdin.write(json.dumps(message).encode() + b'\n')
        self.process.stdin.flush()

    def request(self, method, params=None):
        self.sequence += 1
        self.send({'jsonrpc': '2.0', 'id': self.sequence, 'method': method, 'params': params or {}})
        ready, _, _ = select.select([self.process.stdout], [], [], 5)
        if not ready:
            raise AssertionError('Server did not answer within five seconds')
        line = self.process.stdout.readline()
        if not line:
            raise AssertionError('Server exited without a protocol response')
        response = json.loads(line)
        assert response['id'] == self.sequence
        return response

    def initialize(self):
        result = self.request('initialize', {
            'protocolVersion': '2025-11-25', 'capabilities': {},
            'clientInfo': {'name': 'koe-test', 'version': '1'},
        })
        self.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        return result

    def call(self, name, **arguments):
        return self.request('tools/call', {'name': name, 'arguments': arguments})['result']

    def data(self, name, **arguments):
        result = self.call(name, **arguments)
        assert not result.get('isError'), result
        return json.loads(result['content'][0]['text'])

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        for stream in [self.process.stdin, self.process.stdout, self.process.stderr]:
            stream.close()


class ServerTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.pack = self.root / 'sample.koepack'
        write_pack(self.pack, manifest())
        self.client = Client(self.root)
        self.addCleanup(self.client.close)
        self.client.initialize()

    def recording_id(self):
        return self.client.data('list_recordings')['recordings'][0]['recording_id']

    def test_discovery_and_transcript_sources(self):
        tools = self.client.request('tools/list')['result']['tools']
        self.assertEqual([t['name'] for t in tools], ['list_recordings', 'get_transcript', 'get_minutes'])
        result = self.client.data('get_transcript', recording_id=self.recording_id())
        self.assertEqual(result['text'], '说话人 1：仅先试用。')
        self.assertEqual(result['sources'][0]['speaker'], '小林')
        self.assertEqual(result['sources'][0]['startMs'], 0)
        self.assertTrue(result['timingReliable'])
        self.assertFalse(self.client.data('get_minutes', recording_id=self.recording_id())['hasMinutes'])
        self.assertNotIn(str(self.root), json.dumps(result))

    def test_manual_text_has_no_old_timestamps(self):
        value = manifest()
        value['transcript']['manual'] = '先试用十人。\n负责人尚未确定。'
        write_pack(self.pack, value)
        result = self.client.data('get_transcript', recording_id=self.recording_id())
        self.assertEqual(result['text'], value['transcript']['manual'])
        self.assertFalse(result['timingReliable'])
        self.assertEqual([s['text'] for s in result['sources']], ['先试用十人。', '负责人尚未确定。'])
        self.assertNotIn('startMs', result['sources'][0])

    def test_removal_and_replacement_revoke_old_id(self):
        old_id = self.recording_id()
        value = manifest()
        value['transcript']['manual'] = '已修改。'
        write_pack(self.pack, value)
        self.assertTrue(self.client.call('get_transcript', recording_id=old_id)['isError'])
        new_id = self.recording_id()
        self.assertNotEqual(old_id, new_id)
        self.pack.unlink()
        self.assertTrue(self.client.call('get_transcript', recording_id=new_id)['isError'])

    def test_symlink_and_nested_files_are_not_read(self):
        nested = self.root / 'nested'
        nested.mkdir()
        target = nested / 'private.koepack'
        write_pack(target, manifest())
        self.pack.unlink()
        self.pack.symlink_to(target)
        result = self.client.data('list_recordings')
        self.assertEqual(result['recordings'], [])
        self.assertEqual(result['rejectedCount'], 1)
        self.assertTrue(self.client.call('get_transcript', recording_id='../private.koepack')['isError'])

    def test_invalid_pack_variants_are_rejected_without_content(self):
        mutations = [lambda p: p.update(version=3),
                     lambda p: p.update(version=True),
                     lambda p: p.update(audio={'included': True}),
                     lambda p: p['transcript'].update(segments=[{'text': 'secret', 'startMs': -1}]),
                     lambda p: p.update(minutes={'current': {}, 'history': []})]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                value = manifest()
                mutate(value)
                write_pack(self.pack, value)
                result = self.client.data('list_recordings')
                self.assertEqual(result['recordings'], [])
                self.assertEqual(result['rejectedCount'], 1)
        for raw in [b'KOEPACK1\n100\n{}', b'KOEPACK1\n33554433\n{}', b'KOEPACK1\n2\n{}tail']:
            self.pack.write_bytes(raw)
            self.assertEqual(self.client.data('list_recordings')['rejectedCount'], 1)

    def test_protocol_errors_do_not_break_subsequent_calls(self):
        self.assertEqual(self.client.request('unsupported')['error']['code'], -32601)
        self.assertTrue(self.client.call('get_transcript', recording_id=self.recording_id(), path='/secret')['isError'])
        self.assertTrue(self.client.call('delete_recording')['isError'])
        self.assertEqual(self.client.request('ping')['result'], {})

    def test_nonstring_tool_name_does_not_terminate_server(self):
        self.assertTrue(self.client.call([])['isError'])
        self.assertEqual(self.client.request('ping')['result'], {})

    def test_invalid_unicode_in_export_does_not_terminate_server(self):
        value = manifest()
        value['material']['title'] = '\ud800'
        body = json.dumps(value).encode()
        self.pack.write_bytes(b'KOEPACK1\n' + str(len(body)).encode() + b'\n' + body)
        listing = self.client.data('list_recordings')
        self.assertEqual(listing['recordings'], [])
        self.assertEqual(listing['rejectedCount'], 1)
        self.assertEqual(self.client.request('ping')['result'], {})

    def test_invalid_unicode_request_is_rejected_without_crash(self):
        self.client.send({'jsonrpc': '2.0', 'id': '\ud800', 'method': 'ping'})
        ready, _, _ = select.select([self.client.process.stdout], [], [], 5)
        self.assertTrue(ready)
        line = self.client.process.stdout.readline()
        self.assertTrue(line)
        self.assertEqual(json.loads(line)['error']['code'], -32700)
        self.assertEqual(self.client.request('ping')['result'], {})

    def test_large_result_fails_explicitly(self):
        value = manifest()
        value['transcript']['manual'] = 'x' * 1100000
        write_pack(self.pack, value)
        result = self.client.call('get_transcript', recording_id=self.recording_id())
        self.assertTrue(result['isError'])
        self.assertIn('response_too_large', result['content'][0]['text'])

    def test_scan_budget_is_an_error_not_partial_success(self):
        self.pack.unlink()
        for index in range(5):
            with (self.root / f'large-{index}.koepack').open('wb') as stream:
                stream.write(b'invalid')
                stream.truncate(16 * 1024 * 1024)
        result = self.client.call('list_recordings')
        self.assertTrue(result['isError'])
        self.assertIn('export_directory_too_large', result['content'][0]['text'])
        self.assertEqual(self.client.request('ping')['result'], {})


class LiveServerTest(unittest.TestCase):
    identifier = 'b' * 64

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.live = self.root / 'live.json'
        self.publish({})
        self.client = Client(self.root, live=True)
        self.addCleanup(self.client.close)
        self.client.initialize()

    def publish(self, records, generation=1, seconds=15):
        value = {'version': 1, 'generation': generation,
                 'expiresAt': (datetime.now(timezone.utc) + timedelta(seconds=seconds)).isoformat(),
                 'records': records}
        temporary = self.root / 'live.part'
        temporary.write_text(json.dumps(value))
        temporary.replace(self.live)

    def error(self, tool, **arguments):
        result = self.client.call(tool, **arguments)
        self.assertTrue(result['isError'])
        return json.loads(result['content'][0]['text'])['error']

    def test_updates_use_stable_id_and_old_revision_is_rejected(self):
        self.assertEqual(self.client.data('list_recordings')['recordings'], [])
        value = manifest()
        self.publish({self.identifier: value})
        listing = self.client.data('list_recordings')
        self.assertFalse(listing['snapshotOnly'])
        self.assertEqual(listing['snapshotRevision'], '1')
        self.assertEqual(listing['recordings'][0]['recording_id'], self.identifier)
        self.assertEqual(listing['recordings'][0]['materialContentHash'], 'a' * 64)
        value['transcript']['manual'] = '校订后的新文字'
        self.publish({self.identifier: value}, generation=2)
        self.assertEqual(self.error('get_transcript', recording_id=self.identifier,
                                    expected_revision='1'), 'snapshot_changed')
        result = self.client.data('get_transcript', recording_id=self.identifier, expected_revision='2')
        self.assertEqual(result['text'], '校订后的新文字')
        self.assertEqual(result['snapshotRevision'], '2')
        self.assertEqual(result['materialContentHash'], 'a' * 64)
        minutes = self.client.data('get_minutes', recording_id=self.identifier)
        self.assertEqual(minutes['materialContentHash'], 'a' * 64)
        self.assertNotIn('startMs', result['sources'][0])

    def test_revoke_removes_access_without_restarting_client(self):
        self.publish({self.identifier: manifest()})
        self.client.data('get_transcript', recording_id=self.identifier)
        self.publish({}, generation=2)
        self.assertEqual(self.client.data('list_recordings')['recordings'], [])
        self.assertEqual(self.error('get_transcript', recording_id=self.identifier), 'recording_unavailable')

    def test_missing_expired_or_unbounded_lease_is_not_an_empty_success(self):
        self.publish({self.identifier: manifest()}, seconds=-1)
        self.assertEqual(self.error('list_recordings'), 'publication_expired')
        self.publish({self.identifier: manifest()}, seconds=3600)
        self.assertEqual(self.error('list_recordings'), 'invalid_publication')
        self.live.unlink()
        self.assertEqual(self.error('list_recordings'), 'publication_unavailable')
        self.publish({self.identifier: manifest()})
        self.assertEqual(len(self.client.data('list_recordings')['recordings']), 1)

    def test_invalid_record_rejects_entire_generation(self):
        invalid = manifest()
        invalid['audio']['included'] = True
        self.publish({self.identifier: manifest(), 'c' * 64: invalid})
        self.assertEqual(self.error('list_recordings'), 'invalid_publication')
        for value in [[], {'version': 1, 'generation': True, 'records': {}},
                      {'version': 1, 'generation': 0, 'records': {}, 'expiresAt': '2026-11-05'}]:
            self.live.write_text(json.dumps(value))
            self.assertEqual(self.error('list_recordings'), 'invalid_publication')
        self.assertEqual(self.client.request('ping')['result'], {})

    def test_symlink_and_replaced_directory_cannot_retain_access(self):
        outside = self.root / 'private.json'
        self.publish({self.identifier: manifest()})
        self.live.rename(outside)
        self.live.symlink_to(outside)
        self.assertEqual(self.error('list_recordings'), 'publication_unavailable')
        self.live.unlink()
        moved = self.root.with_name(self.root.name + '-moved')
        self.root.rename(moved)
        self.root.mkdir()
        self.addCleanup(lambda: shutil.rmtree(moved))
        self.publish({self.identifier: manifest()})
        self.assertEqual(self.error('list_recordings'), 'directory_replaced')

    def test_live_limits_fail_closed_and_schema_exposes_revision_guard(self):
        tools = self.client.request('tools/list')['result']['tools']
        self.assertEqual([tool['name'] for tool in tools], ['list_recordings', 'get_transcript', 'get_minutes'])
        self.assertIn('expected_revision', tools[1]['inputSchema']['properties'])
        self.publish({format(index, '064x'): manifest() for index in range(1001)})
        self.assertEqual(self.error('list_recordings'), 'invalid_publication')
        with self.live.open('wb') as output:
            output.truncate(32 * 1024 * 1024 + 1)
        self.assertEqual(self.error('list_recordings'), 'invalid_publication')
        self.publish({self.identifier: manifest()})
        self.assertEqual(self.error('get_transcript', recording_id=self.identifier,
                                    expected_revision=1), 'invalid_arguments')
        self.assertEqual(self.error('list_recordings', expected_revision='1'), 'invalid_arguments')
        self.assertEqual(self.client.request('ping')['result'], {})

    def test_minutes_freshness_compares_effective_text_in_same_generation(self):
        value = manifest()
        value['version'] = 2
        text = value['transcript']['text']
        value['minutes'] = {'current': {
            'text': '{"title":"合成纪要"}', 'sourceHash': hashlib.sha256(text.encode()).hexdigest(),
            'model': 'synthetic', 'instruction': '', 'sources': [text],
            'createdAt': '2026-11-04T10:00:00Z', 'templateVersion': 1, 'isDraft': False,
        }, 'history': []}
        self.publish({self.identifier: value})
        self.assertEqual(self.client.data('get_minutes', recording_id=self.identifier)['freshness'], 'current')
        value['transcript']['manual'] = '校订后的原文'
        self.publish({self.identifier: value}, generation=2)
        result = self.client.data('get_minutes', recording_id=self.identifier)
        self.assertEqual(result['freshness'], 'stale')
        self.assertEqual(result['snapshotRevision'], '2')
        self.assertEqual(result['current']['sources'], [text])
        value.pop('transcript')
        self.publish({self.identifier: value}, generation=3)
        self.assertEqual(self.client.data('get_minutes', recording_id=self.identifier)['freshness'], 'unverified')


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--probe':
        client = Client(Path(sys.argv[2]))
        try:
            initialization = client.initialize()
            names = [t['name'] for t in client.request('tools/list')['result']['tools']]
            listing = client.data('list_recordings')
            recordings = []
            for recording in listing['recordings']:
                identifier = recording['recording_id']
                recordings.append({'metadata': recording,
                                   'transcript': client.data('get_transcript', recording_id=identifier),
                                   'minutes': client.data('get_minutes', recording_id=identifier)})
            print(json.dumps({'tools': names, 'rejectedCount': listing['rejectedCount'],
                              'recordings': recordings}, ensure_ascii=False, indent=2))
        finally:
            client.close()
    else:
        unittest.main()
