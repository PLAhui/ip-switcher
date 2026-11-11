import Foundation

public enum PresetBuilder {
    private struct Key: Hashable {
        let device: String
        let mode: String
        let ip: String
        let mask: String
        let router: String
        let dns: String
    }

    private struct Candidate {
        let nic: String
        let device: String
        let config: IPv4Config
        let dns: DNSConfig?
        let source: String
    }

    /// 把系统位置里的网卡配置拆成「一张网卡 = 一套 IP 预设」。
    /// 只保留 IPv4 + DNS，不带代理 / 静态路由 / IPv6，避免误改用户现有网络环境。
    public static func buildDefault() throws -> ProfileStore {
        let entries = try LocationMigrator.locationEntries()
        let nics = (try? ServiceResolver.list()) ?? []
        var candidates: [Candidate] = []

        for entry in entries {
            for service in entry.services {
                guard let config = service.ipv4,
                      let device = service.match.device, !device.isEmpty else { continue }
                candidates.append(Candidate(
                    nic: service.match.serviceName ?? device,
                    device: device,
                    config: config,
                    dns: service.dns,
                    source: entry.name
                ))
            }
        }

        for nic in nics where !candidates.contains(where: {
            $0.device == nic.device && $0.config.mode == "dhcp"
        }) {
            candidates.append(Candidate(
                nic: nic.name, device: nic.device,
                config: IPv4Config(mode: "dhcp", ip: nil, mask: nil, router: nil),
                dns: DNSConfig(servers: [], searchDomains: nil),
                source: "当前网卡"
            ))
        }

        var seen = Set<Key>()
        var profiles: [Profile] = []
        var usedIDs = Set<String>()
        let deviceOrder = nics.map { $0.device }

        let sorted = candidates.sorted { lhs, rhs in
            let li = deviceOrder.firstIndex(of: lhs.device) ?? Int.max
            let ri = deviceOrder.firstIndex(of: rhs.device) ?? Int.max
            if li != ri { return li < ri }
            if lhs.config.mode != rhs.config.mode { return lhs.config.mode == "dhcp" }
            if lhs.config.mode == "dhcp" {
                let ld = lhs.dns?.servers.isEmpty == false
                let rd = rhs.dns?.servers.isEmpty == false
                if ld != rd { return ld }
            }
            return (lhs.config.ip ?? "") < (rhs.config.ip ?? "")
        }

        let usable = sorted.filter { candidate in
            candidate.config.mode == "manual" || deviceOrder.contains(candidate.device)
        }
        var seenDHCP = Set<String>()
        let deduplicated = usable.filter { candidate in
            guard candidate.config.mode == "dhcp" else { return true }
            return seenDHCP.insert(candidate.device).inserted
        }

        for candidate in deduplicated {
            let dnsServers = candidate.dns?.servers ?? []
            let key = Key(device: candidate.device,
                          mode: candidate.config.mode,
                          ip: candidate.config.ip ?? "",
                          mask: candidate.config.mask ?? "",
                          router: candidate.config.router ?? "",
                          dns: dnsServers.joined(separator: ","))
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            let isDHCP = candidate.config.mode != "manual"
            let addressLabel = isDHCP ? "DHCP 自动获取" : (candidate.config.ip ?? "静态")
            let dnsLabel = dnsServers.isEmpty ? "" : " · DNS " + dnsServers.joined(separator: ",")
            let name = "\(candidate.nic) · \(addressLabel)\(dnsLabel)"

            let slug = (candidate.config.ip ?? "dhcp")
                .replacingOccurrences(of: ".", with: "-")
            let base = "preset-\(candidate.device)-\(slug)"
            var id = base
            var suffix = 2
            while usedIDs.contains(id) {
                id = "\(base)-\(suffix)"
                suffix += 1
            }
            usedIDs.insert(id)

            let match = ServiceMatch(device: candidate.device,
                                     serviceName: candidate.nic,
                                     mac: nil, optional: true)
            let dnsConfig: DNSConfig? =
                (candidate.dns?.servers.isEmpty == false) ? candidate.dns : nil
            let service = ServiceConfig(match: match, ipv4: candidate.config,
                                        dns: dnsConfig, routes: nil,
                                        proxy: nil, ipv6: nil)
            profiles.append(Profile(
                id: id, name: name, backend: "direct",
                locationName: nil,
                note: "来源：\(candidate.source)。已精简为 IPv4 + DNS，不包含代理、静态路由与 IPv6。",
                serviceOrder: nil, services: [service],
                verify: VerifyPolicy.defaults()
            ))
        }

        return ProfileStore(version: ProfileStore.currentVersion,
                            activeProfileID: nil,
                            settings: AppSettings(),
                            profiles: profiles)
    }

    /// 完整导出（含代理 / 静态路由 / IPv6），仅供高级用户手动查阅，App 默认不加载。
    public static func fullLocationExport() throws -> ProfileStore {
        try LocationMigrator.migrate().store
    }
}
