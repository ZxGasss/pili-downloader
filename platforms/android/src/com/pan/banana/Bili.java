package com.pan.banana;

import android.webkit.CookieManager;
import org.json.*;
import java.net.*;
import java.io.*;
import java.util.*;

/** Uses only the session explicitly created in this application's WebView. */
final class Bili {
    static final class Item {
        String bvid, cid, title, series, cover; int index; boolean current;
        String url() { return "https://www.bilibili.com/video/" + bvid; }
    }
    static String normalize(String input) throws Exception {
        String s = input.trim();
        if(s.matches("(?i)bv[0-9a-z]{10}")) s="https://www.bilibili.com/video/BV"+s.substring(2);
        if(s.matches("(?i)av[1-9][0-9]*")) s="https://www.bilibili.com/video/av"+s.substring(2);
        if(s.matches("(?i)(www\\.)?bilibili\\.com/.*")) s="https://"+s;
        URI u=new URI(s); String host=u.getHost();
        if(!"https".equals(u.getScheme()) || u.getUserInfo()!=null || host==null || !(host.equals("www.bilibili.com")||host.equals("bilibili.com")))
            throw new Exception("请输入哔哩哔哩视频、番剧地址或有效 AV/BV 编号。");
        String query=u.getRawQuery(),keep=null;
        if(query!=null)for(String part:query.split("&"))if(part.matches("p=[1-9][0-9]*")){keep=part;break;}
        return new URI("https",null,"www.bilibili.com",-1,u.getPath(),keep,null).toString();
    }
    static HttpURLConnection connect(String address) throws Exception {
        URL u=new URL(address); if(!u.getProtocol().equals("https")) throw new IOException("仅允许安全连接");
        HttpURLConnection c=(HttpURLConnection)u.openConnection(); c.setConnectTimeout(20000); c.setReadTimeout(20000); c.setInstanceFollowRedirects(false);
        c.setRequestProperty("User-Agent","Mozilla/5.0"); c.setRequestProperty("Referer","https://www.bilibili.com/");
        String h=u.getHost();
        if(h.equals("bilibili.com") || h.endsWith(".bilibili.com")) {
            String cookie=CookieManager.getInstance().getCookie("https://www.bilibili.com/");
            if(cookie!=null) c.setRequestProperty("Cookie",cookie);
        }
        return c;
    }
    static JSONObject json(String address) throws Exception {
        HttpURLConnection c=connect(address);
        try {
            if(c.getResponseCode()!=200) throw new IOException("网站返回 "+c.getResponseCode());
            ByteArrayOutputStream out=new ByteArrayOutputStream(); byte[] b=new byte[8192]; int n;
            try(InputStream in=c.getInputStream()) { while((n=in.read(b))>0) { out.write(b,0,n); if(out.size()>8000000) throw new IOException("返回内容过大"); } }
            JSONObject root=new JSONObject(out.toString("UTF-8"));
            if(root.optInt("code",-1)!=0) throw new IOException("网站暂未提供该内容，请检查账号权限（"+root.optInt("code")+"）。");
            return root.has("data")?root.getJSONObject("data"):root.getJSONObject("result");
        } finally { c.disconnect(); }
    }
    static ArrayList<Item> catalogue(String address) throws Exception {
        URI u=new URI(normalize(address)); String[] p=u.getPath().split("/"); String key=p[p.length-1];
        if(u.getPath().startsWith("/bangumi/play/")) {
            String parameter=key.startsWith("ss")?"season_id":"ep_id";
            if(!(key.startsWith("ss")||key.startsWith("ep"))||!key.substring(2).matches("[1-9][0-9]*")) throw new IOException("番剧地址无效。");
            JSONObject season=json("https://api.bilibili.com/pgc/view/web/season?"+parameter+"="+key.substring(2));
            ArrayList<Item> result=new ArrayList<>(); JSONArray episodes=season.getJSONArray("episodes");
            for(int j=0;j<episodes.length();j++) { JSONObject row=episodes.getJSONObject(j); Item i=new Item();
                i.bvid=row.optString("bvid"); i.cid=row.optString("cid"); i.index=j+1; String label=row.optString("title",String.valueOf(i.index));
                try{i.index=Integer.parseInt(label);}catch(NumberFormatException ignored){}
                i.title="第"+label+"话 "+row.optString("long_title"); i.series=season.optString("title","未命名番剧"); i.cover=row.optString("cover");
                i.current=key.equals("ep"+row.optLong("id")); result.add(i);
            }
            Collections.sort(result,new Comparator<Item>(){public int compare(Item a,Item b){return Integer.compare(a.index,b.index);}}); return result;
        }
        if(!u.getPath().startsWith("/video/")) throw new IOException("当前支持投稿视频、分P、投稿合集与番剧正片。");
        JSONObject data=json("https://api.bilibili.com/x/web-interface/view?"+(key.startsWith("av")?"aid="+key.substring(2):"bvid="+key));
        ArrayList<Item> rows=parseCatalogue(data);
        if(data.optJSONObject("ugc_season")==null){
            int selected=1;String query=u.getRawQuery();
            if(query!=null)for(String part:query.split("&"))if(part.matches("p=[1-9][0-9]*"))selected=Integer.parseInt(part.substring(2));
            for(Item item:rows)item.current=item.index==selected;
        }
        return rows;
    }
    static ArrayList<Item> parseCatalogue(JSONObject data) throws Exception {
        ArrayList<Item> result=new ArrayList<>(); JSONObject season=data.optJSONObject("ugc_season");
        if(season!=null) {
            JSONArray sections=season.getJSONArray("sections"); Set<String> seen=new HashSet<>();
            for(int s=0;s<sections.length();s++) { JSONArray rows=sections.getJSONObject(s).getJSONArray("episodes");
                for(int j=0;j<rows.length();j++) { JSONObject row=rows.getJSONObject(j); String bv=row.optString("bvid"); if(bv.isEmpty()||!seen.add(bv)) continue;
                    Item i=new Item(); i.bvid=bv; i.title=row.getString("title"); i.series=season.getString("title"); i.index=result.size()+1; i.current=bv.equals(data.optString("bvid"));
                    JSONObject arc=row.optJSONObject("arc"); i.cover=arc==null?season.optString("cover"):arc.optString("pic"); result.add(i);
                }
            }
        } else {
            JSONArray pages=data.getJSONArray("pages");
            for(int j=0;j<pages.length();j++) { JSONObject page=pages.getJSONObject(j); Item i=new Item(); i.bvid=data.getString("bvid");
                i.cid=page.get("cid").toString(); i.index=j+1; i.title=pages.length()>1?page.getString("part"):data.getString("title"); i.series=data.getString("title"); i.cover=data.optString("pic"); result.add(i);
            }
        }
        return result;
    }
    static JSONObject streams(Item i) throws Exception {
        JSONObject info=json("https://api.bilibili.com/x/web-interface/view?bvid="+i.bvid);
        if(info.optBoolean("is_upower_preview")||info.optBoolean("is_preview"))throw new IOException("当前账号仅能取得试看内容，请登录并确认此内容权限");
        if(i.cid==null) i.cid=info.get("cid").toString();
        JSONObject data=json("https://api.bilibili.com/x/player/playurl?bvid="+i.bvid+"&cid="+i.cid+"&qn=127&fnval=4048&fourk=1");
        if(data.optBoolean("is_drm")||data.optInt("is_drm",0)!=0) throw new IOException("该内容受加密保护，无法下载。");
        if(data.optBoolean("is_preview")||data.optBoolean("is_upower_preview"))throw new IOException("网站只提供试看，未作为完整视频下载");
        JSONObject dash=data.optJSONObject("dash"); if(dash==null) throw new IOException("网站未提供可用分流，请检查当前账号权限。"); return dash;
    }
    static JSONObject choose(JSONArray choices,int maxHeight,boolean video) throws Exception {
        JSONObject chosen=null;
        for(int j=0;j<choices.length();j++) { JSONObject v=choices.getJSONObject(j);
            // Android 7's platform muxer has no AV1 or FLAC-in-MP4 support.
            if(video && (!v.optString("codecs").startsWith("avc")||v.optInt("height")>maxHeight)) continue;
            if(!video && !v.optString("codecs").startsWith("mp4a")) continue;
            if(chosen==null || (video?v.optInt("height")>chosen.optInt("height"):v.optLong("bandwidth")>chosen.optLong("bandwidth")) || (video&&v.optInt("height")==chosen.optInt("height")&&v.optLong("bandwidth")>chosen.optLong("bandwidth"))) chosen=v;
        }
        if(chosen==null) throw new IOException("没有此设备可封装的 H.264/AAC 音视频流。"); return chosen;
    }
    static String safe(String title) { String clean=title.replaceAll("[\\\\/:*?\"<>|\\r\\n]","_").replaceAll("^\\.+|[. ]+$","");return clean.isEmpty()?"未命名合集":clean.substring(0,Math.min(60,clean.length())); }
}
