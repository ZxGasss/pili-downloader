from pathlib import Path
import json, hashlib, subprocess, zipfile, shutil
root=Path(__file__).resolve().parents[1]
cache=root/'.cache/toolchains';cache.mkdir(exist_ok=True)
output=root/'outputs/霹雳下载-1.6.0-Windows'; tools=output/'Tools';tools.mkdir(exist_ok=True)
licenses=output/'Licenses';licenses.mkdir(exist_ok=True)
yt=json.loads((root/'.cache/ytdlp-release.json').read_text())
ff=json.loads((root/'.cache/ffmpeg-windows-release.json').read_text())
items=[next(a for a in yt['assets'] if a['name']=='yt-dlp.exe'),next(a for a in ff['assets'] if a['name']=='ffmpeg-n8.1-latest-win64-lgpl-8.1.zip')]
records=[]
for item in items:
    path=cache/item['name'];expected=item.get('digest')
    if not expected or not expected.startswith('sha256:'): raise RuntimeError('Vendor digest missing')
    if not path.exists():subprocess.run(['curl','-fL','--silent','--show-error','--retry','1','--max-time','360',item['browser_download_url'],'-o',str(path)],check=True,timeout=390)
    actual=hashlib.sha256(path.read_bytes()).hexdigest()
    if actual!=expected.split(':')[1]:raise RuntimeError('Digest mismatch '+path.name)
    if path.suffix=='.exe':shutil.copy2(path,tools/path.name)
    else:
        with zipfile.ZipFile(path) as archive:
            exe=next(n for n in archive.namelist() if n.endswith('/bin/ffmpeg.exe'))
            (tools/'ffmpeg.exe').write_bytes(archive.read(exe))
            for name in archive.namelist():
                base=Path(name).name
                if base and any(token in base.lower() for token in ['license','copying','readme','version']):
                    if not name.endswith('/'):(licenses/('FFmpeg-'+base)).write_bytes(archive.read(name))
    records.append({'name':item['name'],'url':item['browser_download_url'],'sha256':actual})
    print('VERIFIED_WINDOWS_TOOL',item['name'],flush=True)
for p in (root/'work/licenses').glob('*yt*'):shutil.copy2(p,licenses/p.name)
(output/'工具来源与校验.json').write_text(json.dumps(records,ensure_ascii=False,indent=2))
