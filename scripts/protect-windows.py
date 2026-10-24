from pathlib import Path
import subprocess, os, shutil
import xml.etree.ElementTree as ET
root=Path(__file__).resolve().parents[1]
release=root/'outputs/霹雳下载-1.6.0-Windows'
source=root/'work/windows-unprotected';source.mkdir(exist_ok=True)
shutil.copy2(release/'霹雳下载.exe',source/'霹雳下载.exe')
protected=root/'work/windows-protected';protected.mkdir(exist_ok=True)
config=ET.Element('Obfuscator')
for name,value in [('InPath',str(source)),('OutPath',str(protected)),('KeepPublicApi','true'),('HidePrivateApi','true'),('HideStrings','true'),('SkipGeneratedTypes','true')]: ET.SubElement(config,'Var',name=name,value=value)
ET.SubElement(config,'AssemblySearchPath',path=str(root/'work/toolchains/net48-refs/build/.NETFramework/v4.8'))
ET.SubElement(config,'Module',file=str(source/'霹雳下载.exe'))
path=root/'work/windows-obfuscation.xml';ET.ElementTree(config).write(path,encoding='utf-8',xml_declaration=True)
env=dict(os.environ,DOTNET_ROOT=str(root/'work/toolchains/dotnet8'),DOTNET_CLI_TELEMETRY_OPTOUT='1')
subprocess.run([str(root/'work/toolchains/obfuscar/obfuscar.console'),str(path)],env=env,check=True,timeout=120)
# A separate protected filename remains reviewable until runtime validation passes.
shutil.copy2(protected/'霹雳下载.exe',release/'霹雳下载-保护版.exe')
print('WINDOWS_OBFUSCATED',release/'霹雳下载-保护版.exe')
