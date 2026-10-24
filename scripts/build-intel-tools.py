"""Compile the same minimal desktop transfer/mux tools for Intel macOS 13+."""
from pathlib import Path
import subprocess,tarfile,os
root=Path(__file__).resolve().parents[1];base=root/'work/intel';base.mkdir(exist_ok=True)
for filename in ['ffmpeg-8.0.tar.xz','aria2-1.37.0.tar.xz']:
    with tarfile.open(root/'.cache'/filename) as archive:
        if any(Path(x.name).is_absolute() or '..' in Path(x.name).parts for x in archive.getmembers()):raise RuntimeError('Unsafe archive')
        source=base/filename.replace('.tar.xz','')
        if not source.exists():archive.extractall(base)
def run(args,cwd,env=None,limit=900):
    subprocess.run(args,cwd=cwd,env=env,check=True,timeout=limit)
ff=base/'ffmpeg-8.0';flags='-arch x86_64 -mmacosx-version-min=13.0'
if not (ff/'ffmpeg').exists():
    run(['./configure','--arch=x86_64','--target-os=darwin','--enable-cross-compile','--cc=clang','--extra-cflags='+flags,'--extra-ldflags='+flags,'--disable-everything','--disable-autodetect','--disable-doc','--disable-debug','--disable-network','--disable-ffplay','--disable-ffprobe','--disable-x86asm','--enable-protocol=file','--enable-demuxer=mov,matroska,aac,mp3,flv,mpegts','--enable-muxer=mp4,matroska','--enable-bsf=aac_adtstoasc','--enable-parser=aac,h264,hevc,av1'],ff)
    run(['make','-j4'],ff)
print('INTEL_FFMPEG_BUILT',flush=True)
aria=base/'aria2-1.37.0'
if not (aria/'src/aria2c').exists():
    env=dict(os.environ,CC='clang '+flags,CXX='clang++ '+flags,CFLAGS='-O2',CXXFLAGS='-O2')
    run(['./configure','--host=x86_64-apple-darwin','--build=aarch64-apple-darwin','--with-appletls','--without-openssl','--without-gnutls','--without-libssh2','--without-libcares','--without-sqlite3','--without-libxml2','--without-libexpat','--disable-bittorrent','--disable-metalink','--disable-websocket','--disable-nls','--disable-dependency-tracking'],aria,env)
    run(['make','-j4'],aria,env)
print('INTEL_ARIA2_BUILT',flush=True)
