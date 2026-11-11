import Foundation

public enum PresetFactory {
    public static func manual(nic: String, device: String, ip: String,
                              mask: String, router: String?,
                              dns: [String]) -> Profile {
        let ipv4 = IPv4Config(mode: "manual", ip: ip, mask: mask, router: router)
        let dnsConfig = dns.isEmpty
            ? nil : DNSConfig(servers: dns, searchDomains: nil)
        let match = ServiceMatch(device: device, serviceName: nic,
                                 mac: nil, optional: true)
        let service = ServiceConfig(match: match, ipv4: ipv4, dns: dnsConfig,
                                    routes: nil, proxy: nil, ipv6: nil)
        let slug = ip.replacingOccurrences(of: ".", with: "-")
        return Profile(id: "custom-\(device)-\(slug)",
                       name: "\(nic) · \(ip)",
                       backend: "direct", locationName: nil,
                       note: "由「自定义 IP」创建，可在 profiles.json 中编辑。",
                       serviceOrder: nil, services: [service],
                       verify: VerifyPolicy.defaults())
    }

    /// 主界面「新增方案」用：允许自定义 id、名称与模式。
    /// 放在 Core 内部构造，避免跨模块访问结构体的成员构造器。
    public static func custom(id: String, name: String, nic: String, device: String,
                              mode: String, ip: String?, mask: String?,
                              router: String?, dns: [String]) -> Profile {
        let ipv4 = IPv4Config(mode: mode, ip: ip, mask: mask, router: router)
        let dnsConfig = dns.isEmpty
            ? nil : DNSConfig(servers: dns, searchDomains: nil)
        let match = ServiceMatch(device: device, serviceName: nic,
                                 mac: nil, optional: true)
        let service = ServiceConfig(match: match, ipv4: ipv4, dns: dnsConfig,
                                    routes: nil, proxy: nil, ipv6: nil)
        return Profile(id: id, name: name, backend: "direct",
                       locationName: nil,
                       note: "在 IP Switcher 主界面新增的方案。",
                       serviceOrder: nil, services: [service],
                       verify: VerifyPolicy.defaults())
    }

    /// 恢复 DHCP 时不动 DNS（dns = nil 表示不下发 DNS 命令）。
    public static func dhcp(nic: String, device: String) -> Profile {
        let ipv4 = IPv4Config(mode: "dhcp", ip: nil, mask: nil, router: nil)
        let match = ServiceMatch(device: device, serviceName: nic,
                                 mac: nil, optional: true)
        let service = ServiceConfig(match: match, ipv4: ipv4, dns: nil,
                                    routes: nil, proxy: nil, ipv6: nil)
        return Profile(id: "dhcp-\(device)",
                       name: "\(nic) · 恢复 DHCP",
                       backend: "direct", locationName: nil,
                       note: "仅将该网卡改回 DHCP，DNS 与其它设置保持不变。",
                       serviceOrder: nil, services: [service],
                       verify: VerifyPolicy.defaults())
    }
}
