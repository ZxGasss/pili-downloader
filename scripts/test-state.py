"""Run the app model against owned fixtures, in a dedicated preview bundle and data directory."""
from pathlib import Path
import plistlib, shutil, subprocess, time

root = Path(__file__).resolve().parents[1]
project = root / 'work'
base = project / ('2.0-state-' + str(time.time_ns()))
app = base / '模型测试.app'
mac = app / 'Contents/MacOS'
tools = app / 'Contents/Resources/Tools'
mac.mkdir(parents=True); tools.mkdir(parents=True)
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'local.pili.downloader.preview151.state.' + str(time.time_ns()),
    'CFBundleExecutable': 'StateTests', 'CFBundlePackageType': 'APPL',
    'PiliExperimentRoot': str(base / '独立数据')}))
for source, name in [('Tests/fake-downloader.py', 'yt-dlp'), ('work/deps/ffmpeg', 'ffmpeg'), ('work/test-merged.mp4', 'fixture.mp4')]:
    shutil.copy2(root / source, tools / name)
(tools / 'yt-dlp').chmod(0o700)
sources = [str(p) for p in (root / 'Sources').glob('*.swift') if p.name not in ['Main.swift', 'WorkspaceShell.swift']]
with (root / 'work/state-tests-2.0.log').open('w') as log:
    subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', '-target', 'arm64-apple-macos13.0', *sources,
                    str(root / 'Tests/AppState.swift'), '-o', str(mac / 'StateTests')], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=20)
    subprocess.run([str(mac / 'StateTests')], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
print('STATE_TESTS_PASS', base)
