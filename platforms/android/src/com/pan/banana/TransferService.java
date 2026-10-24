package com.pan.banana;

import android.app.*;
import android.content.*;
import android.os.*;
import android.media.*;
import org.json.*;
import java.io.*;
import java.net.*;
import java.nio.ByteBuffer;
import java.util.*;
import java.util.concurrent.*;

public final class TransferService extends Service {
    static volatile boolean running=false, paused=false;
    static volatile String status="准备就绪";
    private PowerManager.WakeLock wake;
    @Override public IBinder onBind(Intent intent) { return null; }
    @Override public int onStartCommand(Intent intent,int flags,int id) {
        if(intent!=null&&"pause".equals(intent.getAction())) { paused=true; status="正在暂停，分片会保留"; return START_NOT_STICKY; }
        if(running) return START_NOT_STICKY;
        if(Build.VERSION.SDK_INT>=26) ((NotificationManager)getSystemService(NOTIFICATION_SERVICE)).createNotificationChannel(new NotificationChannel("downloads","下载进度",NotificationManager.IMPORTANCE_LOW));
        startForeground(15,notification("正在准备下载")); running=true; paused=false;
        wake=((PowerManager)getSystemService(POWER_SERVICE)).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,"banana:downloads"); wake.acquire(3600000L);
        new Thread(()-> {
            try { runQueue(); status=paused?"已暂停，下次可继续":"本次所选内容已完成"; }
            catch(Exception e) { status="未完成，分片已保留："+friendly(e); }
            finally { running=false; if(wake!=null&&wake.isHeld()) wake.release(); saveStatus(); stopForeground(true); stopSelf(); }
        },"download-coordinator").start();
        return START_NOT_STICKY;
    }
    private Notification notification(String text) {
        Notification.Builder b=Build.VERSION.SDK_INT>=26?new Notification.Builder(this,"downloads"):new Notification.Builder(this);
        Intent open=new Intent(this,MainActivity.class);
        b.setSmallIcon(android.R.drawable.stat_sys_download).setContentTitle("霹雳下载 · BY 潘飘亮").setContentText(text).setOngoing(true)
            .setContentIntent(PendingIntent.getActivity(this,0,open,PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE));
        return b.build();
    }
    private synchronized void update(String text) { status=text; saveStatus(); ((NotificationManager)getSystemService(NOTIFICATION_SERVICE)).notify(15,notification(text)); }
    private void saveStatus() { getSharedPreferences("banana",0).edit().putString("status",status).apply(); }
    private void runQueue() throws Exception {
        android.content.SharedPreferences p=getSharedPreferences("banana",0);
        ArrayList<Bili.Item> rows=Bili.catalogue(p.getString("address",""));
        int from=p.getInt("from",1), to=p.getInt("to",from), size=p.getInt("batch",10), groups=p.getInt("groups",2), height=p.getInt("height",4320);
        if(from<1||to<from||to>rows.size()) throw new IOException("选集范围无效，请先解析合集并检查集数。");
        ExecutorService pool=Executors.newFixedThreadPool(Math.min(4,Math.max(1,groups))); ArrayList<Future<?>> tasks=new ArrayList<>();
        try {
            for(int start=from-1;start<to;start+=size) { final int begin=start,end=Math.min(to,start+size);
                tasks.add(pool.submit(()-> { for(int n=begin;n<end&&!paused;n++) { try { transfer(rows.get(n),height); } catch(Exception e) { throw new RuntimeException(e); } } }));
            }
            for(Future<?> task:tasks) task.get();
        } finally { if(!tasks.stream().allMatch(Future::isDone))paused=true;pool.shutdownNow();pool.awaitTermination(30,TimeUnit.SECONDS); }
    }
    private void transfer(Bili.Item item,int height) throws Exception {
        File base=getExternalFilesDir(Environment.DIRECTORY_MOVIES);if(base==null)base=getFilesDir();
        File folder=new File(base,Bili.safe(item.series)); folder.mkdirs();
        File output=new File(folder,String.format(Locale.ROOT,"%03d - %s.mp4",item.index,Bili.safe(item.title)));
        if(output.exists()&&output.length()>0) { exportIfNeeded(output);return; }
        int attempt=0;
        while(!paused) {
            try {
                JSONObject dash=Bili.streams(item), video=Bili.choose(dash.getJSONArray("video"),height,true), audio=Bili.choose(dash.getJSONArray("audio"),height,false);
                File v=new File(folder,item.bvid+"-"+item.cid+"-v"+video.optInt("id")+".part"),a=new File(folder,item.bvid+"-"+item.cid+"-a"+audio.optInt("id")+".part");
                fetch(video.optString("baseUrl",video.optString("base_url")),v,item,"视频");
                if(paused) return; fetch(audio.optString("baseUrl",audio.optString("base_url")),a,item,"音频"); if(paused) return;
                update("第"+item.index+"集 · 正在合并 · "+item.title);
                File temporary=new File(output.getPath()+".merging"); mux(v,a,temporary);
                if(!temporary.renameTo(output)) throw new IOException("无法保存最终文件");
                exportIfNeeded(output);
                v.delete(); a.delete();
                try(FileOutputStream log=new FileOutputStream(new File(folder,"下载日志.txt"),true)) {
                    log.write(("第"+item.index+"集 | "+item.title+" | "+item.url()+" | "+item.bvid+" | "+output.getName()+"\n").getBytes("UTF-8"));
                }
                update("已保存第"+item.index+"集 · "+item.title); return;
            } catch(SocketTimeoutException|java.net.SocketException e) {
                if(++attempt>3) throw e; update("第"+item.index+"集网络中断，正在重连（"+attempt+"/3）");
                for(int i=0;i<(1<<attempt)&&!paused;i++) Thread.sleep(1000);
            }
        }
    }
    private void exportIfNeeded(File output) throws Exception{
        android.content.SharedPreferences prefs=getSharedPreferences("banana",0);String tree=prefs.getString("outputTree","");
        if(tree.isEmpty())return;String marker="exported:"+tree+":"+output.getAbsolutePath();if(prefs.getBoolean(marker,false))return;
        export(output,tree);prefs.edit().putBoolean(marker,true).apply();
    }
    private void export(File output,String tree) throws Exception{
        android.net.Uri folder=android.net.Uri.parse(tree);
        android.net.Uri parent=android.provider.DocumentsContract.buildDocumentUriUsingTree(folder,android.provider.DocumentsContract.getTreeDocumentId(folder));
        android.net.Uri children=android.provider.DocumentsContract.buildChildDocumentsUriUsingTree(folder,android.provider.DocumentsContract.getTreeDocumentId(folder));
        try(android.database.Cursor rows=getContentResolver().query(children,new String[]{android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME},null,null,null)){
            while(rows!=null&&rows.moveToNext())if(output.getName().equals(rows.getString(0)))throw new IOException("所选文件夹已有同名文件；不会覆盖，请另选文件夹");
        }
        android.net.Uri document=android.provider.DocumentsContract.createDocument(getContentResolver(),parent,"application/octet-stream",output.getName()+".part");
        if(document==null)throw new IOException("所选文件夹暂不可写，成品保留在工作目录");
        long count=0;try(InputStream in=new FileInputStream(output);OutputStream out=getContentResolver().openOutputStream(document,"w")){
            if(out==null)throw new IOException("无法写入所选文件夹");byte[] buffer=new byte[131072];int n;
            while((n=in.read(buffer))>0){out.write(buffer,0,n);count+=n;}out.flush();
        }
        if(count!=output.length())throw new IOException("导出未完成，原成品仍保留在工作目录");
        if(android.provider.DocumentsContract.renameDocument(getContentResolver(),document,output.getName())==null)throw new IOException("文件已复制为.part，文件夹暂不支持重命名；原件仍在工作目录");
    }
    private void fetch(String source,File output,Bili.Item item,String kind) throws Exception {
        if(paused) return; long offset=output.exists()?output.length():0;
        HttpURLConnection c=Bili.connect(source);
        File validator=new File(output.getPath()+".validator");
        if(offset>0) { c.setRequestProperty("Range","bytes="+offset+"-");
            if(validator.exists())try(BufferedReader stored=new BufferedReader(new FileReader(validator))){String tag=stored.readLine();if(tag!=null)c.setRequestProperty("If-Range",tag);}
        }
        try {
            int code=c.getResponseCode();
            if(code==416&&offset>0&&("bytes */"+offset).equals(c.getHeaderField("Content-Range")))return;
            if(code!=200&&code!=206) throw new IOException("网站拒绝本次传输（"+code+"），已保留分片。");
            if(code==206) { String range=c.getHeaderField("Content-Range"); if(range==null||!range.startsWith("bytes "+offset+"-")) throw new IOException("续传范围校验失败"); }
            else offset=0;
            String tag=c.getHeaderField("ETag");if(tag!=null&&!tag.startsWith("W/"))try(FileWriter stored=new FileWriter(validator)){stored.write(tag);}
            long total=c.getContentLengthLong()+offset, count=offset, start=System.nanoTime(), last=0;
            try(InputStream in=c.getInputStream(); FileOutputStream out=new FileOutputStream(output,code==206)) {
                byte[] buffer=new byte[131072]; int n;
                while(!paused&&(n=in.read(buffer))>0) {
                    out.write(buffer,0,n); count+=n; long now=System.nanoTime();
                    if(now-last>2000000000L) { last=now; double speed=(count-offset)/Math.max(1,(now-start)/1e9);
                        update(String.format(Locale.ROOT,"第%d集 %s · %.1f / %.1f MB · %.1f MB/秒\n%s",item.index,kind,count/1e6,total/1e6,speed/1e6,item.title)); }
                }
                out.getFD().sync();
                if(!paused&&total>0&&count!=total) throw new SocketException("传输未完成");
            }
        } finally { c.disconnect(); }
    }
    void mux(File video,File audio,File output) throws Exception {
        MediaMuxer muxer=new MediaMuxer(output.getPath(),MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);
        MediaExtractor v=new MediaExtractor(),a=new MediaExtractor(); boolean started=false;
        try {
            v.setDataSource(video.getPath()); a.setDataSource(audio.getPath());
            if(v.getTrackCount()<1||a.getTrackCount()<1) throw new IOException("媒体轨道不完整");
            int vt=muxer.addTrack(v.getTrackFormat(0)),at=muxer.addTrack(a.getTrackFormat(0)); v.selectTrack(0);a.selectTrack(0);muxer.start();started=true;
            copyTrack(v,muxer,vt);copyTrack(a,muxer,at);
        } finally { v.release();a.release();try {if(started)muxer.stop();}finally {muxer.release();} }
    }
    private void copyTrack(MediaExtractor source,MediaMuxer muxer,int track) throws Exception {
        ByteBuffer data=ByteBuffer.allocateDirect(8*1024*1024);MediaCodec.BufferInfo info=new MediaCodec.BufferInfo();
        while(!paused) { data.clear(); int size=source.readSampleData(data,0);if(size<0)return;if((source.getSampleFlags()&MediaExtractor.SAMPLE_FLAG_ENCRYPTED)!=0)throw new IOException("内容包含加密媒体样本，无法下载为可播放文件");info.set(0,size,source.getSampleTime(),source.getSampleFlags());muxer.writeSampleData(track,data,info);source.advance(); }
        throw new IOException("已暂停合并，原分轨仍保留");
    }
    private String friendly(Exception e) { Throwable c=e;while(c.getCause()!=null)c=c.getCause();if(c instanceof SocketTimeoutException)return "网络读取超时，可继续下载";return c.getMessage()==null?"请检查网络或保存目录":c.getMessage(); }
    @Override public void onTimeout(int startId,int fgsType) { paused=true;status="系统后台下载时限已到，分片保留，可重新打开继续";stopSelf(); }
}
