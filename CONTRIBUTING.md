# 贡献指南

先阅读state.md和文件图谱。提交应说明用户问题、改动边界、旧版数据兼容方式、测试结果和未验证范围。

## 开发与验证
- Swift 5.9以上，macOS App最低macOS13；共享核心以Package.swift为准。
- `swift test`验证共享解析/命名模型；`swiftc -swift-version 5 -parse-as-library -typecheck Sources/*.swift`检查完整App。
- `python3 scripts/test-state.py`使用独立preview标识和自有媒体夹具，禁止在用户下载目录进行破坏性测试。
- `python3 Tests/resume_transfer.py`验证自有localhost Range续传与完整哈希。
- macOS打包外部工具需自行准备，遵守各自许可证；不得将账号会话或私有工具配置提交到仓库。

## 安全约束
凭据仅进Keychain；诊断脱敏；新云端写操作必须由用户明确触发。收藏只读。
整理必须先预览，目标冲突停止，不覆盖、不默认删除。样本指纹仅用于候选匹配，不作自动删除依据。
下载完成前不清理分片。清理前重新核验对应成品、残留大小/修改时间以及全局无活动下载。

不要仅为了目录命名移动大段代码。新边界应对应实际状态、数据所有权或可测试职责。
