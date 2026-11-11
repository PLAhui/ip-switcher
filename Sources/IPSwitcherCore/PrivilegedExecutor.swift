import Foundation

public struct PrivilegedResult {
    public let code: Int32
    public let stdout: String
    public let stderr: String

    public var cancelled: Bool {
        let text = stderr.lowercased()
        return text.contains("user canceled") || text.contains("user cancelled")
            || text.contains("(-128)") || text.contains("用户取消")
    }

    public var succeeded: Bool { code == 0 && !cancelled }
}

public enum PrivilegedExecutor {
    public enum ExecutorError: Error, LocalizedError {
        case osascriptUnavailable
        public var errorDescription: String? { "无法调用系统授权对话框" }
    }

    /// 应用预设的标准入口：
    /// - 已开启免密（sudoers NOPASSWD 规则生效）→ 直接静默执行，无对话框
    /// - 未开启 → 走 osascript 授权对话框（原行为）
    public static func run(apply: [[String]],
                           rollback: [[String]] = []) throws -> PrivilegedResult {
        let silent = PasswordlessSwitch.isSilentExecutionAllowed()
        let script = NetworkSetup.shellScript(apply: apply, rollback: rollback,
                                              sudoPrefix: silent)
        if silent {
            IPSLog.write("免密通道生效，静默执行 \(apply.count) 条、回滚 \(rollback.count) 条命令")
            return try runPlain(script: script)
        }
        IPSLog.write("生成提权脚本，应用 \(apply.count) 条、回滚 \(rollback.count) 条命令")
        return try run(script: script)
    }

    /// 免密通道：直接以当前用户运行脚本（脚本内逐条 `sudo -n networksetup`），
    /// sudo 依据 sudoers 规则静默放行，不产生任何对话框。
    public static func runPlain(script: String) throws -> PrivilegedResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-s"]
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardInput = inPipe
        task.standardOutput = outPipe
        task.standardError = errPipe
        do {
            try task.run()
        } catch {
            throw ExecutorError.osascriptUnavailable
        }
        inPipe.fileHandleForWriting.write(Data(script.utf8))
        inPipe.fileHandleForWriting.closeFile()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return PrivilegedResult(
            code: task.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    public static func run(script: String) throws -> PrivilegedResult {
        let encoded = Data(script.utf8).base64EncodedString()
        let appleScript =
            "do shell script \"echo \(encoded) | base64 -D | /bin/bash\" " +
            "with administrator privileges"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", appleScript]
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do {
            try task.run()
        } catch {
            throw ExecutorError.osascriptUnavailable
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return PrivilegedResult(
            code: task.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
