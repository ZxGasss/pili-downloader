"""Cross-compile the managed Windows preview using Microsoft's reference assemblies."""
from pathlib import Path
import subprocess, os
root=Path(__file__).resolve().parents[1]
tool=root/'work/toolchains/dotnet8'
refs=root/'work/toolchains/net48-refs/build/.NETFramework/v4.8'
compiler=next(tool.glob('sdk/*/Roslyn/bincore/csc.dll'))
output=root/'outputs/霹雳下载-1.6.0-Windows';output.mkdir(exist_ok=True)
arguments=[str(tool/'dotnet'),str(compiler),'/nologo','/target:winexe','/optimize+','/debug-','/platform:anycpu','/nostdlib+',
 '/win32manifest:'+str(root/'platforms/windows/app.manifest'),'/win32icon:'+str(root/'work/AppIcon.ico'),'/out:'+str(output/'霹雳下载.exe')]
arguments+=['/reference:'+str(refs/name) for name in ['mscorlib.dll','System.dll','System.Core.dll','System.Drawing.dll','System.Windows.Forms.dll','System.Web.Extensions.dll','System.Management.dll']]
arguments+=[str(root/'platforms/windows/Banana.cs')]
env=dict(os.environ,DOTNET_CLI_TELEMETRY_OPTOUT='1',DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1',DOTNET_NOLOGO='1')
subprocess.run(arguments,env=env,check=True,timeout=120)
print('WINDOWS_EXE_COMPILED',output/'霹雳下载.exe')
