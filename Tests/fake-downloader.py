#!/usr/bin/python3
"""Owned fixture transport for testing the native backend event boundary."""
import json
import shutil
import time
import pathlib
import sys

args = sys.argv[1:]
if '--skip-download' in args:
    print('PLMETA:' + json.dumps({'id': args[-1].rsplit('/', 1)[-1], 'title': '自制解析测试',
          'formats': [{'format_id': 'v', 'height': 1080, 'vcodec': 'h264', 'acodec': 'none'}]}), flush=True)
    sys.exit(0)
folder = pathlib.Path(args[args.index('-P') + 1])
with (folder / 'calls.jsonl').open('a') as handle:
    handle.write(json.dumps(args) + '\n')
identifier = args[-1].rsplit('/', 1)[-1]
if '--load-info-json' in args:
    identifier = json.loads(pathlib.Path(args[args.index('--load-info-json') + 1]).read_text())['id']
def event(kind):
    with (folder / 'events.jsonl').open('a') as handle:
        handle.write(json.dumps({'event': kind, 'id': identifier, 'time': time.monotonic()}) + '\n')
event('start')
if (folder / 'recover-once').exists() and not (folder / 'recovery-triggered').exists():
    (folder / 'recovery-triggered').write_text('owned transient failure')
    print('ERROR: Connection reset by peer', flush=True)
    sys.exit(1)
time.sleep(0.35)
part = folder / 'owned-resume.part'
if (folder / 'slow-fixture').exists():
    prior = part.stat().st_size if part.exists() else 0
    for position in range(prior // 1024, 24):
        with part.open('ab') as stream:
            stream.write(b'x' * 1024)
        print(f'PLPROGRESS|{(position + 1) / 24 * 100}%|4096|3|v|{(position + 1) * 1024}|24576|24576', flush=True)
        time.sleep(0.12)
template = args[args.index('-o') + 1]
name = template.split('/')[-1].split(' - ')[0] + '-' + identifier + '.mp4'
output = folder / name
fixture = pathlib.Path(__file__).parent / 'fixture.mp4'
if fixture.exists(): shutil.copyfile(fixture, output)
else: output.write_bytes(b'owned-test-fixture')
if part.exists(): part.unlink()
print('PLITEM:' + json.dumps({'id': identifier, 'title': '测试 ' + identifier,
      'thumbnail': 'https://example.invalid/' + identifier + '.jpg'}), flush=True)
print('PLPROGRESS|100%|1024|0|v|18|18|18', flush=True)
print('PLFILE:' + str(output), flush=True)
event('end')
