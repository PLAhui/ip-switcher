import Foundation

public struct MigrationResult {
    public let store: ProfileStore
    public let warnings: [String]
}

public enum LocationMigrator {
    public static let preferencesPath =
        "/Library/Preferences/SystemConfiguration/preferences.plist"

    public enum MigrationError: Error, LocalizedError {
        case plutilFailed(String)
        case invalidPlist

        public var errorDescription: String? {
            switch self {
            case .plutilFailed(let detail): return "读取系统网络配置失败：\(detail)"
            case .invalidPlist: return "系统网络配置格式无法解析"
            }
        }
    }

    public static func readPreferences() throws -> [String: Any] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        task.arguments = ["-convert", "json", "-o", "-", preferencesPath]
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        try task.run()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            let detail = String(data: errData, encoding: .utf8) ?? "unknown error"
            throw MigrationError.plutilFailed(detail)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw MigrationError.invalidPlist
        }
        return root
    }

    private static func dict(_ value: Any?) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }

    private static func networkServices(_ root: [String: Any]) -> [String: [String: Any]] {
        var result: [String: [String: Any]] = [:]
        for (key, value) in dict(root["NetworkServices"]) {
            if let entry = value as? [String: Any] { result[key] = entry }
        }
        return result
    }

    private static func allSets(_ root: [String: Any]) -> [String: [String: Any]] {
        var result: [String: [String: Any]] = [:]
        for (key, value) in dict(root["Sets"]) {
            if let entry = value as? [String: Any] { result[key] = entry }
        }
        return result
    }

    private static func currentSetUID(_ root: [String: Any]) -> String? {
        guard let path = root["CurrentSet"] as? String else { return nil }
        return (path as NSString).lastPathComponent
    }

    public static func currentLocationName() throws -> String {
        let root = try readPreferences()
        guard let uid = currentSetUID(root),
              let set = allSets(root)[uid] else { return "自动" }
        return set["UserDefinedName"] as? String ?? "自动"
    }

    public static func locationNames() throws -> [String] {
        let root = try readPreferences()
        return allSets(root).values.compactMap { $0["UserDefinedName"] as? String }.sorted()
    }

    public static func serviceOrder(in set: [String: Any],
                                    root: [String: Any]) -> [String] {
        let global = dict(dict(set["Network"])["Global"])
        let uuids = dict(global["IPv4"])["ServiceOrder"] as? [String] ?? []
        let all = networkServices(root)
        return uuids.compactMap { uuid in
            dict(all[uuid]?["Interface"])["UserDefinedName"] as? String
        }
    }

    public static func services(in set: [String: Any], root: [String: Any],
                                warnings: inout [String]) -> [ServiceConfig] {
        let all = networkServices(root)
        let serviceKeys = dict(dict(set["Network"])["Service"])
        var result: [ServiceConfig] = []

        for uuid in serviceKeys.keys.sorted() {
            guard let service = all[uuid] else { continue }
            let iface = dict(service["Interface"])
            guard let name = iface["UserDefinedName"] as? String,
                  let device = iface["DeviceName"] as? String else {
                warnings.append("跳过无硬件接口的服务 \(uuid)（VPN/虚拟服务，无法按名称定位）")
                continue
            }

            let v4 = dict(service["IPv4"])
            let method = v4["ConfigMethod"] as? String ?? "DHCP"
            let ipv4: IPv4Config
            if method == "Manual" {
                let addresses = v4["Addresses"] as? [String] ?? []
                let masks = v4["SubnetMasks"] as? [String] ?? []
                ipv4 = IPv4Config(mode: "manual",
                                  ip: addresses.first,
                                  mask: masks.first,
                                  router: v4["Router"] as? String)
            } else {
                ipv4 = IPv4Config(mode: "dhcp", ip: nil, mask: nil, router: nil)
            }

            let dnsDict = dict(service["DNS"])
            let dns = DNSConfig(
                servers: dnsDict["ServerAddresses"] as? [String] ?? [],
                searchDomains: dnsDict["SearchDomains"] as? [String]
            )

            var routes: [Route] = []
            for entry in v4["AdditionalRoutes"] as? [[String: Any]] ?? [] {
                routes.append(Route(
                    dest: entry["DestinationAddress"] as? String ?? "",
                    mask: entry["SubnetMask"] as? String ?? "",
                    gateway: entry["GatewayAddress"] as? String ?? ""
                ))
            }

            let proxies = dict(service["Proxies"])
            let proxyEnabled = [proxies["HTTPEnable"], proxies["HTTPSEnable"],
                                proxies["SOCKSEnable"]].contains { ($0 as? Int) == 1 }
            let proxyHost = [proxies["HTTPProxy"], proxies["HTTPSProxy"],
                             proxies["SOCKSProxy"]].compactMap { $0 as? String }.first
            let proxyPort = [proxies["HTTPPort"], proxies["HTTPSPort"],
                             proxies["SOCKSPort"]].compactMap { $0 as? Int }.first { $0 > 0 }
            let proxy = ProxyConfig(
                enabled: proxyEnabled,
                host: proxyHost,
                port: proxyPort,
                bypass: proxies["ExceptionsList"] as? [String]
            )

            let v6Method = (dict(service["IPv6"])["ConfigMethod"] as? String ?? "Automatic").lowercased()
            let ipv6 = v6Method == "automatic" ? "automatic" : (v6Method == "off" ? "off" : "automatic")

            let match = ServiceMatch(device: device,
                                     serviceName: name,
                                     mac: iface["EthernetAddress"] as? String,
                                     optional: true)
            result.append(ServiceConfig(match: match, ipv4: ipv4, dns: dns,
                                        routes: routes, proxy: proxy, ipv6: ipv6))
        }

        let order = serviceOrder(in: set, root: root)
        return result.sorted { lhs, rhs in
            let li = order.firstIndex(of: lhs.match.displayName) ?? Int.max
            let ri = order.firstIndex(of: rhs.match.displayName) ?? Int.max
            return li < ri
        }
    }

    public static func currentServices() throws -> [ServiceConfig] {
        let root = try readPreferences()
        guard let uid = currentSetUID(root), let set = allSets(root)[uid] else { return [] }
        var warnings: [String] = []
        return services(in: set, root: root, warnings: &warnings)
    }

    public static func locationEntries() throws -> [(name: String, services: [ServiceConfig])] {
        let root = try readPreferences()
        var warnings: [String] = []
        return allSets(root).map { entry in
            let name = entry.value["UserDefinedName"] as? String ?? entry.key
            return (name: name,
                    services: services(in: entry.value, root: root, warnings: &warnings))
        }.sorted { $0.name < $1.name }
    }

    public static func migrate() throws -> MigrationResult {
        let root = try readPreferences()
        let sets = allSets(root)
        let currentUID = currentSetUID(root)
        var warnings: [String] = []
        var items: [(uid: String, profile: Profile)] = []

        for (uid, set) in sets {
            let name = set["UserDefinedName"] as? String ?? uid
            let configs = services(in: set, root: root, warnings: &warnings)
            let order = serviceOrder(in: set, root: root)
            let profile = Profile(
                id: "loc-" + String(uid.prefix(8)).lowercased(),
                name: name,
                backend: "direct",
                locationName: name,
                note: "由系统网络位置「\(name)」迁移；来源 Set \(uid)。IP/路由/DNS/代理均为原始值，可按需编辑。",
                serviceOrder: order,
                services: configs,
                verify: VerifyPolicy.defaults()
            )
            items.append((uid: uid, profile: profile))
        }

        items.sort { lhs, rhs in
            let lc = lhs.uid == currentUID ? 0 : 1
            let rc = rhs.uid == currentUID ? 0 : 1
            if lc != rc { return lc < rc }
            return lhs.profile.name < rhs.profile.name
        }

        let store = ProfileStore(
            version: ProfileStore.currentVersion,
            activeProfileID: items.first?.profile.id,
            settings: AppSettings(),
            profiles: items.map { $0.profile }
        )
        return MigrationResult(store: store, warnings: warnings)
    }
}
