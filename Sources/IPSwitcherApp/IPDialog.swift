import IPSwitcherCore

/// IPv4 格式校验（供 Web 界面的方案保存与位置导入使用）。
enum IPDialog {
    static func isValidIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let number = Int(part), number >= 0, number <= 255,
                  part.allSatisfy({ $0.isNumber }) else { return false }
            return true
        }
    }
}
