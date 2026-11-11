import AppKit
import IPSwitcherCore

/// 普通应用模式：不做菜单栏常驻。启动即打开主界面，关闭窗口即退出进程。
/// 所有方案的新增、应用、删除都在 WebWindowController 里完成。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var mainWindow = WebWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        IPSLog.write("App 进程启动，开始初始化")
        do {
            try Store.bootstrap()
        } catch {
            IPSLog.write("初始化失败：\(error.localizedDescription)")
        }

        // 启动即打开主界面；关闭窗口即退出（见 WebWindowController.windowWillClose）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.mainWindow.present()
        }
    }

    /// 用户点击 Dock 图标且没有可见窗口时，重新唤出主界面。
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindow.present() }
        return true
    }

    /// 关闭窗口即退出：由 AppKit 在窗口真正关闭后统一走标准退出流程，
    /// 不在 windowWillClose 里手动 terminate（时机不可靠，可能残留后台进程）。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// 双保险：无论从哪个入口退出（红点 / Cmd+Q / 页面内「退出」）都直接结束进程。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateNow
    }
}
