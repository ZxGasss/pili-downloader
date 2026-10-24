"""Fetch verified vendor toolchains into the project; never alter global developer paths."""
from pathlib import Path
import concurrent.futures, hashlib, json, subprocess, tarfile, zipfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
cache = root / '.cache/toolchains'; cache.mkdir(parents=True, exist_ok=True)
destination = root / 'work/toolchains'; destination.mkdir(parents=True, exist_ok=True)
jdk = json.loads((root / '.cache/temurin17-mac.json').read_text())[0]['binary']['package']
sdk = json.loads((root / '.cache/dotnet8-releases.json').read_text())['releases'][0]['sdk']
net = next(x for x in sdk['files'] if x['rid'] == 'osx-arm64' and x['url'].endswith('.tar.gz'))
artifacts = [('jdk17.tar.gz', jdk['link'], 'sha256', jdk['checksum'], 'jdk17'),
             ('dotnet8.tar.gz', net['url'], 'sha512', net['hash'], 'dotnet8')]
repo = ET.parse(root / '.cache/android-repository.xml').getroot()
selected_packages = set()
for package in repo.findall('remotePackage'):
    path = package.attrib.get('path')
    if path not in ['platforms;android-35', 'build-tools;35.0.0'] or path in selected_packages: continue
    selected_packages.add(path)
    archives = [a for a in package.findall('./archives/archive') if a.findtext('host-os') in [None, 'macosx']]
    archive = next((a for a in archives if a.findtext('complete/url') == 'platform-35_r02.zip'), archives[-1])
    entry = archive.find('complete'); checksum = entry.find('checksum')
    artifacts.append((entry.findtext('url'), 'https://dl.google.com/android/repository/' + entry.findtext('url'),
                      checksum.attrib.get('type', 'sha1'), checksum.text.strip(), 'android-sdk'))

def fetch(record):
    name, url, algorithm, digest, directory = record
    archive = cache / name
    if not archive.exists():
        subprocess.run(['curl', '-fL', '--retry', '1', '--max-time', '600', '--silent', '--show-error', url, '-o', str(archive)], check=True, timeout=630)
    actual = hashlib.new(algorithm)
    with archive.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''): actual.update(chunk)
    if actual.hexdigest().lower() != digest.lower(): raise RuntimeError('Checksum failed: ' + name)
    target = destination / directory; target.mkdir(exist_ok=True)
    stamp = target / (name + '.verified')
    if not stamp.exists():
        if name.endswith('.zip'):
            with zipfile.ZipFile(archive) as zipped:
                if any(Path(x).is_absolute() or '..' in Path(x).parts for x in zipped.namelist()): raise RuntimeError('Unsafe path')
                zipped.extractall(target)
                for info in zipped.infolist():
                    mode = info.external_attr >> 16
                    if mode & 0o111: (target / info.filename).chmod(mode & 0o777)
        else:
            with tarfile.open(archive) as tar:
                for member in tar.getmembers():
                    if Path(member.name).is_absolute() or '..' in Path(member.name).parts: raise RuntimeError('Unsafe path')
                for member in tar.getmembers():
                    if member.issym() and (Path(member.linkname).is_absolute() or '..' in Path(member.linkname).parts):
                        # Vendor JDKs contain relative in-tree links; reject any escape.
                        resolved = (target / member.name).parent.joinpath(member.linkname).resolve()
                        if target.resolve() not in resolved.parents: raise RuntimeError('Unsafe link')
                tar.extractall(target)
        stamp.write_text(actual.hexdigest())
    return {'archive': name, 'url': url, 'digest': actual.hexdigest(), 'path': str(target)}

results = []
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    for future in concurrent.futures.as_completed([pool.submit(fetch, entry) for entry in artifacts]):
        try:
            result = future.result(); results.append(result); print('VERIFIED', result['archive'], flush=True)
        except Exception as error: results.append({'error': str(error)}); print('FAILED', str(error), flush=True)
(root / 'work/toolchain-manifest.json').write_text(json.dumps(results, indent=2))
