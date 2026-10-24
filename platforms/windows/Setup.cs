using System;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;
using System.Drawing;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Forms;
using System.Diagnostics;

[assembly:System.Reflection.AssemblyTitle("霹雳下载安装程序")]
[assembly:System.Reflection.AssemblyCompany("潘飘亮")]
[assembly:System.Reflection.AssemblyVersion("1.6.0.24")]
[assembly:System.Reflection.AssemblyFileVersion("1.6.0.24")]
[assembly:System.Runtime.Versioning.TargetFramework(".NETFramework,Version=v4.8",FrameworkDisplayName=".NET Framework 4.8")]

internal static class Setup {
    private static string Extract(string directory) {
        string temporary=directory+".preparing-"+Guid.NewGuid().ToString("N");Directory.CreateDirectory(temporary);
        using(Stream resource=Assembly.GetExecutingAssembly().GetManifestResourceStream("BananaPayload"))
        using(var archive=new ZipArchive(resource,ZipArchiveMode.Read)) {
            foreach(var entry in archive.Entries) {
                string target=Path.GetFullPath(Path.Combine(temporary,entry.FullName));
                if(!target.StartsWith(Path.GetFullPath(temporary)+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase))throw new IOException("安装包路径校验失败");
                if(entry.FullName.EndsWith("/")){Directory.CreateDirectory(target);continue;}
                Directory.CreateDirectory(Path.GetDirectoryName(target));using(var input=entry.Open())using(var output=File.Create(target)){input.CopyTo(output);}
            }
        }
        if(!File.Exists(Path.Combine(temporary,"霹雳下载.exe"))||!File.Exists(Path.Combine(temporary,"Tools","yt-dlp.exe")))throw new IOException("安装包内容不完整");
        // Keep existing installed versions and avoid overwriting a running application.
        if(Directory.Exists(directory)) directory+="-"+DateTime.UtcNow.Ticks;
        Directory.Move(temporary,directory);return Path.Combine(directory,"霹雳下载.exe");
    }
    [STAThread] public static void Main(string[] args) {
        if(args.Contains("--self-test")) {
            string test=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"BananaInstallerTests",Guid.NewGuid().ToString("N"));
            string exe=Extract(test);if(!File.Exists(Path.Combine(Path.GetDirectoryName(exe),"Tools","ffmpeg.exe")))Environment.Exit(2);
            Console.WriteLine("WINDOWS_INSTALLER_PASS");return;
        }
        Application.EnableVisualStyles();var form=new Form{Text="霹雳下载 · BY 潘飘亮",Width=540,Height=220,StartPosition=FormStartPosition.CenterScreen};
        var text=new Label{Dock=DockStyle.Fill,Text="正在准备霹雳下载…\n\n文件保存在当前用户的应用目录，不修改开机启动项。",Padding=new Padding(25),Font=new Font("Microsoft YaHei",11)};form.Controls.Add(text);
        form.Shown+=async(s,e)=>{
            try{string destination=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"PiliDownloader","1.6.0-b24");string exe=await Task.Run(()=>Extract(destination));Process.Start(new ProcessStartInfo(exe){UseShellExecute=false});form.Close();}
            catch(Exception failure){text.Text="准备未完成："+failure.Message+"\n请检查剩余空间，或使用随附的便携版。";}
        };
        Application.Run(form);
    }
}
