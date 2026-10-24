# Roadmap

## 2.0
- [x] 从既有1.8.3演进；Bilibili下载为第一入口。
- [x] 真实暂停停止子进程，保留分片、持久化检查点、恢复前刷新播放地址。
- [x] 全局四集和单集八连接上限；整季完成数与活跃流进度汇总。
- [x] 旧历史首次改写前快照；坏JSON保护；独立媒体索引。
- [x] 同卷文件改名/移动保留ID，跨卷可手动重关联；记录删除与视频废纸篓分离。
- [x] 图片请求合并、离屏取消、磁盘/内存缓存、后台本地缩略图。
- [x] Keychain会话、账号头像昵称会员、用户主动Chrome只读导入、只读收藏入口。
- [x] mdls/ffmpeg逐文件检查与分辨率纠正预览，确认后清理可靠关联的残留。
- [ ] 不同macOS/Chrome版本、真实大会员和收藏隐私权限的完整实机矩阵。
- [ ] 203集真实网络长时间压力、异常退出恢复与滚动性能的量化报告。
- [ ] 可信Developer ID签名、公证与自动更新签名渠道。
- [ ] 文件系统持续监听和更完善的跨卷候选匹配；当前按目录扫描或手动重定位。
- [ ] 缩略图缓存的可见容量管理入口。

不自动删除视频，不静默覆盖；不把本地规则分类称作AI，不将未验收能力当作通过。

## 参考
Chrome会话格式参考Chromium源代码（PBKDF2与Cookie域名摘要）：
https://chromium.googlesource.com/chromium/src/+/main/components/os_crypt/sync/os_crypt_mac.mm
https://chromium.googlesource.com/chromium/src/+/5ea6d65c622a3d5ff75db9dc0257ea3869f31289%5E%21/
