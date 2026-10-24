package com.pan.banana;

import android.app.*;
import android.os.*;
import android.content.*;
import android.view.*;
import android.widget.*;
import android.webkit.*;
import java.io.*;
import java.util.*;

public final class MainActivity extends Activity {
    private EditText address,from,to; private Spinner groupSize,groupCount,quality;
    private TextView state,hardware; private ArrayList<Bili.Item> items=new ArrayList<>();
    private final Handler handler=new Handler(Looper.getMainLooper());
    private long lastCPU=0,lastWall=0; private String gpuModel="检测中";
    private final Runnable refresh=new Runnable(){public void run(){
        state.setText(TransferService.running?TransferService.status:getSharedPreferences("banana",0).getString("status","准备就绪"));
        long now=SystemClock.elapsedRealtime(),cpu=android.os.Process.getElapsedCpuTime();int cores=Runtime.getRuntime().availableProcessors();
        String usage=lastWall>0?String.format(Locale.ROOT,"%.1f%%",100.0*(cpu-lastCPU)/Math.max(1,now-lastWall)/Math.max(1,cores)):"采样中";lastCPU=cpu;lastWall=now;
        android.app.ActivityManager.MemoryInfo memory=new android.app.ActivityManager.MemoryInfo();((android.app.ActivityManager)getSystemService(ACTIVITY_SERVICE)).getMemoryInfo(memory);
        java.io.File storage=getExternalFilesDir(Environment.DIRECTORY_MOVIES);if(storage==null)storage=getFilesDir();StatFs disk=new StatFs(storage.getPath());
        String chip=Build.VERSION.SDK_INT>=31?Build.SOC_MODEL:Build.HARDWARE;
        hardware.setText("CPU型号 "+chip+" · GPU型号 "+gpuModel+"\nCPU "+usage+" · 内存 "+((memory.totalMem-memory.availMem)/1048576)+"/"+(memory.totalMem/1048576)+"MB · 存储 "+(disk.getAvailableBytes()/1073741824)+"/"+(disk.getTotalBytes()/1073741824)+"GB");
        handler.postDelayed(this,2000);
    }};
    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved); LinearLayout screen=new LinearLayout(this);screen.setOrientation(LinearLayout.VERTICAL);
        LinearLayout root=new LinearLayout(this);root.setOrientation(1);root.setPadding(24,24,24,20);
        ScrollView scroll=new ScrollView(this);scroll.addView(root);screen.addView(scroll,new LinearLayout.LayoutParams(-1,0,1));
        LinearLayout footer=new LinearLayout(this);footer.setGravity(android.view.Gravity.CENTER_VERTICAL);footer.setPadding(24,10,24,10);
        TextView signature=new TextView(this);signature.setText("BY 潘飘亮");signature.setTextSize(13);signature.setTypeface(null,android.graphics.Typeface.BOLD);footer.addView(signature,new LinearLayout.LayoutParams(0,-2,1));
        hardware=new TextView(this);hardware.setTextSize(11);hardware.setGravity(android.view.Gravity.END);footer.addView(hardware,new LinearLayout.LayoutParams(0,-2,3));screen.addView(footer,new LinearLayout.LayoutParams(-1,-2));setContentView(screen);gpuModel=detectGPU();
        TextView brand=new TextView(this);brand.setText("霹雳下载\nBY 潘飘亮");brand.setTextSize(26);root.addView(brand);
        TextView note=new TextView(this);note.setText("支持投稿视频、分P、合集与番剧正片；H.264/AAC原画质封装。账号权限及加密限制适用。");root.addView(note);
        button(root,"登录账号（仅在本应用保存）",v->login());
        address=field(root,"粘贴视频网址或 AV/BV 编号",getSharedPreferences("banana",0).getString("address",""));
        button(root,"解析视频／合集",v->inspect());
        from=field(root,"开始集数",String.valueOf(getSharedPreferences("banana",0).getInt("from",1)));from.setInputType(2);
        to=field(root,"结束集数",String.valueOf(getSharedPreferences("banana",0).getInt("to",1)));to.setInputType(2);
        quality=choice(root,"最高可用（H.264）","1080P及以下","720P及以下");
        groupSize=choice(root,"每组10集","每组20集");groupCount=choice(root,"同时1组","同时2组","同时3组","同时4组");groupCount.setSelection(1);
        TextView path=new TextView(this);path.setText("工作目录："+getExternalFilesDir(Environment.DIRECTORY_MOVIES)+"\n可另选成品文件夹；未选择时保存在应用目录，卸载应用会删除此目录。");root.addView(path);
        button(root,"选择成品保存文件夹",v->{Intent pick=new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);pick.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION|Intent.FLAG_GRANT_WRITE_URI_PERMISSION|Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION|Intent.FLAG_GRANT_PREFIX_URI_PERMISSION);startActivityForResult(pick,41);});
        button(root,"选择全部集数",v->{if(!items.isEmpty()){from.setText("1");to.setText(String.valueOf(items.size()));}});
        button(root,"开始／恢复下载",v->start());button(root,"暂停（保留分片）",v->{if(TransferService.running)startService(new Intent(this,TransferService.class).setAction("pause"));});
        state=new TextView(this);state.setTextSize(16);state.setPadding(0,20,0,20);root.addView(state);
        if(Build.VERSION.SDK_INT>=33&&checkSelfPermission("android.permission.POST_NOTIFICATIONS")!=android.content.pm.PackageManager.PERMISSION_GRANTED)requestPermissions(new String[]{"android.permission.POST_NOTIFICATIONS"},31);
    }
    private EditText field(LinearLayout parent,String hint,String value){EditText f=new EditText(this);f.setHint(hint);f.setText(value);parent.addView(f);return f;}
    private Spinner choice(LinearLayout parent,String...values){Spinner s=new Spinner(this);s.setAdapter(new ArrayAdapter<String>(this,android.R.layout.simple_spinner_dropdown_item,values));parent.addView(s);return s;}
    private String detectGPU(){try{android.opengl.EGLDisplay d=android.opengl.EGL14.eglGetDisplay(android.opengl.EGL14.EGL_DEFAULT_DISPLAY);int[] v=new int[2];android.opengl.EGL14.eglInitialize(d,v,0,v,1);int[] a={android.opengl.EGL14.EGL_RENDERABLE_TYPE,android.opengl.EGL14.EGL_OPENGL_ES2_BIT,android.opengl.EGL14.EGL_SURFACE_TYPE,android.opengl.EGL14.EGL_PBUFFER_BIT,android.opengl.EGL14.EGL_NONE};android.opengl.EGLConfig[] c=new android.opengl.EGLConfig[1];int[] n=new int[1];android.opengl.EGL14.eglChooseConfig(d,a,0,c,0,1,n,0);android.opengl.EGLContext x=android.opengl.EGL14.eglCreateContext(d,c[0],android.opengl.EGL14.EGL_NO_CONTEXT,new int[]{android.opengl.EGL14.EGL_CONTEXT_CLIENT_VERSION,2,android.opengl.EGL14.EGL_NONE},0);android.opengl.EGLSurface s=android.opengl.EGL14.eglCreatePbufferSurface(d,c[0],new int[]{android.opengl.EGL14.EGL_WIDTH,1,android.opengl.EGL14.EGL_HEIGHT,1,android.opengl.EGL14.EGL_NONE},0);android.opengl.EGL14.eglMakeCurrent(d,s,s,x);String name=android.opengl.GLES20.glGetString(android.opengl.GLES20.GL_RENDERER);android.opengl.EGL14.eglMakeCurrent(d,android.opengl.EGL14.EGL_NO_SURFACE,android.opengl.EGL14.EGL_NO_SURFACE,android.opengl.EGL14.EGL_NO_CONTEXT);android.opengl.EGL14.eglDestroySurface(d,s);android.opengl.EGL14.eglDestroyContext(d,x);android.opengl.EGL14.eglTerminate(d);return name==null||name.trim().isEmpty()?"系统未公开":name;}catch(Exception e){return "系统未公开";}}
    private void button(LinearLayout parent,String text,View.OnClickListener action){Button b=new Button(this);b.setText(text);b.setOnClickListener(action);parent.addView(b);}
    private void inspect(){
        final String input=address.getText().toString();state.setText("正在读取官方列表…");
        new Thread(()->{
            try{
                ArrayList<Bili.Item> rows=Bili.catalogue(input);
                runOnUiThread(()->{
                    items=rows;int selected=1;for(Bili.Item item:rows)if(item.current)selected=item.index;
                    from.setText(String.valueOf(selected));to.setText(String.valueOf(selected));
                    StringBuilder text=new StringBuilder("共 "+rows.size()+" 集，当前第"+selected+"集，可输入起止集数或选择全部：\n");
                    for(Bili.Item item:rows)text.append(item.index).append(". ").append(item.title).append('\n');
                    state.setText(text);getSharedPreferences("banana",0).edit().putString("status",text.toString()).apply();
                });
            }catch(Exception e){runOnUiThread(()->state.setText("暂未读取到列表："+e.getMessage()));}
        },"catalogue").start();
    }
    private void start(){try{String value=Bili.normalize(address.getText().toString());int begin=Integer.parseInt(from.getText().toString()),end=Integer.parseInt(to.getText().toString());if(begin<1||end<begin)throw new Exception("请检查选集范围");getSharedPreferences("banana",0).edit().putString("address",value).putInt("from",begin).putInt("to",end).putInt("batch",groupSize.getSelectedItemPosition()==0?10:20).putInt("groups",groupCount.getSelectedItemPosition()+1).putInt("height",new int[]{4320,1080,720}[quality.getSelectedItemPosition()]).apply();Intent i=new Intent(this,TransferService.class);if(Build.VERSION.SDK_INT>=26)startForegroundService(i);else startService(i);}catch(Exception e){state.setText(e.getMessage());}}
    private void login(){WebView web=new WebView(this);web.getSettings().setJavaScriptEnabled(true);web.getSettings().setDomStorageEnabled(true);CookieManager.getInstance().setAcceptCookie(true);web.setWebViewClient(new WebViewClient(){@Override public boolean shouldOverrideUrlLoading(WebView view,WebResourceRequest r){String host=r.getUrl().getHost();return host==null||!(host.equals("bilibili.com")||host.endsWith(".bilibili.com"));}});web.loadUrl("https://passport.bilibili.com/login");new AlertDialog.Builder(this).setTitle("账号授权仅保存在本应用").setView(web).setPositiveButton("完成",(d,w)->{CookieManager.getInstance().flush();web.destroy();}).setOnCancelListener(d->web.destroy()).show();}
    @Override protected void onResume(){super.onResume();handler.post(refresh);}
    @Override protected void onPause(){handler.removeCallbacks(refresh);super.onPause();}
    @Override protected void onActivityResult(int request,int result,Intent data){super.onActivityResult(request,result,data);if(request==41&&result==RESULT_OK&&data!=null&&data.getData()!=null){android.net.Uri uri=data.getData();int flags=data.getFlags()&(Intent.FLAG_GRANT_READ_URI_PERMISSION|Intent.FLAG_GRANT_WRITE_URI_PERMISSION);getContentResolver().takePersistableUriPermission(uri,flags);getSharedPreferences("banana",0).edit().putString("outputTree",uri.toString()).apply();state.setText("已选择成品保存文件夹；下载分片保留在应用工作目录。");}}
}
