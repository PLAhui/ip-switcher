import Foundation
import IPSwitcherCore

func usage() {
    print("""
    ipswctl - Mac 网卡 IP 配置命令行工具

      init-config [路径]        从系统位置与当前网卡生成单网卡 IP 预设
      list-nics                 列出网卡、设备名与当前 IP
      list [--config 路径]      列出所有 IP 预设
      status                    显示当前生效预设与系统位置
      state                     逐张网卡显示当前 IP、模式与匹配到的方案（只读）
      preview <预设ID> [--config 路径]   打印将执行的命令（不执行、不弹授权）
      script <预设ID> [--config 路径]    打印完整提权脚本（含自动回滚段）
      apply <预设ID>            应用预设（会弹出管理员授权）
      rollback                  恢复最近一次切换前的快照
      import-locations [路径]   完整导出系统位置（含代理/路由，供查阅）
      current-location          显示当前系统位置名
      locations                 列出所有系统位置及其网卡配置（只读）
      location-script <位置名>  打印切换位置将执行的提权脚本（不执行）

    所有写操作都需要管理员授权；preview / list / status / list-nics 均为只读。
    """)
}

func store(from args: [String]) throws -> ProfileStore {
    if let index = args.firstIndex(of: "--config"), args.count > index + 1 {
        let url = URL(fileURLWithPath: args[index + 1])
        return try JSONDecoder().decode(ProfileStore.self, from: Data(contentsOf: url))
    }
    try Store.bootstrap()
    return try Store.load()
}

func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

func currentIP(for service: String) -> String {
    guard let info = try? NetworkSetup.read(["-getinfo", service]) else { return "未知" }
    for line in info.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("IP address:") {
            let value = trimmed.replacingOccurrences(of: "IP address:", with: "")
                .trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? "未分配" : value
        }
    }
    return "未分配"
}

func findProfile(_ store: ProfileStore, _ token: String) -> Profile? {
    store.profiles.first { $0.id == token || $0.name == token }
        ?? store.profiles.first { $0.id.contains(token) || $0.name.contains(token) }
}

func run(_ args: [String]) throws {
    let command = args.first ?? "help"
    switch command {
    case "help", "-h", "--help":
        usage()

    case "init-config":
        let result = try PresetBuilder.buildDefault()
        let path = args.count > 1 ? args[1] : "profiles.json"
        try encoded(result).write(to: URL(fileURLWithPath: path), options: .atomic)
        print("已生成 \(result.profiles.count) 套单网卡 IP 预设 -> \(path)")
        for profile in result.profiles {
            let target = profile.services.first?.match.displayName ?? "-"
            print("  [\(profile.id)] \(profile.name)  → \(target)")
        }

    case "list-nics":
        let nics = try ServiceResolver.list()
        print("当前系统位置：\(NetworkSetup.currentLocation())")
        print("共 \(nics.count) 张可用网卡：")
        for nic in nics {
            print("  \(nic.name) (\(nic.device))  \(currentIP(for: nic.name))")
        }

    case "list":
        let loaded = try store(from: args)
        print("共 \(loaded.profiles.count) 套预设：")
        for profile in loaded.profiles {
            let service = profile.services.first
            let device = service?.match.device ?? "-"
            let mode = service?.ipv4?.mode ?? "-"
            let ip = service?.ipv4?.ip ?? "自动"
            let dns = service?.dns?.servers.joined(separator: ",") ?? "-"
            print("  [\(profile.id)] \(profile.name)")
            print("      网卡=\(device) 模式=\(mode) IP=\(ip) DNS=\(dns)")
        }

    case "status":
        let loaded = try store(from: args)
        let active = Applier.activeProfileID(in: loaded)
        let name = loaded.profiles.first { $0.id == active }?.name ?? "未识别（可能被手动改过）"
        print("系统位置：\(NetworkSetup.currentLocation())")
        print("当前配置：\(name)")
        print("设置：DNS=\(loaded.settings.applyDNS) 代理/路由=\(loaded.settings.applyProxyAndRoutes) 校验=\(loaded.settings.verifyReadBack)")

    case "state":
        let loaded = try store(from: args)
        let nics = try ServiceResolver.list()
        let statuses = CurrentState.snapshot(nics: nics, profiles: loaded.profiles)
        print("系统位置：\(NetworkSetup.currentLocation())  共 \(statuses.count) 张网卡 / \(loaded.profiles.count) 套方案")
        for status in statuses {
            print("  \(status.name) (\(status.device))  \(status.summary)")
            print("      \(status.currentConfigLabel)")
            let plans = loaded.profiles.filter { profile in
                guard profile.isDirect, let first = profile.services.first else {
                    return false
                }
                return first.match.device == status.device
                    || first.match.serviceName == status.name
            }
            for plan in plans {
                let mark = plan.id == status.matchedProfileID ? "✓" : " "
                let mode = plan.services.first?.ipv4?.mode ?? "-"
                let value = mode == "manual"
                    ? (plan.services.first?.ipv4?.ip ?? "?") : "DHCP"
                print("     \(mark) [\(plan.id)] \(plan.name)  → \(value)")
            }
        }

    case "preview":
        guard args.count > 1, let token = args.dropFirst().first else {
            print("用法：ipswctl preview <预设ID>"); return
        }
        let loaded = try store(from: args)
        guard let profile = findProfile(loaded, token) else {
            print("未找到预设：\(token)"); return
        }
        let nics = try ServiceResolver.list()
        let effective = Applier.effectiveServices(
            for: profile, available: nics,
            neutralize: loaded.settings.neutralizeUnlistedServices
        )
        let plan = NetworkSetup.buildCommands(
            services: effective.configs, available: nics,
            applyDNS: loaded.settings.applyDNS,
            applyProxyAndRoutes: loaded.settings.applyProxyAndRoutes,
            applyServiceOrder: loaded.settings.applyServiceOrder,
            serviceOrder: profile.serviceOrder
        )
        print("预设：\(profile.name)")
        print("将执行 \(plan.commands.count) 条命令（只读预览，不会修改系统）：")
        for command in plan.commands {
            print("  networksetup " + command.map(NetworkSetup.shellQuote).joined(separator: " "))
        }
        if !effective.skipped.isEmpty {
            print("跳过（网卡不存在）：\(effective.skipped.joined(separator: "、"))")
        }

    case "script":
        guard args.count > 1, let token = args.dropFirst().first else {
            print("用法：ipswctl script <预设ID>"); return
        }
        let loaded = try store(from: args)
        guard let profile = findProfile(loaded, token) else {
            print("未找到预设：\(token)"); return
        }
        let nics = try ServiceResolver.list()
        let effective = Applier.effectiveServices(
            for: profile, available: nics,
            neutralize: loaded.settings.neutralizeUnlistedServices
        )
        let plan = NetworkSetup.buildCommands(
            services: effective.configs, available: nics,
            applyDNS: loaded.settings.applyDNS,
            applyProxyAndRoutes: loaded.settings.applyProxyAndRoutes
        )
        let before = (try? LocationMigrator.currentServices()) ?? []
        let rollback = Applier.rollbackCommands(
            before: before,
            applyCommands: plan.commands,
            appliedNames: plan.appliedServices,
            affectedDevices: effective.configs.compactMap { $0.match.device },
            available: nics,
            settings: loaded.settings
        )
        print(NetworkSetup.shellScript(apply: plan.commands, rollback: rollback))

    case "apply":
        guard args.count > 1, let token = args.dropFirst().first else {
            print("用法：ipswctl apply <预设ID>"); return
        }
        let loaded = try store(from: args)
        guard let profile = findProfile(loaded, token) else {
            print("未找到预设：\(token)"); return
        }
        let report = Applier.apply(profile: profile, store: loaded)
        print("\(report.title)：\(report.fullMessage)")
        if !report.succeeded { exit(1) }

    case "rollback":
        let report = Applier.rollback()
        print("\(report.title)：\(report.fullMessage)")
        if !report.succeeded { exit(1) }

    case "import-locations":
        let result = try PresetBuilder.fullLocationExport()
        let path = args.count > 1 ? args[1] : "locations-full.json"
        try encoded(result).write(to: URL(fileURLWithPath: path), options: .atomic)
        print("已完整导出 \(result.profiles.count) 个系统位置 -> \(path)")
        print("注意：该文件包含代理与静态路由，仅供查阅，App 默认不加载。")

    case "current-location":
        print(NetworkSetup.currentLocation())

    case "locations":
        let entries = LocationManager.list()
        print("当前位置：\(NetworkSetup.currentLocation())　共 \(entries.count) 个位置")
        for entry in entries {
            print("\n\(entry.isCurrent ? "✓" : " ") \(entry.name)　\(entry.summary)")
            for line in entry.serviceLines { print("    \(line)") }
        }

    case "location-script":
        guard args.count > 1 else {
            print("用法：ipswctl location-script <位置名>"); return
        }
        let name = args.dropFirst().joined(separator: " ")
        guard LocationManager.exists(name) else {
            print("位置「\(name)」不存在"); return
        }
        print(NetworkSetup.shellScript(
            apply: NetworkSetup.locationCommands(name),
            rollback: NetworkSetup.locationCommands(NetworkSetup.currentLocation())))

    default:
        print("未知命令：\(command)\n")
        usage()
    }
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch {
    fputs("错误：\(error.localizedDescription)\n", stderr)
    exit(1)
}
