from pathlib import Path
import subprocess, zipfile, os, shutil
root=Path(__file__).resolve().parents[1];release=root/'outputs/霹雳下载-1.6.0-Windows'
zip_path=root/'outputs/霹雳下载-1.6.0-Windows-便携版.zip'
with zipfile.ZipFile(zip_path,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as archive:
    for p in release.rglob('*'):
        if p.is_file() and p.name!='霹雳下载-保护版.exe':archive.write(p,p.relative_to(release))
tool=root/'work/toolchains/dotnet8';compiler=next(tool.glob('sdk/*/Roslyn/bincore/csc.dll'));refs=root/'work/toolchains/net48-refs/build/.NETFramework/v4.8'
output=root/'outputs/霹雳下载-1.6.0-Windows-安装程序.exe'
args=[str(tool/'dotnet'),str(compiler),'/nologo','/target:winexe','/optimize+','/debug-','/platform:anycpu','/nostdlib+',
 '/win32manifest:'+str(root/'platforms/windows/app.manifest'),'/win32icon:'+str(root/'work/AppIcon.ico'),'/out:'+str(output),'/resource:'+str(zip_path)+',BananaPayload']
args+=['/reference:'+str(refs/name) for name in ['mscorlib.dll','System.dll','System.Core.dll','System.Drawing.dll','System.Windows.Forms.dll','System.IO.Compression.dll']]
args+=[str(root/'platforms/windows/Setup.cs')]
env=dict(os.environ,DOTNET_CLI_TELEMETRY_OPTOUT='1',DOTNET_NOLOGO='1',DOTNET_CLI_HOME=str(root/'work/dotnet-cli'))
subprocess.run(args,env=env,check=True,timeout=120)
print('WINDOWS_PORTABLE_AND_INSTALLER_BUILT',zip_path.stat().st_size,output.stat().st_size)
