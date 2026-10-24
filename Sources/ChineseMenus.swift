import AppKit

extension Notification.Name { static let piliOpenSettings = Notification.Name("pili.openSettings") }

@MainActor enum ChineseMenus {
    static func localize(_ menu: NSMenu?) {
        guard let menu else { return }
        let names: [String: String] = [
            "File":"文件", "Edit":"编辑", "View":"显示", "Window":"窗口", "Help":"帮助",
            "New":"新建窗口", "New Window":"新建窗口", "Close Window":"关闭窗口", "Close":"关闭",
            "Minimize":"最小化", "Zoom":"缩放", "Bring All to Front":"全部置于前面",
            "Enter Full Screen":"进入全屏幕", "Exit Full Screen":"退出全屏幕",
            "Show Tab Bar":"显示标签栏", "Hide Tab Bar":"隐藏标签栏", "Show All Tabs":"显示所有标签页",
            "Show Toolbar":"显示工具栏", "Hide Toolbar":"隐藏工具栏", "Customize Toolbar…":"自定工具栏…",
            "Undo":"撤销", "Redo":"重做", "Cut":"剪切", "Copy":"拷贝", "Paste":"粘贴", "Delete":"删除",
            "Select All":"全选", "Paste and Match Style":"粘贴并匹配样式", "Find":"查找", "Find…":"查找…",
            "Find Next":"查找下一个", "Find Previous":"查找上一个", "Use Selection for Find":"使用所选内容查找",
            "Jump to Selection":"跳到所选内容", "Services":"服务", "Hide Others":"隐藏其他", "Show All":"显示全部",
            "Settings…":"设置…", "Preferences…":"设置…", "Spelling and Grammar":"拼写和语法",
            "Substitutions":"替换", "Transformations":"转换", "Speech":"语音", "Start Speaking":"开始朗读", "Stop Speaking":"停止朗读",
            "Emoji & Symbols":"表情与符号", "Emoji & Symbols…":"表情与符号…", "Dictation…":"听写…",
            "Show Colors":"显示颜色", "Hide Colors":"隐藏颜色", "Show Fonts":"显示字体"
        ]
        for item in menu.items {
            if let name = names[item.title] { item.title = name }
            else if item.title.hasPrefix("About ") { item.title = "关于霹雳下载" }
            else if item.title.hasPrefix("Quit ") { item.title = "退出霹雳下载" }
            else if item.title.hasPrefix("Hide ") { item.title = "隐藏霹雳下载" }
            else if item.title.hasPrefix("Show ") && item.title.contains("Help") { item.title = "霹雳下载帮助" }
            localize(item.submenu)
        }
    }
}
