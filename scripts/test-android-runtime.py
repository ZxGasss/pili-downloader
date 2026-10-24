"""Boot a private ARM64 AVD and run non-UI instrumentation on owned fixtures."""
from pathlib import Path
import os, subprocess, time, json
root=Path(__file__).resolve().parents[1]
sdk=root/'work/toolchains/android-sdk'
base=Path(os.environ.get('PILI_ANDROID_WORK',root/'work/android-test'))
avd=base/'avd/Banana35.avd';avd.mkdir(parents=True,exist_ok=True)
(base/'avd/Banana35.ini').write_text('avd.ini.encoding=UTF-8\npath='+str(avd)+'\ntarget=android-35\n')
image=sdk/'system-images/android-35/google_apis/arm64-v8a'
config={'AvdId':'Banana35','avd.ini.displayname':'Banana private tests','abi.type':'arm64-v8a','hw.cpu.arch':'arm64','hw.cpu.ncore':'2','hw.ramSize':'2048','hw.lcd.width':'720','hw.lcd.height':'1280','hw.lcd.density':'320','hw.gpu.enabled':'yes','hw.gpu.mode':'auto','disk.dataPartition.size':'2G','image.sysdir.1':str(image)+'/', 'tag.id':'google_apis','tag.display':'Google APIs','PlayStore.enabled':'false','showDeviceFrame':'no','fastboot.forceColdBoot':'yes'}
(avd/'config.ini').write_text(''.join(k+'='+v+'\n' for k,v in config.items()))
env=dict(os.environ,ANDROID_SDK_ROOT=str(sdk),ANDROID_HOME=str(sdk),ANDROID_AVD_HOME=str(base/'avd'),ANDROID_ADB_SERVER_PORT='5043',ADB_SERVER_SOCKET='tcp:localhost:5043')
adb=sdk/'platform-tools/adb'
def run(args,timeout=30):return subprocess.run([str(adb),'-P','5043',*args],env=env,capture_output=True,text=True,timeout=timeout)
run(['start-server'])
log=(root/'work/android-emulator.log').open('w')
process=subprocess.Popen([str(sdk/'emulator/emulator'),'-avd','Banana35','-port','5560','-no-window','-no-audio','-no-boot-anim','-no-snapshot','-memory','2048','-cores','2'],env=env,stdout=log,stderr=subprocess.STDOUT)
(base/'emulator-pid.json').write_text(json.dumps({'pid':process.pid,'avd':str(avd)}))
try:
    deadline=time.monotonic()+180
    while time.monotonic()<deadline:
        if process.poll() is not None:raise RuntimeError('Emulator exited '+str(process.returncode))
        check=run(['-s','emulator-5560','shell','getprop','sys.boot_completed'],timeout=10)
        if check.stdout.strip()=='1':break
        time.sleep(2)
    else:raise TimeoutError('Android boot deadline')
    print('ANDROID_BOOTED',flush=True)
    result=run(['-s','emulator-5560','install','-r',str(root/'outputs/霹雳下载-1.6.0-Android.apk')],timeout=90)
    print('APK_INSTALL',result.returncode,result.stdout.strip(),result.stderr.strip(),flush=True)
    if result.returncode:raise RuntimeError('APK installation failed')
    test=run(['-s','emulator-5560','shell','am','instrument','-w','com.pan.banana/.SelfTestRunner'],timeout=90)
    print(test.stdout,flush=True)
    if 'ANDROID_RUNTIME_PASS' not in test.stdout:raise RuntimeError('Instrumentation did not pass')
finally:
    try:run(['-s','emulator-5560','emu','kill'],timeout=10)
    except Exception:pass
    try:process.wait(timeout=15)
    except subprocess.TimeoutExpired:process.terminate()
    run(['kill-server']);log.close()
