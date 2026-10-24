from pathlib import Path
import hashlib,json,re,subprocess,zipfile
root=Path(__file__).resolve().parents[1]
manifest=json.loads((root/'outputs/交付校验清单.json').read_text())
for artifact in manifest['artifacts']:
    file=root/'outputs'/artifact['name'];h=hashlib.sha256()
    with file.open('rb') as stream:
        for chunk in iter(lambda:stream.read(1024*1024),b''):h.update(chunk)
    if h.hexdigest()!=artifact['sha256'] or file.stat().st_size!=artifact['bytes']:raise RuntimeError('Changed artifact '+file.name)
plan=(root/'outputs/大香蕉播放器-300条优化与验收方案.md').read_text()
if [int(x) for x in re.findall(r'(?m)^(\d+)\. ',plan)]!=list(range(1,301)):raise RuntimeError('Plan item count')
source=next(x for x in manifest['artifacts'] if x['name'].endswith('源码.zip'))
with zipfile.ZipFile(root/'outputs'/source['name']) as zipped:
    if zipped.testzip():raise RuntimeError('Source ZIP CRC failure')
print('DELIVERABLE_HASHES_PASS',len(manifest['artifacts']))
print('SOURCE_CRC_AND_300_PLAN_ITEMS_PASS')
