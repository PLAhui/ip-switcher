import IPSwitcherCore

/// 给界面显示的一行方案摘要。
enum ProfileEditor {
    static func detail(_ profile: Profile) -> String {
        guard let service = profile.services.first else { return "无可用的网卡配置" }
        guard let ipv4 = service.ipv4 else { return "未设置 IPv4" }
        if ipv4.mode != "manual" {
            return "DHCP 自动获取" +
                (service.dns?.servers.isEmpty == false
                 ? " · DNS " + (service.dns?.servers.joined(separator: ", ") ?? "")
                 : "")
        }
        var parts = ["静态 \(ipv4.ip ?? "?") / \(ipv4.mask ?? "?")"]
        if let router = ipv4.router, !router.isEmpty { parts.append("网关 \(router)") }
        if let dns = service.dns, !dns.servers.isEmpty {
            parts.append("DNS " + dns.servers.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }
}
