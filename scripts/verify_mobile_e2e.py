#!/usr/bin/env python3
"""Verify the ios/{live,device,device-link,restart} and android/{live,device,device-link,restart} evidence bundles."""
import argparse
import filecmp
import json
from pathlib import Path
import re
import struct
import wave
import zlib


PAGES = {'live': 'settings project capture playback mini-player detail actions answer source-focused trash purged', 'device': 'device', 'device-link': 'synced-detail', 'restart': 'restart'}
COMMANDS = {
    'live': set('configure_speech configure_provider create_note set_record_project start_capture_mode capture_action playback seek '
                'edit_segment_text rename_speaker add_highlight export_workspace_markdown review_item set_ask_scope ask open_source set_record_archived trash_record '
                'restore_record purge_record'.split()),
    'device': {'device_release'},
    'device-link': {'select_record'},
    'restart': {'sync_app_metadata'},
}
CRASH = re.compile(r'FATAL EXCEPTION|EXC_BAD_ACCESS|Fatal error:|uncaught exception|SIG(?:ABRT|SEGV)|'
                   r'terminating app due to|Fatal signal (?:6|11)', re.I)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify_png(path):
    """Check chunk order/CRCs, zlib termination and complete scanlines, including Adam7 passes."""
    data = path.read_bytes()
    require(data.startswith(b'\x89PNG\r\n\x1a\n'), path)
    offset = 8
    image = bytearray()
    passes = []
    palette = False
    color = None
    previous = None
    while offset + 12 <= len(data):
        size, kind = struct.unpack_from('>I4s', data, offset)
        payload = data[offset + 8:offset + 8 + size]
        end = offset + size + 12
        require(end <= len(data) and zlib.crc32(kind + payload) == int.from_bytes(data[end-4:end], 'big'), path)
        if previous is None:
            require(kind == b'IHDR' and size == 13, path)
            width, height, depth, color, comp, filt, interlace = struct.unpack('>IIBBBBB', payload)
            depths = {0: (1, 2, 4, 8, 16), 2: (8, 16), 3: (1, 2, 4, 8), 4: (8, 16), 6: (8, 16)}
            require(width and height and depth in depths.get(color, ()) and comp == filt == 0 and interlace <= 1, path)
            bits = depth * {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color]
            tiles = ((0, 0, 1, 1),) if not interlace else (
                (0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4),
                (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2))
            for x, y, dx, dy in tiles:
                if width > x and height > y:
                    columns = (width - x + dx - 1) // dx
                    rows = (height - y + dy - 1) // dy
                    passes.append((1 + (columns * bits + 7) // 8, rows))
        elif kind == b'PLTE':
            require(not palette and not image and color in (2, 3, 6) and 0 < size <= 768 and size % 3 == 0, path)
            require(color != 3 or size <= 3 * (1 << depth), path)
            palette = True
        elif kind == b'IDAT':
            require((color != 3 or palette) and (not image or previous == kind), path)
            image.extend(payload)
        elif kind == b'IEND':
            require(size == 0 and end == len(data), path)
            expected = sum(stride * rows for stride, rows in passes)
            decoder = zlib.decompressobj()
            pixels = decoder.decompress(image, expected + 1)
            require(decoder.eof and not decoder.unused_data and len(pixels) == expected, path)
            pos = 0
            for stride, rows in passes:
                stop = pos + stride * rows
                require(all(f < 5 for f in pixels[pos:stop:stride]), path)
                pos = stop
            return
        else:
            require(kind[:1].islower(), f'{path}: unexpected critical chunk {kind!r}')
        offset = end
        previous = kind
    raise ValueError(f'{path}: incomplete PNG')


def verify_phase(directory, platform, phase):
    for page in PAGES[phase].split():
        screenshots = list((directory / 'maestro_debug').rglob(page + '.png'))
        require(len(screenshots) == 1, f'{directory}: expected one {page}.png')
        verify_png(screenshots[0])
    log = (directory / ('syslog.txt' if platform == 'ios' else 'logcat.txt')).read_text()
    time_pattern = r'(?m)^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:' if platform == 'ios' else r'(?m)^\d{2}-\d{2} \d{2}:\d{2}:'
    require(re.search(time_pattern, log) and not CRASH.search(log), f'{directory}: missing log entries or crash signature')
    entries = json.loads((directory / 'koe-trace.json').read_text())
    require(isinstance(entries, list) and entries, f'{directory}: missing host trace')
    observed = []
    for entry in entries:
        require(isinstance(entry, dict) and isinstance(entry.get('hasError'), bool)
                and isinstance(entry.get('name'), str) and isinstance(entry.get('section'), str)
                and type(entry.get('generation')) is int and type(entry.get('timestampEpochMs')) is int,
                f'{directory}: invalid trace entry')
        expected_device_load_error = phase.startswith('device') and entry.get('kind') in ('fixture', 'snapshot')
        if entry['hasError']:
            require(expected_device_load_error, f'{directory}: {entry}')
        if entry.get('kind') == 'command' or (phase == 'restart' and entry.get('kind') == 'event'):
            observed.append(entry['name'])
    missing = COMMANDS[phase] - set(observed)
    require(not missing, f'{directory}: missing commands {sorted(missing)}')

    if phase == 'live':
        require(observed.count('ask') == 1, f'{directory}: expected a single question submission')
        adapters = iter(entry['name'] for entry in entries if entry.get('kind') == 'event')
        lifecycle = ('microphone_started', 'microphone_paused', 'resume_microphone',
                     'microphone_started', 'microphone_stopped')
        require(all(name in adapters for name in lifecycle), f'{directory}: missing microphone adapter transition')
        require(observed.count('capture_action') >= 2 and observed.count('review_item') >= 6,
                f'{directory}: incomplete capture/review lifecycle')
        lifecycle = [name for name in observed if name in ('trash_record', 'restore_record', 'purge_record')]
        require(lifecycle == ['trash_record', 'restore_record', 'trash_record', 'purge_record'],
                f'{directory}: invalid trash/undo/purge sequence {lifecycle}')


def verify_workspace(directory, before):
    state = json.loads((directory / 'product-workspace.json').read_text())
    require(state['provider']['model'] == 'deepseek-v4-pro' and state['provider']['speech_engine'] == 'cloud', f'{directory}: model did not survive restart')
    records = state['records']
    notes = [r for r in records if r.get('project') == 'M9Project' and r.get('title') == 'M9Note'
             and r.get('trashed_at_ms') is None]
    require(len(notes) == 1 and any(s.get('original_text') == 'M9Note' and s['text'] == 'M9Revised'
                                    and s['id'] in notes[0]['highlighted_segments']
                                    for s in notes[0]['segments']), f'{directory}: missing surviving note revision/project')
    reviews = {(item['kind'], item['text']): item['review'] for item in state['items']}
    for kind in ('task', 'memory'):
        require(reviews.get((kind, '核对会议纪要')) == 'accepted' and reviews.get((kind, '整理项目文档')) == 'proposed',
                f'{directory}: {kind} accept/reset did not persist')
    messages = state['ask']['messages']
    require(state['ask']['scope'] == notes[0]['id'] and any(m.get('role') == 'user' and m.get('text') == 'M9Revised' for m in messages) and
            any(line.get('record_id') == notes[0]['id'] for m in messages if m.get('role') == 'assistant' for line in m['sources']),
            f'{directory}: scoped question or linked source did not survive')
    require(not any(r.get('title') == 'M9Disposable' for r in records), f'{directory}: purge did not persist')
    archived = [r for r in records if r.get('title') == 'M9Archive' and r.get('archived') is True
                and r.get('trashed_at_ms') is None]
    require(len(archived) == 1, f'{directory}: the protected archive did not survive')
    synced = [r for r in records if r.get('title') == 'M9Synced']
    require(len(synced) == 1 and [s.get('speaker') for s in synced[0]['segments']] == ['Bob', 'Bob'],
            f'{directory}: expected both original speakers to merge into Bob')
    microphones = [r for r in records if r.get('origin') == 'microphone' and r.get('duration_ms', 0) > 0]
    require(microphones, f'{directory}: missing captured microphone record')
    previous = json.loads((before / 'product-workspace.json').read_text())
    records_by_persisted_id = {r['id']: r for r in previous['records']}
    require(state['provider'] == previous['provider'], f'{directory}: provider settings changed on restart')
    for survivor in [*notes, *synced, *archived, *microphones]:
        old = records_by_persisted_id.get(survivor['id'])
        fields = ('title', 'origin', 'project', 'content_revision', 'segments', 'highlighted_segments', 'duration_ms', 'archived')
        require(old is not None and all(old.get(k) == survivor.get(k) for k in fields),
                f'{directory}: record content changed on restart')
    for record in microphones:
        require(re.fullmatch(r'[a-zA-Z0-9-]+', record['id']), 'invalid microphone id')
        wav = directory / 'audio' / (record['id'] + '.wav')
        require(filecmp.cmp(wav, before / 'audio' / wav.name, shallow=False), f'{wav}: captured audio changed on restart')
        with wave.open(str(wav), 'rb') as stream:
            frames = stream.getnframes()
            require(wav.stat().st_size > 44 and frames > 0 and
                    len(stream.readframes(frames)) == frames * stream.getsampwidth() * stream.getnchannels(), wav)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('evidence', type=Path)
    args = parser.parse_args()
    for platform in ('ios', 'android'):
        for phase in PAGES:
            verify_phase(args.evidence / platform / phase, platform, phase)
        verify_workspace(args.evidence / platform / 'restart/workspace', args.evidence / platform / 'live/workspace')
    print('Both platforms passed screenshot, trace, crash log and workspace verification.')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, EOFError, wave.Error, zlib.error) as error:
        raise SystemExit(f'Evidence verification failed: {error}')
