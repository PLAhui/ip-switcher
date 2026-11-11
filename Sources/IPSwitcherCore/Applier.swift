import Foundation

public struct ApplyReport {
    public let succeeded: Bool
    public let title: String
    public let message: String
    public let commandCount: Int
    public let skipped: [String]
    public let neutralized: [String]
    public let rolledBack: Bool

    public init(succeeded: Bool, title: String, message: String,
                commandCount: Int, skipped: [String], neutralized: [String],
                rolledBack: Bool) {
        self.succeeded = succeeded
        self.title = title
        self.message = message
        self.commandCount = commandCount
        self.skipped = skipped
        self.neutralized = neutralized
        self.rolledBack = rolledBack
    }

    public var fullMessage: String {
        var parts = [message]
        if !skipped.isEmpty {
            parts.append("未找到而跳过：\(skipped.joined(separator: "、"))")
        }
        if !neutralized.isEmpty {
            parts.append("已中性化：\(neutralized.joined(separator: "、"))")
        }
        return parts.joined(separator: "\n\n")
    }
}

public enum Applier {
    private static func now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func norm(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func neutralConfig(for service: ResolvedService) -> ServiceConfig {
        ServiceConfig(
            match: ServiceMatch(device: service.device, serviceName: service.name,
                                mac: nil, optional: true),
            ipv4: IPv4Config(mode: "dhcp", ip: nil, mask: nil, router: nil),
            dns: DNSConfig(servers: [], searchDomains: nil),
            routes: [],
            proxy: ProxyConfig(enabled: false, host: nil, port: nil, bypass: nil),
            ipv6: "automatic"
        )
    }

    public static func effectiveServices(for profile: Profile,
                                         available: [ResolvedService],
                                         neutralize: Bool)
        -> (configs: [ServiceConfig], skipped: [String], neutralized: [String]) {
        var configs: [ServiceConfig] = []
        var skipped: [String] = []
        var neutralized: [String] = []
        var used = Set<String>()

        for var config in profile.services {
            guard let target = ServiceResolver.resolve(config.match, in: available) else {
                skipped.append(config.match.displayName +
                               (config.match.device.map { " (\($0))" } ?? ""))
                continue
            }
            if used.contains(target.name) { continue }
            used.insert(target.name)
            config.match.device = target.device
            config.match.serviceName = target.name
            configs.append(config)
        }

        if neutralize {
            for service in available where !used.contains(service.name) {
                configs.append(neutralConfig(for: service))
                neutralized.append("\(service.name) (\(service.device))")
            }
        }
        return (configs, skipped, neutralized)
    }

    /// 回滚只涉及本次真正改动过的网卡与字段，避免误触其它网卡（例如让 Wi-Fi 重新 DHCP 续租）。
    public static func rollbackCommands(before: [ServiceConfig],
                                        applyCommands: [[String]]?,
                                        appliedNames: [String],
                                        affectedDevices: [String],
                                        available: [ResolvedService],
                                        settings: AppSettings) -> [[String]] {
        let names = Set(appliedNames)
        let devices = Set(affectedDevices)
        let isFull = names.isEmpty && devices.isEmpty

        var kindsByService: [String: Set<String>] = [:]
        if let applyCommands = applyCommands {
            for command in applyCommands where command.count >= 2 {
                let kind: String?
                switch command[0] {
                case "-setmanual", "-setmanualwithdhcprouter", "-setdhcp",
                     "-setbootp", "-setv4off":
                    kind = "ipv4"
                case "-setdnsservers", "-setsearchdomains":
                    kind = "dns"
                case "-setadditionalroutes":
                    kind = "routes"
                case "-setwebproxy", "-setsecurewebproxy", "-setsocksfirewallproxy",
                     "-setwebproxystate", "-setsecurewebproxystate",
                     "-setsocksfirewallproxystate", "-setautoproxystate",
                     "-setproxybypassdomains":
                    kind = "proxy"
                case "-setv6off", "-setv6automatic", "-setv6manual":
                    kind = "ipv6"
                default:
                    kind = nil
                }
                if let kind = kind {
                    kindsByService[command[1], default: []].insert(kind)
                }
            }
        }

        var trimmed: [ServiceConfig] = []
        for var service in before {
            let name = service.match.serviceName ?? ""
            if !isFull {
                let hit = names.contains(name)
                    || devices.contains(service.match.device ?? "")
                guard hit else { continue }
            }
            if let applyCommands = applyCommands, !applyCommands.isEmpty {
                let kinds = kindsByService[name] ?? []
                if !kinds.contains("ipv4") { service.ipv4 = nil }
                if !kinds.contains("dns") { service.dns = nil }
                if !kinds.contains("routes") { service.routes = nil }
                if !kinds.contains("proxy") { service.proxy = nil }
                if !kinds.contains("ipv6") { service.ipv6 = nil }
            } else {
                if !settings.applyDNS { service.dns = nil }
                if !settings.applyProxyAndRoutes {
                    service.routes = nil
                    service.proxy = nil
                    service.ipv6 = nil
                }
            }
            trimmed.append(service)
        }
        return NetworkSetup.buildCommands(
            services: trimmed, available: available,
            applyDNS: settings.applyDNS,
            applyProxyAndRoutes: settings.applyProxyAndRoutes
        ).commands
    }

    public static func apply(profile: Profile, store: ProfileStore) -> ApplyReport {
        IPSLog.write("开始应用配置「\(profile.name)」backend=\(profile.backend)")

        guard let available = try? ServiceResolver.list(), !available.isEmpty else {
            return ApplyReport(succeeded: false, title: "切换失败",
                               message: "无法读取当前网络服务列表。", commandCount: 0,
                               skipped: [], neutralized: [], rolledBack: false)
        }

        if !profile.isDirect {
            return switchLocation(profile.locationName ?? profile.name)
        }

        let effective = effectiveServices(
            for: profile, available: available,
            neutralize: store.settings.neutralizeUnlistedServices
        )
        let plan = NetworkSetup.buildCommands(
            services: effective.configs, available: available,
            applyDNS: store.settings.applyDNS,
            applyProxyAndRoutes: store.settings.applyProxyAndRoutes,
            applyServiceOrder: store.settings.applyServiceOrder,
            serviceOrder: profile.serviceOrder
        )
        guard !plan.commands.isEmpty else {
            return ApplyReport(succeeded: false, title: "无可执行的配置",
                               message: "没有匹配到任何当前存在的网卡。", commandCount: 0,
                               skipped: effective.skipped,
                               neutralized: effective.neutralized, rolledBack: false)
        }

        let before = (try? LocationMigrator.currentServices()) ?? []
        let affectedNames = plan.appliedServices
        let affectedDevices = effective.configs.compactMap { $0.match.device }
        try? Store.writeSnapshot(ConfigSnapshot(
            createdAt: now(),
            reason: "应用「\(profile.name)」之前",
            services: before, serviceOrder: nil,
            affectedServices: affectedNames,
            affectedDevices: affectedDevices,
            applyCommands: plan.commands
        ))

        let rollbackCommands = Self.rollbackCommands(
            before: before,
            applyCommands: plan.commands,
            appliedNames: affectedNames,
            affectedDevices: affectedDevices,
            available: available,
            settings: store.settings
        )
        let result: PrivilegedResult
        do {
            result = try PrivilegedExecutor.run(apply: plan.commands,
                                                rollback: rollbackCommands)
        } catch {
            IPSLog.write("提权执行异常：\(error.localizedDescription)")
            return ApplyReport(succeeded: false, title: "切换失败",
                               message: error.localizedDescription,
                               commandCount: plan.commands.count,
                               skipped: effective.skipped,
                               neutralized: effective.neutralized, rolledBack: false)
        }
        IPSLog.write("提权执行结束 code=\(result.code) out=\(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) err=\(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")

        if result.cancelled {
            return ApplyReport(succeeded: false, title: "已取消",
                               message: "你取消了管理员授权，网络配置未改动。",
                               commandCount: plan.commands.count,
                               skipped: effective.skipped,
                               neutralized: effective.neutralized, rolledBack: false)
        }
        if !result.succeeded {
            let didRollback = result.stderr.contains("IPSW_ROLLBACK_START")
            return ApplyReport(
                succeeded: false, title: "切换失败，已尝试回滚",
                message: didRollback
                    ? "部分 networksetup 命令执行失败，已在同一授权会话内自动恢复切换前配置。\n\n\(result.stderr.prefix(600))"
                    : "命令执行失败：\n\(result.stderr.prefix(600))",
                commandCount: plan.commands.count,
                skipped: effective.skipped, neutralized: effective.neutralized,
                rolledBack: didRollback
            )
        }

        Thread.sleep(forTimeInterval: 0.8)
        let verification = verify(configs: effective.configs,
                                  settings: store.settings)
        if !verification.ok {
            IPSLog.write("回读校验未通过：\(verification.detail)")
            let message = """
            配置命令已执行，但回读校验发现差异：\(verification.detail)

            这通常是系统偏好写入延迟或某项参数不受 networksetup 支持。可用菜单中的「恢复上次快照」手动回滚。
            """
            return ApplyReport(succeeded: false, title: "配置已写入，校验有差异",
                               message: message, commandCount: plan.commands.count,
                               skipped: effective.skipped,
                               neutralized: effective.neutralized, rolledBack: false)
        }

        try? Store.setActiveProfileID(profile.id)
        IPSLog.write("配置「\(profile.name)」应用成功，共 \(plan.commands.count) 条命令")
        return ApplyReport(
            succeeded: true, title: "切换成功",
            message: "已应用「\(profile.name)」，共执行 \(plan.commands.count) 条命令，回读校验通过。切换前配置已存为快照。",
            commandCount: plan.commands.count,
            skipped: effective.skipped, neutralized: effective.neutralized,
            rolledBack: false
        )
    }

    public static func switchLocation(_ name: String) -> ApplyReport {
        let before = (try? LocationMigrator.currentServices()) ?? []
        try? Store.writeSnapshot(ConfigSnapshot(
            createdAt: now(),
            reason: "切换系统位置「\(name)」之前",
            services: before, serviceOrder: nil,
            affectedServices: nil, affectedDevices: nil,
            applyCommands: nil
        ))
        do {
            // 切换失败时在同一个授权会话内切回原位置，避免停留在半切换状态。
            let rollback = NetworkSetup.locationCommands(NetworkSetup.currentLocation())
            let result = try PrivilegedExecutor.run(
                apply: NetworkSetup.locationCommands(name), rollback: rollback)
            if result.cancelled {
                return ApplyReport(succeeded: false, title: "已取消",
                                   message: "你取消了管理员授权，位置未切换。",
                                   commandCount: 1, skipped: [], neutralized: [],
                                   rolledBack: false)
            }
            IPSLog.write("切换系统位置「\(name)」code=\(result.code)")
            return ApplyReport(
                succeeded: result.succeeded,
                title: result.succeeded ? "位置已切换" : "位置切换失败",
                message: result.succeeded
                    ? "系统位置已切换为「\(name)」。注意：这会整体替换所有网卡配置，覆盖 App 中已应用的 profile。"
                    : result.stderr,
                commandCount: 1, skipped: [], neutralized: [], rolledBack: false
            )
        } catch {
            return ApplyReport(succeeded: false, title: "位置切换失败",
                               message: error.localizedDescription, commandCount: 1,
                               skipped: [], neutralized: [], rolledBack: false)
        }
    }

    public static func rollback() -> ApplyReport {
        guard let snapshot = try? Store.readSnapshot() else {
            return ApplyReport(succeeded: false, title: "无法回滚",
                               message: "没有找到切换前的快照文件。", commandCount: 0,
                               skipped: [], neutralized: [], rolledBack: false)
        }
        guard let available = try? ServiceResolver.list() else {
            return ApplyReport(succeeded: false, title: "无法回滚",
                               message: "无法读取当前网络服务列表。", commandCount: 0,
                               skipped: [], neutralized: [], rolledBack: false)
        }
        let settings = (try? Store.load())?.settings ?? AppSettings()
        let commands = rollbackCommands(
            before: snapshot.services,
            applyCommands: snapshot.applyCommands,
            appliedNames: snapshot.affectedServices ?? [],
            affectedDevices: snapshot.affectedDevices ?? [],
            available: available,
            settings: settings
        )
        do {
            let result = try PrivilegedExecutor.run(apply: commands)
            let ok = result.succeeded
            if ok { try? Store.setActiveProfileID(nil) }
            IPSLog.write("手动回滚 code=\(result.code)")
            return ApplyReport(
                succeeded: ok, title: ok ? "已恢复快照" : "回滚失败",
                message: ok
                    ? "已恢复 \(snapshot.createdAt) 保存的配置（\(snapshot.reason)）。"
                    : result.stderr,
                commandCount: commands.count, skipped: [],
                neutralized: [], rolledBack: ok
            )
        } catch {
            return ApplyReport(succeeded: false, title: "回滚失败",
                               message: error.localizedDescription, commandCount: 0,
                               skipped: [], neutralized: [], rolledBack: false)
        }
    }

    private static func verify(configs: [ServiceConfig], settings: AppSettings)
        -> (ok: Bool, detail: String) {
        guard settings.verifyReadBack else { return (true, "已跳过回读校验") }
        var problems: [String] = []

        for attempt in 0..<2 {
            guard let current = try? LocationMigrator.currentServices() else {
                return (false, "无法读取系统网络配置")
            }
            problems = []
            for expected in configs {
                let actual = current.first { item in
                    if let device = expected.match.device, !device.isEmpty {
                        return item.match.device == device
                    }
                    return item.match.serviceName == expected.match.serviceName
                }
                let label = expected.match.displayName
                guard let actual = actual else {
                    problems.append("\(label) 不在当前位置中")
                    continue
                }
                if let want = expected.ipv4 {
                    if norm(actual.ipv4?.mode) != norm(want.mode) {
                        problems.append("\(label) IPv4 模式")
                    }
                    if want.mode == "manual" {
                        if norm(actual.ipv4?.ip) != norm(want.ip) {
                            problems.append("\(label) IP")
                        }
                        if norm(actual.ipv4?.mask) != norm(want.mask) {
                            problems.append("\(label) 子网掩码")
                        }
                    }
                }
                if settings.applyDNS, let want = expected.dns,
                   (actual.dns?.servers ?? []) != want.servers {
                    problems.append("\(label) DNS")
                }
                if settings.applyProxyAndRoutes {
                    if let want = expected.routes,
                       (actual.routes ?? []).count != want.count {
                        problems.append("\(label) 静态路由")
                    }
                    if let want = expected.proxy,
                       (actual.proxy?.enabled ?? false) != want.enabled {
                        problems.append("\(label) 代理开关")
                    }
                }
            }
            if problems.isEmpty { return (true, "回读校验通过") }
            if attempt == 0 { Thread.sleep(forTimeInterval: 1.0) }
        }
        return (false, Array(Set(problems)).sorted().joined(separator: "、"))
    }

    public static func activeProfileID(in store: ProfileStore) -> String? {
        guard let current = try? LocationMigrator.currentServices() else {
            return store.activeProfileID
        }
        var bestID: String?
        var bestScore = Int.min

        for profile in store.profiles where profile.isDirect {
            var score = 0
            for expected in profile.services {
                let actual = current.first { item in
                    if let device = expected.match.device, !device.isEmpty {
                        return item.match.device == device
                    }
                    return item.match.serviceName == expected.match.serviceName
                }
                guard let actual = actual else { continue }
                if let want = expected.ipv4 {
                    score += norm(actual.ipv4?.mode) == norm(want.mode) ? 1 : -2
                    if want.mode == "manual" {
                        score += norm(actual.ipv4?.ip) == norm(want.ip) ? 1 : -2
                    }
                }
                if let want = expected.dns {
                    score += (actual.dns?.servers ?? []) == want.servers ? 1 : -2
                }
                if let want = expected.routes {
                    score += (actual.routes ?? []).count == want.count ? 1 : -2
                }
                if let want = expected.proxy {
                    score += (actual.proxy?.enabled ?? false) == want.enabled ? 1 : -2
                }
            }
            if score > bestScore {
                bestScore = score
                bestID = profile.id
            }
        }
        return bestScore > 0 ? bestID : store.activeProfileID
    }
}
