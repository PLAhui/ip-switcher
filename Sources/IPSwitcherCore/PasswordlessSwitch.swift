import Foundation

/// 「免密切换」开关。
///
/// 原理：向 /etc/sudoers.d/ 写入一条只对 /usr/sbin/networksetup 生效的 NOPASSWD 规则。
/// 规则生效后，PrivilegedExecutor 探测到免密可用，会直接以
/// `sudo -n` 逐条执行 networksetup（静默通过），不再弹出授权对话框。
///
/// 写入/删除规则本身仍需一次管理员授权（走原授权对话框），这是最后一次输密码。
/// 撤销方式：关闭开关，或手动 `sudo rm /etc/sudoers.d/ipswitcher`。
public enum PasswordlessSwitch {
    /// 规则文件路径（/etc/sudoers.d/ 目录内的文件都会被 sudo 读取）。
    public static let sudoersPath = "/etc/sudoers.d/ipswitcher"

    /// 唯一放行的程序：networksetup（完整路径，写死）。
    /// 该命令只能修改网络配置（IP/DNS/路由/代理），不能访问文件或提权。
    public static let toolPath = "/usr/sbin/networksetup"

    /// 写入的规则行：管理员组成员免密执行 networksetup。
    public static let ruleLine = "%admin ALL=(root) NOPASSWD: \(toolPath)"

    // MARK: - 状态

    /// 免密是否已开启：规则文件存在且包含我们的规则行。
    public static func isEnabled() -> Bool {
        guard let content = try? String(contentsOfFile: sudoersPath, encoding: .utf8) else {
            return false
        }
        return content.split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces) == ruleLine
        }
    }

    /// 探测当前环境是否允许静默执行 networksetup（供 PrivilegedExecutor 判断走哪条通道）。
    /// `sudo -n -l <path>` 命中 NOPASSWD 规则时返回 0，需要密码时返回非 0，均不产生副作用。
    public static func isSilentExecutionAllowed() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["-n", "-l", toolPath]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    // MARK: - 提权脚本（由 PrivilegedExecutor 以管理员权限执行）

    /// 开启免密：临时文件 → visudo 语法校验 → 安装为 0440 root:wheel。
    /// 校验失败会保留临时文件名并退出，绝不安装残缺规则。
    public static func enableScript() -> String {
        """
        set -e
        RULE_FILE='\(sudoersPath)'
        TMP=$(mktemp /tmp/ipswitcher-sudoers.XXXXXX)
        printf '%s\\n' '\(ruleLine)' > "$TMP"
        if ! /usr/sbin/visudo -cf "$TMP" >/dev/null 2>&1; then
          echo "IPSWITCHER_SUDOERS_INVALID" >&2
          rm -f "$TMP"
          exit 1
        fi
        /usr/sbin/install -m 0440 -o root -g wheel "$TMP" "$RULE_FILE"
        rm -f "$TMP"
        echo "IPSWITCHER_SUDOERS_ENABLED"
        """
    }

    /// 关闭免密：删除规则文件（文件不存在也视为成功，保证幂等）。
    public static func disableScript() -> String {
        """
        set -e
        rm -f '\(sudoersPath)'
        echo "IPSWITCHER_SUDOERS_DISABLED"
        """
    }

    /// 解析脚本输出为用户可读的结果报告。
    public static func report(for result: PrivilegedResult, enabling: Bool) -> ApplyReport {
        let verb = enabling ? "开启" : "关闭"
        if result.cancelled {
            return ApplyReport(succeeded: false, title: "已取消",
                               message: "未\(verb)免密切换，规则文件未做任何改动。",
                               commandCount: 0, skipped: [], neutralized: [], rolledBack: false)
        }
        guard result.succeeded else {
            return ApplyReport(succeeded: false, title: "\(verb)失败",
                               message: result.stdout.isEmpty ? result.stderr : result.stdout,
                               commandCount: 0, skipped: [], neutralized: [], rolledBack: false)
        }
        if enabling {
            return ApplyReport(succeeded: true, title: "免密切换已开启",
                               message: "规则已写入 \(sudoersPath)（仅对 networksetup 生效）。"
                                   + "之后切换方案、恢复 DHCP、切换位置都不再要求密码。",
                               commandCount: 0, skipped: [], neutralized: [], rolledBack: false)
        }
        return ApplyReport(succeeded: true, title: "免密切换已关闭",
                           message: "规则文件已删除，恢复为每次操作都要求管理员密码。",
                           commandCount: 0, skipped: [], neutralized: [], rolledBack: false)
    }
}
