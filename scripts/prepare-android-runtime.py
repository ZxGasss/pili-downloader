from pathlib import Path
import xml.etree.ElementTree as ET
import hashlib, subprocess, zipfile, concurrent.futures
root=Path(__file__).resolve().parents[1]
sdk=root/'work/toolchains/android-sdk';cache=root/'.cache/toolchains'
tasks=[]
repo=ET.parse(root/'.cache/android-repository-v3.xml').getroot()
for package in repo.findall('remotePackage'):
    name=package.attrib.get('path')
    if name not in ['emulator','platform-tools'] or any(t[0]==name for t in tasks):continue
    for a in package.findall('./archives/archive'):
        if a.findtext('host-os')=='macosx' and a.findtext('host-arch') in [None,'aarch64']:
            z=a.find('complete');tasks.append((name,'https://dl.google.com/android/repository/'+z.findtext('url'),z.findtext('checksum'),sdk));break
repo=ET.parse(root/'.cache/android-system-images.xml').getroot()
for package in repo.findall('remotePackage'):
    if package.attrib.get('path')=='system-images;android-35;google_apis;arm64-v8a':
        z=package.find('./archives/archive/complete');tasks.append(('android35-image','https://dl.google.com/android/repository/sys-img/google_apis/'+z.findtext('url'),z.findtext('checksum'),sdk/'system-images/android-35/google_apis'));break
def install(record):
    name,url,digest,dest=record;archive=cache/url.rsplit('/',1)[-1]
    if not archive.exists():subprocess.run(['curl','-fL','--silent','--show-error','--max-time','900','--retry','1',url,'-o',str(archive)],check=True,timeout=930)
    h=hashlib.sha1()
    with archive.open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
    if h.hexdigest()!=digest:raise RuntimeError('Checksum mismatch '+name)
    stamp=sdk/(name+'.installed')
    if not stamp.exists():
        dest.mkdir(parents=True,exist_ok=True)
        with zipfile.ZipFile(archive) as z:
            if any(Path(x).is_absolute() or '..' in Path(x).parts for x in z.namelist()):raise RuntimeError('Unsafe archive')
            z.extractall(dest)
            for i in z.infolist():
                mode=i.external_attr>>16
                if mode&0o111:(dest/i.filename).chmod(mode&0o777)
        stamp.write_text(digest)
    print('ANDROID_RUNTIME_VERIFIED',name,flush=True)
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:list(pool.map(install,tasks))
