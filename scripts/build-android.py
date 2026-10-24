"""Build a real Java/DEX Android APK with verified local vendor tools."""
from pathlib import Path
import subprocess, zipfile, shutil

root=Path(__file__).resolve().parents[1]
java=next((root/'work/toolchains/jdk17').glob('*/Contents/Home/bin'))
sdk=root/'work/toolchains/android-sdk'; platform=next(sdk.glob('*/android.jar')); tools=next(p.parent for p in sdk.glob('*/aapt2'))
build=root/'work/android-build'; build.mkdir(exist_ok=True)
classes=build/'classes'; shutil.rmtree(classes,ignore_errors=True); classes.mkdir()
dex=build/'dex'; shutil.rmtree(dex,ignore_errors=True); dex.mkdir()
def run(args): subprocess.run([str(x) for x in args],check=True,timeout=180)
run([java/'javac','-encoding','UTF-8','--release','8','-classpath',platform,'-d',classes,*sorted((root/'platforms/android/src').rglob('*.java'))])
jar=build/'app.jar'
run([java/'jar','cf',jar,'-C',classes,'.'])
rules=build/'rules.pro'; rules.write_text('-keep public class com.pan.banana.MainActivity { public *; protected *; }\n-keep public class com.pan.banana.TransferService { public *; protected *; }\n-keep public class com.pan.banana.SelfTestRunner { public *; protected *; }\n-dontwarn java.lang.invoke.**\n')
run([java/'java','-cp',tools/'lib/d8.jar','com.android.tools.r8.R8','--release','--min-api','24','--lib',platform,'--pg-conf',rules,'--pg-map-output',build/'mapping.txt','--output',dex,jar])
resources=build/'resources.zip';run([tools/'aapt2','compile','--dir',root/'platforms/android/res','-o',resources])
assets=build/'assets';assets.mkdir(exist_ok=True)
shutil.copy2(root/'.cache/ugc-BV1QMTv6uE45.json',assets/'ugc-fixture.json');shutil.copy2(root/'work/test-merged.mp4',assets/'owned-fixture.mp4')
unsigned=build/'unsigned.apk'
run([tools/'aapt2','link','-o',unsigned,'-I',platform,'-A',assets,'--manifest',root/'platforms/android/AndroidManifest.xml','--version-code','162','--version-name','1.6.0',resources])
with zipfile.ZipFile(unsigned,'a',zipfile.ZIP_DEFLATED) as apk:
    for f in dex.glob('*.dex'): apk.write(f,f.name)
aligned=build/'aligned.apk'; run([tools/'zipalign','-f','4',unsigned,aligned])
signing=root/'work/signing';signing.mkdir(exist_ok=True)
signing.chmod(0o700)
key=signing/'android-development.p12'
if not key.exists(): run([java/'keytool','-genkeypair','-keystore',key,'-storepass','banana-development','-keypass','banana-development','-alias','banana','-keyalg','RSA','-keysize','3072','-validity','3650','-dname','CN=Pan Piaoliang Development,O=Banana,C=CN'])
key.chmod(0o600)
output=root/'outputs/霹雳下载-1.6.0-Android.apk'
run([java/'java','-jar',tools/'lib/apksigner.jar','sign','--ks',key,'--ks-key-alias','banana','--ks-pass','pass:banana-development','--out',output,aligned])
run([java/'java','-jar',tools/'lib/apksigner.jar','verify','--verbose',output])
run([tools/'aapt2','dump','badging',output])
print('ANDROID_APK_BUILT',output)
