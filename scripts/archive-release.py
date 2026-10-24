"""Whitelist-only archival; keep originals, credentials and heavyweight SDKs in place."""
from pathlib import Path
import argparse,shutil,json,hashlib,zipfile,difflib,datetime
root=Path(__file__).resolve().parents[1]
archive=Path(__import__('os').environ.get('PILI_ARCHIVE_ROOT',root/'release-archive'))
tag='2026-10-24_1.5.1_b21'
before=archive/'做前'/('需求与参考_'+tag)
snapshot=archive/'做中'/('软件工程_'+tag)
after=archive/'做后'/('大香蕉播放器_'+tag)
experiment=archive/'独立实验区'/('验证证据_'+tag)
latest=['大香蕉播放器-1.5.1-macOS通用版-b21.dmg','大香蕉播放器-1.5.1-Android-预览版.apk','大香蕉播放器-1.5.1-Windows-安装程序.exe','大香蕉播放器-1.5.1-Windows-便携版.zip']
proof=['state-tests-1.5.1.log','network-probe.log','network-probe-safe.json','mac-final-checks.log','macos-universal-build.log','macos-final-b21.log','macos-b21-build.log','dmg-content-test.log','intel-smoke.log','intel-runtime-test.log','android-final-build.log','android-final-runtime.log','windows-final-verification.log','windows-release-test.log','windows-installer-test.log','ios-parse-final.log','ios-project.log','build-ios.log','shared-smoke.log','shared-core-final.log','toolchain-manifest.json','range-benchmark.json','resume-1.3.json']
cache=['ytdlp-release.json','ffmpeg-windows-release.json','ugc-BV1QMTv6uE45.json','season1376-1.3.json','temurin17-mac.json','dotnet8-releases.json','android-repository.xml','android-repository-v3.xml','android-system-images.xml','ffmpeg-8.0.tar.xz','aria2-1.37.0.tar.xz','ffmpeg-windows-92611900bb.tar.gz','toolchains/net48-refs.nupkg','toolchains/ffmpeg-n8.1-latest-win64-lgpl-8.1.zip','toolchains/yt-dlp.exe']
def copy(source,target):
    if not source.exists():return
    target.parent.mkdir(parents=True,exist_ok=True)
    if source.is_dir():shutil.copytree(source,target,dirs_exist_ok=True,ignore=shutil.ignore_patterns('__pycache__'))
    else:shutil.copy2(source,target)
def digest(file):
    h=hashlib.sha256()
    with file.open('rb') as stream:
        for chunk in iter(lambda:stream.read(1024*1024),b''):h.update(chunk)
    return h.hexdigest()
parser=argparse.ArgumentParser();parser.add_argument('phase',choices=['prepare','finish']);phase=parser.parse_args().phase
for path in [before,snapshot,after,experiment]:path.mkdir(parents=True,exist_ok=True)
if phase=='prepare':
    for name in ['Sources','platforms','scripts','Tests','Info.plist','Package.swift','README.md','state.md','file-map.md']:copy(root/name,snapshot/name)
    for name in ['deps','licenses','AppIcon.icns','test-merged.mp4']:copy(root/'work'/name,snapshot/'work'/name)
    for name in cache:copy(root/'.cache'/name,snapshot/'.cache'/name)
    for name in proof:
        copy(root/'work'/name,snapshot/'work'/name);copy(root/'work'/name,experiment/name)
    copy(root/'work/android-build/mapping.txt',snapshot/'work/android-build/mapping.txt')
    copy(root/'work/windows-protected/Mapping.txt',snapshot/'work/windows-protected/Mapping.txt')
    for file in (root/'outputs').glob('*.md'):
        copy(file,before/file.name);copy(file,snapshot/'outputs'/file.name);copy(file,after/file.name)
    previous=after/'历史成品_原件仍保留'
    for file in (root/'outputs').iterdir():
        if file.is_file() and file.suffix in ['.dmg','.zip','.apk','.exe']:
            copy(file,after/file.name if file.name in latest else previous/file.name)
        elif file.is_dir():copy(file,previous/file.name)
    baseline=archive/'做中/软件工程_2026-10-24_1.5_v1'
    changes=[]
    for folder in ['Sources','scripts','Tests','platforms']:
        for file in sorted((root/folder).rglob('*')):
            if not file.is_file() or '__pycache__' in file.parts:continue
            relative=file.relative_to(root);old=baseline/relative
            try:
                new=file.read_text().splitlines();prior=old.read_text().splitlines() if old.exists() else []
                added=removed=0
                for kind,a,b,c,d in difflib.SequenceMatcher(None,prior,new).get_opcodes():
                    if kind in ['insert','replace']:added+=d-c
                    if kind in ['delete','replace']:removed+=b-a
                changes.append({'path':str(relative),'lines':len(new),'added':added,'removed':removed,'sha256':digest(file)})
            except UnicodeError:pass
    report={'baseline':str(baseline),'files':changes,'added':sum(x['added'] for x in changes),'removed':sum(x['removed'] for x in changes)}
    (root/'outputs/源码变更清单.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
    print('ARCHIVE_PREPARED',len(changes),'source files',report['added'],'added',report['removed'],'removed',flush=True)
else:
    for name in ['state.md','file-map.md']:copy(root/name,snapshot/name)
    for file in (root/'outputs').glob('*.md'):copy(file,snapshot/'outputs'/file.name);copy(file,after/file.name)
    copy(root/'outputs/源码变更清单.json',snapshot/'outputs/源码变更清单.json')
    copy(root/'state.md',archive/'state.md');copy(root/'file-map.md',archive/'文件图谱.md')
    source=root/'outputs/大香蕉播放器-1.5.1-b21-源码.zip'
    if source.exists():raise RuntimeError('Existing source release preserved')
    with zipfile.ZipFile(source,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as zipped:
        for file in sorted(snapshot.rglob('*')):
            if file.is_file():zipped.write(file,Path('大香蕉播放器-1.5.1')/file.relative_to(snapshot))
    with zipfile.ZipFile(source) as zipped:
        bad=zipped.testzip()
        if bad:raise RuntimeError('Source ZIP failed CRC: '+bad)
        names=zipped.namelist()
        for required in ['Sources/Main.swift','platforms/android/AndroidManifest.xml','platforms/windows/Banana.cs','platforms/ios/BananaApp.swift','state.md','file-map.md']:
            if not any(n.endswith('/'+required) for n in names):raise RuntimeError('Source missing '+required)
        if any('/work/signing/' in name or '/WebKit/' in name for name in names):raise RuntimeError('Private data not allowed')
    manifest={'version':'1.5.1','macBuild':21,'sourceCRC':'PASS','artifacts':[],'archive':{'before':str(before),'during':str(snapshot),'after':str(after),'experiments':str(experiment)},'notDelivered':['IPA','full SKU exhaustive inventory','full platform feature parity','Win7 and all legacy hardware validation']}
    for name in latest+[source.name]:
        file=root/'outputs'/name
        if not file.exists():raise RuntimeError('Missing artifact '+name)
        manifest['artifacts'].append({'name':name,'bytes':file.stat().st_size,'sha256':digest(file)})
        copy(file,after/name)
    path=root/'outputs/交付校验清单.json';path.write_text(json.dumps(manifest,ensure_ascii=False,indent=2));copy(path,after/path.name)
    copy(root/'outputs/源码变更清单.json',after/'源码变更清单.json')
    print('ARCHIVE_AND_SOURCE_CRC_PASS',len(manifest['artifacts']),'deliverables',flush=True)
