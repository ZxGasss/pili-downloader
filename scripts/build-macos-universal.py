"""Build both desktop architectures; this does not lower the macOS 13 requirement."""
from pathlib import Path
import subprocess,shutil,plistlib,sys
root=Path(__file__).resolve().parents[1]
info=plistlib.loads((root/'Info.plist').read_bytes());version=info['CFBundleShortVersionString'];name=info['CFBundleDisplayName']
source=root/'outputs'/f'{name}-{version}'/f'{name}.app'
app=root/'outputs'/f'{name}-{version}-macOS通用版'/f'{name}.app'
app.parent.mkdir(exist_ok=True)
subprocess.run(['ditto',str(source),str(app)],check=True,timeout=60)
shutil.copy2(root/'README.md',app/'Contents/Resources/使用说明.md')
intel=root/'work/intel';exe=intel/'PiliDownloader'
subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-target','x86_64-apple-macosx13.0','-O',*map(str,sorted((root/'Sources').glob('*.swift'))),'-o',str(exe)],check=True,timeout=180)
subprocess.run(['strip','-x',str(exe)],check=True,timeout=20)
pairs=[(source/'Contents/MacOS/PiliDownloader',exe,app/'Contents/MacOS/PiliDownloader'),(root/'work/deps/ffmpeg',intel/'ffmpeg-8.0/ffmpeg',app/'Contents/Resources/Tools/ffmpeg'),(root/'work/deps/aria2c',intel/'aria2-1.37.0/src/aria2c',app/'Contents/Resources/Tools/aria2c')]
thumbnail=intel/'PiliThumbnail'
subprocess.run(['swiftc','-swift-version','5','-parse-as-library','-target','x86_64-apple-macosx13.0','-O',str(root/'Tools/ThumbnailWorker.swift'),'-o',str(thumbnail)],check=True,timeout=90)
pairs.append((source/'Contents/Resources/Tools/PiliThumbnail',thumbnail,app/'Contents/Resources/Tools/PiliThumbnail'))
for arm,x86,output in pairs:
    subprocess.run(['lipo','-create',str(arm),str(x86),'-output',str(output)],check=True,timeout=30)
    subprocess.run(['codesign','--force','--sign','-',str(output)],check=True,timeout=30)
subprocess.run(['codesign','--force','--sign','-',str(app/'Contents/Resources/Tools/yt-dlp')],check=True,timeout=30)
subprocess.run(['codesign','--force','--sign','-',str(app)],check=True,timeout=30)
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True,timeout=30)
for relative in ['Contents/MacOS/PiliDownloader','Contents/Resources/Tools/ffmpeg','Contents/Resources/Tools/aria2c','Contents/Resources/Tools/yt-dlp','Contents/Resources/Tools/PiliThumbnail']:
    result=subprocess.run(['lipo','-archs',str(app/relative)],capture_output=True,text=True,check=True,timeout=10)
    if not all(arch in result.stdout for arch in ['arm64','x86_64']):raise RuntimeError('Architecture missing '+relative)
    print('UNIVERSAL_ARCH_OK',relative,result.stdout.strip(),flush=True)
if '--no-package' in sys.argv:raise SystemExit(0)
dmgroot=root/f'work/dmg-universal-{version}';dmgroot.mkdir(exist_ok=True)
subprocess.run(['ditto',str(app),str(dmgroot/app.name)],check=True,timeout=60)
link=dmgroot/'Applications'
if not link.exists():link.symlink_to('/Applications')
shutil.copy2(root/'README.md',dmgroot/'安装与使用说明.md')
build=info['CFBundleVersion']
dmg=root/'outputs'/f'{name}-{version}-macOS通用版-b{build}.dmg'
if dmg.exists():raise RuntimeError('Preserving existing DMG; choose a new build number')
subprocess.run(['hdiutil','create','-volname',name,'-srcfolder',str(dmgroot),'-format','UDZO',str(dmg)],check=True,timeout=240)
subprocess.run(['hdiutil','verify',str(dmg)],check=True,timeout=90)
print('UNIVERSAL_DMG_OK',dmg)
