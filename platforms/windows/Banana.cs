using System;
using System.IO;
using System.Linq;
using System.Management;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

[assembly:System.Reflection.AssemblyTitle("霹雳下载")]
[assembly:System.Reflection.AssemblyProduct("霹雳下载")]
[assembly:System.Reflection.AssemblyCompany("潘飘亮")]
[assembly:System.Reflection.AssemblyVersion("1.6.0.24")]
[assembly:System.Reflection.AssemblyFileVersion("1.6.0.24")]
[assembly:System.Runtime.Versioning.TargetFramework(".NETFramework,Version=v4.8",FrameworkDisplayName=".NET Framework 4.8")]

internal sealed class Item {
    public string Id, Title, Cover, Url; public int Index;
    private string series;
    public string Series { get { return series; } set {
        string clean=Regex.Replace(value ?? "",@"[\\/:*?""<>|%\r\n]","_").Trim(' ','.');
        series=String.IsNullOrEmpty(clean)?"未命名合集":clean.Substring(0,Math.Min(60,clean.Length));
    } }
}
internal sealed class Window : Form {
    readonly TextBox links = new TextBox { Multiline=true, Height=70, ScrollBars=ScrollBars.Vertical };
    readonly TextBox log = new TextBox { Multiline=true, ReadOnly=true, ScrollBars=ScrollBars.Vertical, Height=210 };
    readonly NumericUpDown first = new NumericUpDown { Minimum=1, Maximum=10000, Value=1 }, last = new NumericUpDown { Minimum=1, Maximum=10000, Value=1 };
    readonly NumericUpDown groupSize = new NumericUpDown { Minimum=10, Maximum=20, Increment=10, Value=10 }, groups = new NumericUpDown { Minimum=1, Maximum=4, Value=2 };
    readonly ComboBox quality = new ComboBox { DropDownStyle=ComboBoxStyle.DropDownList };
    readonly Label current = new Label { AutoSize=true }, hardware = new Label { Dock=DockStyle.Fill, TextAlign=ContentAlignment.MiddleRight, AutoEllipsis=true };
    readonly PictureBox cover = new PictureBox { Width=190, Height=108, SizeMode=PictureBoxSizeMode.Zoom };
    readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength=16000000 };
    readonly List<Process> processes = new List<Process>(); readonly List<Item> catalogue = new List<Item>();
    readonly NotifyIcon tray = new NotifyIcon { Icon=SystemIcons.Information, Text="霹雳下载" };
    readonly string data = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"BananaPlayer");
    string folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),"Downloads"), player="";
    volatile bool paused, busy;
    PerformanceCounter cpu, read, write, available; string chip=HardwareName("Win32_Processor","Name",Environment.GetEnvironmentVariable("PROCESSOR_IDENTIFIER") ?? "系统未公开"),gpu=HardwareName("Win32_VideoController","Name","系统未公开");
    [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint flags);

    public Window() {
        Text="霹雳下载 1.6.0 · BY 潘飘亮";AutoScaleMode=AutoScaleMode.Dpi;Font=new Font("Microsoft YaHei UI",10);MinimumSize=new Size(900,680);Size=new Size(1080,780);BackColor=Color.FromArgb(18,20,26);ForeColor=Color.White;
        var footer=new Panel { Dock=DockStyle.Bottom,Height=66,Padding=new Padding(24,8,24,8),BackColor=Color.FromArgb(23,25,30) };
        footer.Controls.Add(hardware);footer.Controls.Add(new Label { Text="BY 潘飘亮",Dock=DockStyle.Left,Width=180,TextAlign=ContentAlignment.MiddleLeft,Font=new Font("Microsoft YaHei",10,FontStyle.Bold) });
        var root=new FlowLayoutPanel { Dock=DockStyle.Fill,FlowDirection=FlowDirection.TopDown,WrapContents=false,Padding=new Padding(30,24,30,24),AutoScroll=true,BackColor=Color.FromArgb(18,20,26) };Controls.Add(root);Controls.Add(footer);footer.BringToFront();
        Add(root,new Label { Text="⚡ 霹雳下载",Font=new Font("Microsoft YaHei UI",24,FontStyle.Bold),AutoSize=true,ForeColor=Color.FromArgb(242,246,255) });
        Add(root,new Label { Text="BY 潘飘亮  ·  视频 / 分P / 合集 / 番剧下载",AutoSize=true,ForeColor=Color.FromArgb(142,160,190) });
        Add(root,new Label { Text="粘贴链接",Font=new Font("Microsoft YaHei UI",11,FontStyle.Bold),AutoSize=true,ForeColor=Color.FromArgb(190,205,230) });
        Add(root,links); Add(root,Line(Button("解析链接",async()=>await Inspect()),Button("选择保存目录",()=>{using(var d=new FolderBrowserDialog()){d.SelectedPath=folder;if(d.ShowDialog()==DialogResult.OK)folder=d.SelectedPath;}return Task.CompletedTask;})));
        quality.Items.AddRange(new object[]{"最高可用画质","1080P及以下","720P及以下"});quality.SelectedIndex=0;
        Add(root,Line(new Label{Text="从第",AutoSize=true},first,new Label{Text="集到第",AutoSize=true},last,new Label{Text="集；每组集数",AutoSize=true},groupSize,new Label{Text="同时运行组数",AutoSize=true},groups,quality));
        Add(root,Line(cover,current));
        Add(root,Line(Button("开始／恢复下载",Download),Button("暂停并保留分片",()=>{Pause();return Task.CompletedTask;}),Button("在文件夹中查看",()=>{Process.Start(new ProcessStartInfo(folder){UseShellExecute=true});return Task.CompletedTask;})));
        Add(root,Line(Button("选择播放器",()=>{using(var d=new OpenFileDialog()){d.Filter="播放器程序|*.exe";if(d.ShowDialog()==DialogResult.OK)player=d.FileName;}return Task.CompletedTask;}),Button("打开最新视频",()=>{var f=Directory.Exists(folder)?Directory.GetFiles(folder,"*.*",SearchOption.AllDirectories).Where(x=>x.EndsWith(".mp4")||x.EndsWith(".mkv")).OrderByDescending(File.GetLastWriteTimeUtc).FirstOrDefault():null;if(f!=null){if(File.Exists(player))Process.Start(new ProcessStartInfo(player,Quote(f)){UseShellExecute=false});else Process.Start(new ProcessStartInfo(f){UseShellExecute=true});}return Task.CompletedTask;})));
        Add(root,new Label { Text="运行日志",Font=new Font("Microsoft YaHei UI",11,FontStyle.Bold),AutoSize=true,ForeColor=Color.FromArgb(190,205,230) });Add(root,log);
        links.BackColor=log.BackColor=Color.FromArgb(35,39,49);links.ForeColor=log.ForeColor=Color.FromArgb(235,240,250);links.BorderStyle=log.BorderStyle=BorderStyle.FixedSingle;links.Width=log.Width=960;links.Height=78;log.Height=190;cover.BackColor=Color.FromArgb(35,39,49);cover.BorderStyle=BorderStyle.FixedSingle;quality.FlatStyle=FlatStyle.Flat;quality.BackColor=Color.FromArgb(35,39,49);quality.ForeColor=Color.White;foreach(var n in new[]{first,last,groupSize,groups}){n.BackColor=Color.FromArgb(35,39,49);n.ForeColor=Color.White;}root.SizeChanged+=(s,e)=>{int w=Math.Max(500,root.ClientSize.Width-75);links.Width=log.Width=w;};
        Directory.CreateDirectory(data); var saved=Path.Combine(data,"settings.json");
        try {var s=Obj(json.DeserializeObject(File.ReadAllText(saved)));links.Text=Str(s,"links");folder=Str(s,"folder");first.Value=Number(s,"first",1);last.Value=Number(s,"last",1);player=Str(s,"player");}catch{}
        try{cpu=new PerformanceCounter("Processor","% Processor Time","_Total");read=new PerformanceCounter("PhysicalDisk","Disk Read Bytes/sec","_Total");write=new PerformanceCounter("PhysicalDisk","Disk Write Bytes/sec","_Total");available=new PerformanceCounter("Memory","Available MBytes");cpu.NextValue();}catch{}
        var timer=new System.Windows.Forms.Timer { Interval=2000 };timer.Tick+=(s,e)=>{try{hardware.Text="CPU型号 "+chip+"  ·  GPU型号 "+gpu+"  ·  版本 1.6.0\nCPU "+cpu.NextValue().ToString("F0")+"%  ·  可用内存 "+available.NextValue().ToString("F0")+" MB  ·  磁盘 读 "+(read.NextValue()/1e6).ToString("F1")+" / 写 "+(write.NextValue()/1e6).ToString("F1")+" MB/s";}catch{hardware.Text="CPU型号 "+chip+"  ·  GPU型号 "+gpu+"  ·  性能计数器暂不可用";}};timer.Start();
        tray.DoubleClick+=(s,e)=>{Show();WindowState=FormWindowState.Normal;};tray.ContextMenuStrip=new ContextMenuStrip();tray.ContextMenuStrip.Items.Add("显示主窗口",null,(s,e)=>Show());tray.ContextMenuStrip.Items.Add("退出并保存分片",null,(s,e)=>{Pause();tray.Visible=false;Application.Exit();});tray.Visible=true;
        FormClosing+=(s,e)=>{Save();if(busy&&e.CloseReason==CloseReason.UserClosing){e.Cancel=true;Hide();tray.ShowBalloonTip(1500,"下载仍在后台进行","双击托盘图标返回应用",ToolTipIcon.Info);}};
    }
    static string HardwareName(string table,string property,string fallback){try{using(var q=new ManagementObjectSearcher("SELECT "+property+" FROM "+table))foreach(ManagementObject row in q.Get()){var value=Convert.ToString(row[property]).Trim();if(value.Length>0)return value;}}catch{}return fallback;}
    static void Add(FlowLayoutPanel root,Control c){c.Margin=new Padding(0,7,0,7);root.Controls.Add(c);}
    static Control Line(params Control[] cs){var p=new FlowLayoutPanel{AutoSize=true,WrapContents=true};p.Controls.AddRange(cs);return p;}
    Button Button(string text,Func<Task> action){var b=new Button{Text=text,AutoSize=true,Padding=new Padding(12,6,12,6),BackColor=Color.FromArgb(45,111,225),ForeColor=Color.White,FlatStyle=FlatStyle.Flat,Cursor=Cursors.Hand};b.FlatAppearance.BorderSize=0;b.Click+=async(s,e)=>{try{await action();}catch(Exception ex){Append("未完成，分片保留："+ex.Message);}};return b;}
    static Dictionary<string,object> Obj(object x){return (Dictionary<string,object>)x;}
    static string Str(Dictionary<string,object> o,string key){object v;return o.TryGetValue(key,out v)&&v!=null?v.ToString():"";}
    static int Number(Dictionary<string,object> o,string k,int fallback){int n;return int.TryParse(Str(o,k),out n)?n:fallback;}
    static string Quote(string value){if(value.Contains('"')||value.Contains('\r')||value.Contains('\n'))throw new Exception("参数包含无效字符");return "\""+Regex.Replace(value,@"(\\+)$","$1$1")+"\"";}
    void UI(Action action){if(!IsDisposed&&IsHandleCreated)BeginInvoke(action);}
    void Append(string text){text=Regex.Replace(text,@"https?://[^\s]+","[链接隐藏]");UI(()=>{log.AppendText(text+Environment.NewLine);if(log.TextLength>160000)log.Text=log.Text.Substring(log.TextLength-100000);});}
    void Save(){File.WriteAllText(Path.Combine(data,"settings.json"),json.Serialize(new{links=links.Text,folder,first=(int)first.Value,last=(int)last.Value,player}));}
    static string Normalize(string value){var s=value.Trim();if(Regex.IsMatch(s,@"(?i)^bv[0-9a-z]{10}$"))s="https://www.bilibili.com/video/BV"+s.Substring(2);if(Regex.IsMatch(s,@"(?i)^av[1-9][0-9]*$"))s="https://www.bilibili.com/video/av"+s.Substring(2);if(Regex.IsMatch(s,@"(?i)^(www\.)?bilibili\.com/"))s="https://"+s;var u=new Uri(s);if(u.Scheme!="https"||u.UserInfo!=""||!(u.Host=="www.bilibili.com"||u.Host=="bilibili.com"))throw new Exception("请输入哔哩哔哩链接或 AV/BV 编号");var p=Regex.Match(u.Query,@"(?:^|[?&])p=([1-9][0-9]*)");return "https://www.bilibili.com"+u.AbsolutePath+(p.Success?"?p="+p.Groups[1].Value:"");}
    async Task<Dictionary<string,object>> Api(string url){using(var client=new WebClient()){client.Headers["User-Agent"]="Mozilla/5.0";client.Headers["Referer"]="https://www.bilibili.com/";var result=Obj(json.DeserializeObject(await client.DownloadStringTaskAsync(url)));if(Number(result,"code",-1)!=0)throw new Exception("网站未提供内容或账号权限不足（"+Str(result,"code")+"）");return Obj(result.ContainsKey("data")?result["data"]:result["result"]);}}
    async Task<List<Item>> List(string input){var u=new Uri(Normalize(input));string id=u.Segments.Last().Trim('/');var result=new List<Item>();
        if(u.AbsolutePath.StartsWith("/bangumi/play/")){if(!(id.StartsWith("ss")||id.StartsWith("ep"))||!Regex.IsMatch(id.Substring(2),@"^[1-9][0-9]*$"))throw new Exception("番剧地址无效");var season=await Api("https://api.bilibili.com/pgc/view/web/season?"+(id.StartsWith("ss")?"season_id=":"ep_id=")+id.Substring(2));foreach(var raw in (object[])season["episodes"]){var row=Obj(raw);string label=Str(row,"title");int index; if(!Int32.TryParse(label,out index))index=result.Count+1;result.Add(new Item{Id="ep"+Str(row,"id"),Index=index,Title="第"+label+"话 "+Str(row,"long_title"),Series=Str(season,"title"),Cover=Str(row,"cover"),Url="https://www.bilibili.com/bangumi/play/ep"+Str(row,"id")});}return result.OrderBy(x=>x.Index).ToList();}
        if(!u.AbsolutePath.StartsWith("/video/"))throw new Exception("当前支持投稿、分P、合集与番剧正片");var d=await Api("https://api.bilibili.com/x/web-interface/view?"+(id.StartsWith("av")?"aid="+id.Substring(2):"bvid="+id));
        if(d.ContainsKey("ugc_season")){var season=Obj(d["ugc_season"]);foreach(var section in (object[])season["sections"])foreach(var row in (object[])Obj(section)["episodes"]){var r=Obj(row);string bv=Str(r,"bvid");if(result.Any(x=>x.Id==bv))continue;var arc=r.ContainsKey("arc")?Obj(r["arc"]):new Dictionary<string,object>();result.Add(new Item{Id=bv,Title=Str(r,"title"),Series=Str(season,"title"),Cover=Str(arc,"pic"),Index=result.Count+1,Url="https://www.bilibili.com/video/"+bv});}}
        else{foreach(var raw in (object[])d["pages"]){var p=Obj(raw);int n=Number(p,"page",result.Count+1);string bv=Str(d,"bvid");result.Add(new Item{Id=bv+"-p"+n,Index=n,Title=((object[])d["pages"]).Length>1?Str(p,"part"):Str(d,"title"),Series=Str(d,"title"),Cover=Str(d,"pic"),Url="https://www.bilibili.com/video/"+bv+"?p="+n});}}return result;}
    async Task Inspect(){if(busy)return;catalogue.Clear();catalogue.AddRange(await List(links.Lines.FirstOrDefault(x=>!String.IsNullOrWhiteSpace(x))??""));last.Value=catalogue.Count;Append("官方列表 "+catalogue.Count+" 集，按网页顺序编号，可选择起止集数。");foreach(var i in catalogue)Append(i.Index+". "+i.Title);}
    void Pause(){paused=true;lock(processes)foreach(var p in processes.ToArray())try{if(!p.HasExited)p.Kill();}catch{}Save();}
    async Task Download(){if(busy)return;Save();Directory.CreateDirectory(folder);paused=false;busy=true;string[] inputs=links.Lines.Where(x=>!String.IsNullOrWhiteSpace(x)).ToArray();int begin=(int)first.Value,end=(int)last.Value,size=(int)groupSize.Value,count=(int)groups.Value,height=new[]{4320,1080,720}[quality.SelectedIndex];
        try{var queue=new List<List<Item>>();foreach(string input in inputs){var all=await List(input);if(begin<1||end<begin||end>all.Count)throw new Exception("选集范围超出列表");var selected=all.Where(x=>x.Index>=begin&&x.Index<=end).ToList();for(int start=0;start<selected.Count;start+=size)queue.Add(selected.Skip(start).Take(size).ToList());}
            var limit=new SemaphoreSlim(count);var tasks=queue.Select(async batch=>{await limit.WaitAsync();try{foreach(var item in batch){if(paused)break;await Task.Run(()=>Transfer(item,height));}}finally{limit.Release();}}).ToArray();await Task.WhenAll(tasks);Append(paused?"已暂停，重开软件可继续":"所选内容下载完成");
        }finally{busy=false;Save();}}
    void Transfer(Item item,int height){if(paused)return;UI(()=>{current.Text="当前第"+item.Index+"集\n"+item.Title;try{cover.LoadAsync(item.Cover.Replace("http:","https:"));}catch{}});string tools=Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"Tools");string executable=Path.Combine(tools,"yt-dlp.exe");if(!File.Exists(executable))throw new Exception("安装包缺少下载组件，请重新解压完整安装包");string series=Regex.Replace(item.Series,@"[\\/:*?""<>|]","_");
        string[] args={"--ignore-config","--no-plugin-dirs","--no-geo-bypass","--no-playlist","--continue","--no-overwrites","--newline","--socket-timeout","20","--retries","3","--ffmpeg-location",tools,"--merge-output-format","mkv","--print","after_move:PLFILE:%(filepath)s","--progress-template","download:PLPROGRESS|%(progress._percent_str)s|%(progress.speed)s|%(progress.eta)s|%(progress.downloaded_bytes)s|%(progress.total_bytes_estimate)s","-f","bestvideo[height<="+height+"]+bestaudio/best[height<="+height+"]","-P",folder,"-o",series+"/"+item.Index.ToString("000")+" - %(title).120B.%(ext)s","--",item.Url};
        for(int attempt=0;attempt<4&&!paused;attempt++){string error="";string final="";var info=new ProcessStartInfo(executable,String.Join(" ",args.Select(Quote))){UseShellExecute=false,CreateNoWindow=true,RedirectStandardError=true,RedirectStandardOutput=true,StandardOutputEncoding=Encoding.UTF8,StandardErrorEncoding=Encoding.UTF8};
            using(var p=new Process{StartInfo=info}){p.ErrorDataReceived+=(s,e)=>{if(e.Data!=null){error=e.Data;Append(e.Data);}};p.Start();lock(processes)processes.Add(p);p.BeginErrorReadLine();SetThreadExecutionState(0x80000001);try{string row;while((row=p.StandardOutput.ReadLine())!=null){if(row.StartsWith("PLFILE:"))final=row.Substring(7);else Append("第"+item.Index+"集 · "+row);}p.WaitForExit();if(paused)return;if(p.ExitCode==0&&File.Exists(final)){File.AppendAllText(Path.Combine(folder,"下载日志.txt"),DateTime.Now.ToString("s")+" | 第"+item.Index+"集 | "+item.Title+" | "+item.Url+" | "+item.Id+" | "+Path.GetFileName(final)+Environment.NewLine);return;}
                if(attempt<3&&Regex.IsMatch(error,"(?i)timed out|timeout|connection reset|429")){Append("网络暂时中断，将续传（"+(attempt+1)+"/3）");for(int wait=0;wait<(2<<attempt)&&!paused;wait++)Thread.Sleep(1000);continue;}throw new Exception("第"+item.Index+"集未完成，分片已保留。"+Regex.Replace(error,@"https?://[^\s]+","[链接隐藏]"));
            }finally{SetThreadExecutionState(0x80000000);lock(processes)processes.Remove(p);}}}
    }
    [STAThread] public static void Main(string[] args){ServicePointManager.SecurityProtocol=SecurityProtocolType.Tls12;if(args.Contains("--self-test")){if(Normalize("BV1QMTv6uE45")!="https://www.bilibili.com/video/BV1QMTv6uE45"||Normalize("bilibili.com/video/BV1QMTv6uE45/?trackid=test&p=2")!="https://www.bilibili.com/video/BV1QMTv6uE45/?p=2")Environment.Exit(2);Console.WriteLine("WINDOWS_CORE_PASS");return;}Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);Application.Run(new Window());}
}
