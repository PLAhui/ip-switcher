import AppKit
import IPSwitcherCore

/// NSApplication.delegate 是 assign（不持有）。必须用真正的全局强引用持有 delegate，
/// 否则 release 构建下 ARC 会提前释放 AppDelegate。
private enum DelegateBox {
    static let shared = AppDelegate()
}

let application = NSApplication.shared
application.delegate = DelegateBox.shared
// 普通 Dock 应用：关闭窗口即退出，不常驻后台。
application.setActivationPolicy(.regular)
application.run()
