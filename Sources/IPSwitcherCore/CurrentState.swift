import Foundation

/// 一张网卡的当前状态，以及它正在使用哪套方案。
/// 判定基于系统真实配置（preferences.plist + networksetup -getinfo），
/// 而不是「上次点了哪个按钮」，所以在系统设置里手动改了 IP 也能如实反映。
public struct NICStatus: Equatable {
    public let device: String
    public let name: String
    public let hardwarePort: String
    public let liveIP: String
    public let mode: String
    public let dns: [String]
    public let matchedProfileID: String?
    public let matchedProfileName: String?

    public var modeLabel: String {
        switch mode {
        case "manual": return "手动 IP"
        case "dhcp": return "DHCP"
        case "off": return "已关闭"
        default: return "未知"
        }
    }

    public var currentConfigLabel: String {
        if let matchedProfileName {
            return "当前方案：\(matchedProfileName)"
        }
        switch mode {
        case "dhcp":
            return "当前：DHCP · \(liveIP) · 无匹配方案"
        case "manual":
            return "当前：手动 \(liveIP) · 无匹配方案"
        default:
            return "当前：\(liveIP) · 状态未识别"
        }
    }

    public var summary: String {
        dns.isEmpty ? "\(modeLabel) · \(liveIP)" : "\(modeLabel) · \(liveIP) · DNS \(dns.joined(separator: ","))"
    }
}

public enum CurrentState {
    public static func snapshot(nics: [ResolvedService],
                                profiles: [Profile],
                                activeProfileID: String? = nil) -> [NICStatus] {
        let configs = (try? LocationMigrator.currentServices()) ?? []
        return nics.map { nic in
            let actual = configs.first { cfg in
                if let device = cfg.match.device, !device.isEmpty, device == nic.device {
                    return true
                }
                return cfg.match.serviceName == nic.name
            }
            let mode = actual?.ipv4?.mode ?? "unknown"
            let dns = actual?.dns?.servers ?? []
            let candidates = profiles.filter { profile in
                guard profile.isDirect, let first = profile.services.first else {
                    return false
                }
                return first.match.device == nic.device
                    || first.match.serviceName == nic.name
            }
            let contentMatch = candidates.first { profile in
                guard let want = profile.services.first else { return false }
                return matches(want, actual)
            }
            // 多套方案内容完全相同时，只按内容匹配会永远命中第一套，
            // 导致刚点的那套不显示 ✓。优先承认「最近一次成功应用」的方案。
            let matched: Profile? = {
                if let activeProfileID,
                   let active = candidates.first(where: { $0.id == activeProfileID }),
                   let want = active.services.first,
                   matches(want, actual) {
                    return active
                }
                return contentMatch
            }()
            return NICStatus(
                device: nic.device,
                name: nic.name,
                hardwarePort: nic.hardwarePort,
                liveIP: NetworkSetup.liveIP(nic.name),
                mode: mode,
                dns: dns,
                matchedProfileID: matched?.id,
                matchedProfileName: matched?.name
            )
        }
    }

    /// 方案的 IPv4 与（可选）DNS 是否与系统当前配置一致。
    /// routes / proxy / ipv6 默认不下发，不参与判定。
    private static func matches(_ want: ServiceConfig, _ actual: ServiceConfig?) -> Bool {
        guard let actual,
              let wantV4 = want.ipv4,
              let actualV4 = actual.ipv4 else { return false }
        guard norm(wantV4.mode) == norm(actualV4.mode) else { return false }
        if wantV4.mode == "manual" {
            guard norm(wantV4.ip) == norm(actualV4.ip),
                  norm(wantV4.mask) == norm(actualV4.mask) else { return false }
            // 方案没写网关 = 「不改动网关」。networksetup -setmanual 传空网关时
            // 系统常常保留旧 Router，这里不拿旧值去否定匹配，否则会误报「无匹配方案」。
            if !norm(wantV4.router).isEmpty {
                guard norm(wantV4.router) == norm(actualV4.router) else { return false }
            }
        }
        if let wantDNS = want.dns, !wantDNS.servers.isEmpty {
            guard wantDNS.servers == (actual.dns?.servers ?? []) else { return false }
        }
        return true
    }

    private static func norm(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
