"""Resign the verified binaries with final version/docs and package the final universal DMG."""
from pathlib import Path
import plistlib,subprocess,shutil
root=Path(__file__).resolve().parents[1]
info=plistlib.loads((root/'Info.plist').read_bytes());build=info['CFBundleVersion']
apps=[root/'outputs/大香蕉播放器-1.5.1/大香蕉播放器.app',root/'outputs/大香蕉播放器-1.5.1-macOS通用版/大香蕉播放器.app']
for app in apps:
    shutil.copy2(root/'Info.plist',app/'Contents/Info.plist');shutil.copy2(root/'README.md',app/'Contents/Resources/使用说明.md')
    docs=app/'Contents/Resources/文档';docs.mkdir(exist_ok=True)
    for name in ['1.5.1交付与验收说明.md','大香蕉播放器-300条优化与验收方案.md','全平台适配与处理器覆盖矩阵.md','处理器覆盖与实测边界.md']:
        shutil.copy2(root/'outputs'/name,docs/name)
    subprocess.run(['codesign','--force','--sign','-',str(app)],check=True,timeout=30)
    subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True,timeout=30)
stage=root/('work/dmg-final-b'+build);stage.mkdir(exist_ok=True)
subprocess.run(['ditto',str(apps[1]),str(stage/'大香蕉播放器.app')],check=True,timeout=60)
if not (stage/'Applications').exists():(stage/'Applications').symlink_to('/Applications')
shutil.copy2(root/'README.md',stage/'安装与使用说明.md')
shutil.copy2(root/'outputs/1.5.1交付与验收说明.md',stage/'本版验收说明.md')
target=root/('outputs/大香蕉播放器-1.5.1-macOS通用版-b'+build+'.dmg')
if target.exists():raise RuntimeError('Existing final DMG preserved')
subprocess.run(['hdiutil','create','-volname','大香蕉播放器','-srcfolder',str(stage),'-format','UDZO',str(target)],check=True,timeout=240)
subprocess.run(['hdiutil','verify',str(target)],check=True,timeout=90)
print('MACOS_FINAL_SIGN_AND_DMG_PASS',target)
