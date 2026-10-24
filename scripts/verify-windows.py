from pathlib import Path
import subprocess,os,shutil
root=Path(__file__).resolve().parents[1]
base=Path(os.environ.get('PILI_WINDOWS_WORK',root/'work/windows-verify'))
env=dict(os.environ,CX_BOTTLE_PATH=str(base/'bottles'),WINEDEBUG='-all')
wine='/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine'
release=root/'outputs/霹雳下载-1.6.0-Windows'
for script in ['build-windows.py','protect-windows.py']:
    subprocess.run(['python3',str(root/'scripts'/script)],check=True,timeout=150)
result=subprocess.run([wine,'--bottle','Banana151',str(release/'霹雳下载-保护版.exe'),'--self-test'],env=env,capture_output=True,text=True,timeout=75)
if result.returncode or 'WINDOWS_CORE_PASS' not in result.stdout:raise RuntimeError('Protected runtime verification failed: code=%s stdout=%r stderr=%r'%(result.returncode,result.stdout[-500:],result.stderr[-500:]))
print('PROTECTED_WINDOWS_CORE_PASS',flush=True)
shutil.copy2(release/'霹雳下载-保护版.exe',release/'霹雳下载.exe')
subprocess.run(['python3',str(root/'scripts/package-windows.py')],check=True,timeout=180)
result=subprocess.run([wine,'--bottle','Banana151',str(root/'outputs/霹雳下载-1.6.0-Windows-安装程序.exe'),'--self-test'],env=env,capture_output=True,text=True,timeout=100)
if result.returncode or 'WINDOWS_INSTALLER_PASS' not in result.stdout:raise RuntimeError('Installer extraction verification failed: code=%s stdout=%r stderr=%r'%(result.returncode,result.stdout[-500:],result.stderr[-500:]))
print('WINDOWS_INSTALLER_PASS',flush=True)
