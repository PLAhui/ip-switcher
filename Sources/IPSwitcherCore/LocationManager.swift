import Foundation

/// 一个系统网络位置的完整快照（离线从 preferences.plist 解析，不需要 root、不会切换位置）。
public struct LocationInfo: Equatable {
    public let name: String
    public let isCurrent: Bool
    public let services: [ServiceConfig]

    public init(name: String, isCurrent: Bool, services: [ServiceConfig]) {
        self.name = name
        self.isCurrent = isCurrent
        self.services = services
    }

    /// 右侧明细列表，每行「标题 + 小字」。
    public var serviceRows: [(title: String, detail: String)] {
        services.map { config in
            let nic = config.match.serviceName ?? "未命名服务"
            let device = config.match.device ?? "?"
            var detail: String
            if config.ipv4?.mode == "manual" {
                detail = "静态 \(config.ipv4?.ip ?? "?") / \(config.ipv4?.mask ?? "?")"
                if let router = config.ipv4?.router, !router.isEmpty {
                    detail += " · 网关 \(router)"
                }
            } else {
                detail = "DHCP 自动获取"
            }
            if let dns = config.dns, !dns.servers.isEmpty {
                detail += " · DNS " + dns.servers.joined(separator: ", ")
            }
            if let routes = config.routes, !routes.isEmpty {
                detail += " · \(routes.count) 条静态路由"
            }
            if config.proxy?.enabled == true { detail += " · 代理开启" }
            return ("\(nic) (\(device))", detail)
        }
    }

    /// 命令行 / 纯文本展示用。
    public var serviceLines: [String] {
        serviceRows.map { "\($0.title)　\($0.detail)" }
    }

    public var summary: String {
        let manual = services.filter { $0.ipv4?.mode == "manual" }.count
        let routes = services.reduce(0) { $0 + ($1.routes?.count ?? 0) }
        let proxy = services.contains { $0.proxy?.enabled == true }
        var parts = ["\(services.count) 项服务", "\(manual) 个静态 IP"]
        if routes > 0 { parts.append("\(routes) 条静态路由") }
        if proxy { parts.append("代理开启") }
        return parts.joined(separator: " · ")
    }
}

public enum LocationManager {
    /// 只读：列出所有位置及其配置，当前位置排在最前。
    public static func list() -> [LocationInfo] {
        let current = NetworkSetup.currentLocation()
        let entries = (try? LocationMigrator.locationEntries()) ?? []
        return entries.map {
            LocationInfo(name: $0.name, isCurrent: $0.name == current,
                         services: $0.services)
        }.sorted { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            return lhs.name < rhs.name
        }
    }

    public static func exists(_ name: String) -> Bool {
        NetworkSetup.listLocations().contains(name)
    }

    /// 创建位置。populate=true 时由系统带出默认网络服务，否则创建一个空位置。
    public static func create(name: String, populate: Bool) -> ApplyReport {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return failure("位置名称不能为空")
        }
        guard !exists(trimmed) else {
            return failure("已存在同名位置「\(trimmed)」")
        }
        var command = ["-createlocation", trimmed]
        if populate { command.append("populate") }
        IPSLog.write("创建系统位置「\(trimmed)」populate=\(populate)")
        return execute([command], title: "位置已创建",
                       message: "已创建位置「\(trimmed)」。它还没有被启用，可在左侧选中后点「切换到此位置」。")
    }

    /// 删除位置。当前正在使用的位置不允许删除。
    public static func delete(name: String) -> ApplyReport {
        let current = NetworkSetup.currentLocation()
        guard name != current else {
            return failure("不能删除当前正在使用的位置「\(name)」。请先切换到其它位置。")
        }
        guard exists(name) else { return failure("位置「\(name)」不存在") }
        IPSLog.write("删除系统位置「\(name)」")
        return execute([["-deletelocation", name]], title: "位置已删除",
                       message: "已删除位置「\(name)」。此操作不可撤销。")
    }

    /// 切换位置会整体替换所有网卡的 IP / DNS / 路由 / 代理，先写快照再执行。
    public static func switchTo(name: String) -> ApplyReport {
        guard exists(name) else { return failure("位置「\(name)」不存在") }
        let report = Applier.switchLocation(name)
        if report.succeeded {
            try? Store.setActiveProfileID(nil)
            IPSLog.write("位置「\(name)」已生效，清空当前生效方案标记")
        }
        return report
    }

    /// 把某个位置拆成「按网卡」的方案写入 profiles.json。
    /// 与工具默认行为一致：只保留 IPv4 + DNS，静态路由 / 代理 / IPv6 不带入。
    @discardableResult
    public static func importAsProfiles(_ location: LocationInfo) throws -> Int {
        var store = try Store.load()
        let existing = Set(store.profiles.map { $0.id })
        let prefix = "loc-\(shortHash(location.name))"
        var added = 0

        for config in location.services {
            guard let device = config.match.device, !device.isEmpty,
                  let nic = config.match.serviceName else { continue }
            let manual = config.ipv4?.mode == "manual"
            let ipLabel = manual
                ? (config.ipv4?.ip ?? "static").replacingOccurrences(of: ".", with: "-")
                : "dhcp"
            let id = "\(prefix)-\(device)-\(ipLabel)"
            guard !existing.contains(id) else { continue }

            let dns = (config.dns?.servers.isEmpty == false) ? config.dns : nil
            let service = ServiceConfig(
                match: ServiceMatch(device: device, serviceName: nic,
                                    mac: config.match.mac, optional: true),
                ipv4: config.ipv4, dns: dns,
                routes: nil, proxy: nil, ipv6: nil)
            let display = manual ? (config.ipv4?.ip ?? "静态 IP") : "DHCP"
            let profile = Profile(
                id: id,
                name: "\(location.name) · \(nic) · \(display)",
                backend: "direct", locationName: location.name,
                note: "从系统位置「\(location.name)」导入；仅保留 IPv4 与 DNS，静态路由 / 代理 / IPv6 未包含。",
                serviceOrder: nil, services: [service],
                verify: VerifyPolicy.defaults())
            store.profiles.append(profile)
            added += 1
        }

        if added > 0 {
            _ = Store.backupCurrent()
            try Store.save(store)
            IPSLog.write("从位置「\(location.name)」导入 \(added) 套方案")
        }
        return added
    }

    // MARK: - 内部

    private static func execute(_ commands: [[String]], title: String,
                                message: String) -> ApplyReport {
        do {
            let result = try PrivilegedExecutor.run(apply: commands)
            if result.cancelled {
                return ApplyReport(succeeded: false, title: "已取消",
                                   message: "你取消了管理员授权，系统位置未改动。",
                                   commandCount: commands.count, skipped: [],
                                   neutralized: [], rolledBack: false)
            }
            let ok = result.succeeded
            IPSLog.write("位置操作结束 code=\(result.code) err=\(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            return ApplyReport(
                succeeded: ok, title: ok ? title : "操作失败",
                message: ok ? message : result.stderr,
                commandCount: commands.count, skipped: [],
                neutralized: [], rolledBack: false)
        } catch {
            return ApplyReport(succeeded: false, title: "操作失败",
                               message: error.localizedDescription,
                               commandCount: commands.count, skipped: [],
                               neutralized: [], rolledBack: false)
        }
    }

    private static func failure(_ message: String) -> ApplyReport {
        ApplyReport(succeeded: false, title: "无法执行",
                    message: message, commandCount: 0, skipped: [],
                    neutralized: [], rolledBack: false)
    }

    /// FNV-1a，生成稳定且不含中文的位置 ID 前缀。
    private static func shortHash(_ text: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 16777619
        }
        return String(format: "%08x", hash & 0xffff_ffff)
    }
}
