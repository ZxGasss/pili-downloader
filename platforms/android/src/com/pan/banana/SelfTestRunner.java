package com.pan.banana;

import android.app.Instrumentation;
import android.os.Bundle;
import android.media.*;
import org.json.JSONObject;
import java.io.*;
import java.util.*;
import java.nio.ByteBuffer;

/** Non-UI instrumentation; synthetic/owned fixture data only. */
public final class SelfTestRunner extends Instrumentation {
    @Override public void onCreate(Bundle args){super.onCreate(args);start();}
    @Override public void onStart(){Bundle result=new Bundle();try{
        if(!Bili.normalize("BV1QMTv6uE45").endsWith("/BV1QMTv6uE45"))throw new Exception("BV normalization");
        if(!Bili.normalize("bilibili.com/video/BV1QMTv6uE45/?trackid=test&p=2").equals("https://www.bilibili.com/video/BV1QMTv6uE45/?p=2"))throw new Exception("Scheme completion/tracking cleanup");
        ArrayList<Bili.Item> live=Bili.catalogue("bilibili.com/video/BV1vNng6GE93/?trackid=web_pegasus");if(live.isEmpty())throw new Exception("Real site catalogue");
        JSONObject dash=Bili.streams(live.get(0));Bili.choose(dash.getJSONArray("video"),1080,true);Bili.choose(dash.getJSONArray("audio"),1080,false);
        try{Bili.normalize("https://www.bilibili.com.evil.test/video/BVbad");throw new AssertionError("Foreign URL accepted");}catch(Exception expected){}
        ByteArrayOutputStream data=new ByteArrayOutputStream();try(InputStream in=getTargetContext().getAssets().open("ugc-fixture.json")){byte[] b=new byte[8192];int n;while((n=in.read(b))>0)data.write(b,0,n);}
        ArrayList<Bili.Item> list=Bili.parseCatalogue(new JSONObject(data.toString("UTF-8")).getJSONObject("data"));
        if(list.size()!=48||list.get(1).index!=2||!list.get(1).current)throw new Exception("Collection/current item order");
        for(int i=0;i<list.size();i++)if(list.get(i).index!=i+1)throw new Exception("Noncontiguous order");
        File fixture=new File(getTargetContext().getCacheDir(),"owned-fixture.mp4");
        try(InputStream in=getTargetContext().getAssets().open("owned-fixture.mp4");FileOutputStream out=new FileOutputStream(fixture)){byte[] b=new byte[8192];int n;while((n=in.read(b))>0)out.write(b,0,n);}
        MediaExtractor media=new MediaExtractor();media.setDataSource(fixture.getPath());if(media.getTrackCount()!=2)throw new Exception("Owned AV fixture tracks");media.release();
        File video=new File(fixture.getParentFile(),"v.mp4"),audio=new File(fixture.getParentFile(),"a.m4a"),merged=new File(fixture.getParentFile(),"merged.mp4");
        split(fixture,video,"video/");split(fixture,audio,"audio/");if(merged.exists())merged.delete();new TransferService().mux(video,audio,merged);
        media=new MediaExtractor();media.setDataSource(merged.getPath());if(media.getTrackCount()!=2)throw new Exception("Merged tracks");media.release();
        result.putString("stream","ANDROID_RUNTIME_PASS: missing-scheme screenshot URL normalized; real Bilibili catalogue/streams resolved; 48-episode order; native two-track MP4 mux passed.\n");finish(-1,result);
    }catch(Throwable error){result.putString("stream","ANDROID_RUNTIME_FAIL: "+error.toString()+"\n");finish(0,result);}}
    private void split(File input,File output,String mime) throws Exception{
        if(output.exists())output.delete();MediaExtractor source=new MediaExtractor();source.setDataSource(input.getPath());
        MediaMuxer target=new MediaMuxer(output.getPath(),MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);
        try{int chosen=-1;for(int i=0;i<source.getTrackCount();i++)if(source.getTrackFormat(i).getString(MediaFormat.KEY_MIME).startsWith(mime)){chosen=i;break;}
            if(chosen<0)throw new Exception("Fixture track missing");int track=target.addTrack(source.getTrackFormat(chosen));source.selectTrack(chosen);target.start();
            ByteBuffer buffer=ByteBuffer.allocateDirect(1024*1024);MediaCodec.BufferInfo info=new MediaCodec.BufferInfo();
            while(true){buffer.clear();int size=source.readSampleData(buffer,0);if(size<0)break;info.set(0,size,source.getSampleTime(),source.getSampleFlags());target.writeSampleData(track,buffer,info);source.advance();}target.stop();
        }finally{source.release();target.release();}
    }
}
