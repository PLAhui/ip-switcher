import AppKit
import WebKit
import IPSwitcherCore

/// 精致界面的承载窗口：前端是纯 HTML/CSS/JS（Resources/web/index.html），
/// 这里只负责把已验证的 Core 能力桥接给页面，不重写任何系统操作逻辑。
/// 前端与 Tauri 通用 —— 将来换壳只需替换这一层。
final class WebWindowController: NSWindowController, NSWindowDelegate,
                                 WKScriptMessageHandler, WKNavigationDelegate {
    private var webView: WKWebView!
    private var busy = false
    private var lastMessage = ""
    private var didSelfTest = false
    private var sampler: TrafficSampler?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable,
                        .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "IP Switcher"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(calibratedWhite: 0.96, alpha: 1)
        window.minSize = NSSize(width: 900, height: 580)
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        setupWebView(in: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupWebView(in window: NSWindow) {
        let config = WKWebViewConfiguration()
        // 控制器常驻应用生命周期，这里的强引用不会造成实际问题。
        config.userContentController.add(self, name: "ipsw")
        let view = WKWebView(frame: .zero, configuration: config)
        view.autoresizingMask = [.width, .height]
        view.navigationDelegate = self
        window.contentView = view
        webView = view

        let monitor = TrafficSampler()
        monitor.onUpdate = { [weak self] payload in
            self?.pushTraffic(payload)
        }
        sampler = monitor
        loadPage()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 页面就绪后再开始采样，避免首帧推给一个还没定义 __ipswTraffic 的文档。
        let devices = (try? ServiceResolver.list().map { $0.device }) ?? []
        sampler?.start(devices: devices)
        pushState()
    }

    /// 定位前端入口：优先 App 包内资源；直接跑编译产物（swift run / .build/debug）时
    /// 回退到源码树的 Resources/web，保证开发态也能正常渲染。
    private func locatePage() -> URL? {
        if let url = Bundle.main.url(forResource: "index", withExtension: "html",
                                     subdirectory: "web") {
            return url
        }
        var candidates: [URL] = []
        if let root = ProcessInfo.processInfo.environment["IPSW_WEB_ROOT"],
           !root.isEmpty {
            candidates.append(URL(fileURLWithPath: root).appendingPathComponent("index.html"))
        }
        if let executable = Bundle.main.executableURL {
            let base = executable.deletingLastPathComponent()
            // 已组装 .app：MacOS/../Resources/web
            candidates.append(base.appendingPathComponent("../Resources/web/index.html")
                .standardizedFileURL)
            // 源码直跑：.build/debug/../../Resources/web
            candidates.append(base.appendingPathComponent("../../Resources/web/index.html")
                .standardizedFileURL)
        }
        // 从仓库根目录运行
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/web/index.html"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func loadPage() {
        guard let page = locatePage() else {
            IPSLog.write("界面资源缺失：找不到 Resources/web/index.html")
            webView.loadHTMLString(
                "<body style='font-family:-apple-system;padding:40px'>界面资源缺失，请重新运行 ./build.sh</body>",
                baseURL: nil)
            return
        }
        IPSLog.write("加载界面资源：\(page.path)")
        webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    }

    // MARK: - 窗口

    func present() {
        guard let window else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        IPSLog.write("主界面已打开（WebView）")
        pushState()
    }

    func refresh() { pushState() }

    func windowWillClose(_ notification: Notification) {
        // 退出交给 AppDelegate.applicationShouldTerminateAfterLastWindowClosed，
        // 这里只记录日志，不在关闭回调里手动 terminate。
        sampler?.stop()
        IPSLog.write("主窗口已关闭")
    }

    // MARK: - Swift → JS

    private func evaluate(_ script: String) {
        webView.evaluateJavaScript(script) { _, error in
            if let error {
                IPSLog.write("JS 执行失败：\(error.localizedDescription)")
            }
        }
    }

    private func pushState(message: String? = nil) {
        let msg = message ?? lastMessage
        let isBusy = busy
        DispatchQueue.global(qos: .utility).async {
            let state = Self.buildState(message: msg, busy: isBusy)
            guard let data = try? JSONSerialization.data(withJSONObject: state),
                  let text = String(data: data, encoding: .utf8) else { return }
            let encoded = Data(text.utf8).base64EncodedString()
            DispatchQueue.main.async {
                let devices = (state["nics"] as? [[String: Any]])?
                    .compactMap { $0["device"] as? String } ?? []
                self.sampler?.updateDevices(devices)
                self.evaluate("window.__ipswRender(window.__b64json('\(encoded)'))")
                self.applySelfTest()
            }
        }
    }

    /// 无人值守界面自检：仅 IPSW_SELFTEST=web-* 时生效，正常使用不触发。
    private func applySelfTest() {
        guard !didSelfTest else { return }
        let test = ProcessInfo.processInfo.environment["IPSW_SELFTEST"] ?? ""
        guard test.hasPrefix("web-") else { return }
        didSelfTest = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            switch test {
            case "web-locations":
                self.evaluate("window.__ipswSetView && window.__ipswSetView('locations')")
            case "web-traffic":
                self.evaluate("window.__ipswSetView && window.__ipswSetView('traffic')")
            case "web-modal":
                self.evaluate("document.querySelector('[data-act=addPlan]')?.click()")
            case "web-click":
                self.evaluate("document.querySelector('[data-act=refresh]')?.click()")
            case "web-edit":
                self.evaluate("document.querySelector('[data-act=editPlan]')?.click()")
            case "web-edit-static":
                let js = "(function(){var p=S.profiles.find(function(x){return x.mode==='manual'&&x.ip});" +
                    "if(!p)return;selectedDevice=p.device;render();planModal(p)})()"
                self.evaluate(js)
            case "web-loc-modal":
                self.evaluate("window.__ipswSetView && window.__ipswSetView('locations');" +
                              "setTimeout(function(){document.querySelector('[data-act=createLoc]')?.click()},120)")
            case "web-close":
                // 等价于用户点窗口红色关闭按钮，验证「关窗口即退出」。
                self.window?.performClose(nil)
            default:
                break
            }
        }
    }

    private func sendToast(_ kind: String, _ title: String, _ message: String) {
        let payload: [String: Any] = ["kind": kind, "title": title, "message": message]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        let encoded = Data(text.utf8).base64EncodedString()
        evaluate("window.__ipswToast(window.__b64json('\(encoded)'))")
    }

    /// 每秒一次的轻量增量，只更新图表与速率数字，不重绘整个页面。
    private func pushTraffic(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        let encoded = Data(text.utf8).base64EncodedString()
        evaluate("window.__ipswTraffic && window.__ipswTraffic(window.__b64json('\(encoded)'))")
    }

    /// 把 Core 的数据整理成前端需要的结构（后台构建，避免阻塞 UI）。
    private static func buildState(message: String, busy: Bool) -> [String: Any] {
        let store = (try? Store.load()) ?? ProfileStore.empty()
        let nics = (try? ServiceResolver.list()) ?? []
        let statuses = CurrentState.snapshot(nics: nics,
                                             profiles: store.profiles,
                                             activeProfileID: store.activeProfileID)
        let locations = LocationManager.list()
        let liveDevices = Set(nics.map { $0.device })
        let liveNames = Set(nics.map { $0.name })

        let nicRows: [[String: Any]] = statuses.map { s in
            ["device": s.device, "name": s.name, "mode": s.mode,
             "liveIP": s.liveIP, "dns": s.dns,
             "currentProfileID": s.matchedProfileID ?? "",
             "currentProfileName": s.matchedProfileName ?? ""]
        }

        let profileRows: [[String: Any]] = store.profiles.compactMap { profile in
            guard profile.isDirect, let service = profile.services.first else {
                return nil
            }
            let device = service.match.device ?? ""
            let name = service.match.serviceName ?? ""
            let matched = statuses.first {
                $0.device == device || $0.name == name
            }?.matchedProfileID
            return [
                "id": profile.id,
                "name": profile.name,
                "nic": name,
                "device": device,
                "mode": service.ipv4?.mode ?? "dhcp",
                "ip": service.ipv4?.ip ?? "",
                "mask": service.ipv4?.mask ?? "",
                "router": service.ipv4?.router ?? "",
                "dns": service.dns?.servers ?? [],
                "detail": ProfileEditor.detail(profile),
                "isCurrent": matched == profile.id,
                "connected": liveDevices.contains(device) || liveNames.contains(name)
            ]
        }

        let locationRows: [[String: Any]] = locations.map { entry in
            ["name": entry.name, "isCurrent": entry.isCurrent,
             "summary": entry.summary,
             "services": entry.serviceRows.map {
                 ["title": $0.title, "detail": $0.detail]
             }]
        }

        return ["location": NetworkSetup.currentLocation(),
                "activeProfileID": store.activeProfileID ?? "",
                "busy": busy, "message": message,
                "nics": nicRows, "profiles": profileRows,
                "locations": locationRows]
    }

    // MARK: - JS → Swift

    private func bool(_ body: [String: Any], _ key: String) -> Bool {
        if let value = body[key] as? Bool { return value }
        if let number = body[key] as? NSNumber { return number.boolValue }
        if let text = body[key] as? String { return text == "1" || text == "true" }
        return false
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }
        IPSLog.write("Web 动作：\(action)")

        switch action {
        case "ready", "refresh":
            pushState()

        case "openLog":
            NSWorkspace.shared.open(IPSLog.fileURL)

        case "openConfig":
            NSWorkspace.shared.open(Store.fileURL)

        case "dragWindow":
            // 前端在顶栏 / 弹窗标题按下鼠标时触发，交还系统执行窗口拖动。
            if let event = NSApp.currentEvent, let win = window {
                win.performDrag(with: event)
            }

        case "quit":
            NSApp.terminate(nil)

        case "rollback":
            runCore("正在恢复上次快照… 请输密码") { Applier.rollback() }

        case "apply":
            guard let id = body["id"] as? String,
                  let profile = (try? Store.load())?.profiles.first(where: { $0.id == id })
            else { return }
            runCore("正在应用「\(profile.name)」… 请输密码") {
                Applier.apply(profile: profile,
                              store: (try? Store.load()) ?? ProfileStore.empty())
            }

        case "dhcp":
            guard let device = body["device"] as? String,
                  let nic = body["nic"] as? String else { return }
            let profile = PresetFactory.dhcp(nic: nic, device: device)
            runCore("正在把 \(nic) 恢复为 DHCP…") {
                Applier.apply(profile: profile,
                              store: (try? Store.load()) ?? ProfileStore.empty())
            }

        case "saveProfile":
            saveProfile(body)

        case "deleteProfile":
            guard let id = body["id"] as? String else { return }
            do {
                _ = Store.backupCurrent()
                try Store.deleteProfile(id: id)
                sendToast("success", "方案已删除", "配置文件已自动备份。")
                pushState()
            } catch {
                sendToast("error", "删除失败", error.localizedDescription)
            }

        case "switchLocation":
            guard let name = body["name"] as? String else { return }
            runCore("正在切换到位置「\(name)」… 请输密码") {
                LocationManager.switchTo(name: name)
            }

        case "createLocation":
            guard let name = body["name"] as? String else { return }
            let populate = bool(body, "populate")
            runCore("正在创建位置「\(name)」…") {
                LocationManager.create(name: name, populate: populate)
            }

        case "deleteLocation":
            guard let name = body["name"] as? String else { return }
            runCore("正在删除位置「\(name)」…") {
                LocationManager.delete(name: name)
            }

        case "importLocation":
            guard let name = body["name"] as? String else { return }
            DispatchQueue.global(qos: .utility).async {
                guard let entry = LocationManager.list().first(where: { $0.name == name }) else {
                    return
                }
                let result: Result<Int, Error>
                do { result = .success(try LocationManager.importAsProfiles(entry)) }
                catch { result = .failure(error) }
                DispatchQueue.main.async {
                    switch result {
                    case .success(let count):
                        self.sendToast("success",
                                       count > 0 ? "已导入 \(count) 套方案" : "没有新增方案",
                                       count > 0 ? "可在「网卡与方案」页直接选用。"
                                                 : "相同配置已存在，无需重复导入。")
                    case .failure(let error):
                        self.sendToast("error", "导入失败", error.localizedDescription)
                    }
                    self.pushState()
                }
            }

        default:
            IPSLog.write("未处理的 Web 动作：\(action)")
        }
    }

    private func saveProfile(_ body: [String: Any]) {
        guard let name = body["name"] as? String,
              let mode = body["mode"] as? String else { return }
        let ip = body["ip"] as? String ?? ""
        let mask = body["mask"] as? String ?? ""
        let router = body["router"] as? String ?? ""
        let dns = body["dns"] as? [String] ?? []
        let editID = body["editId"] as? String

        guard !name.isEmpty else {
            sendToast("error", "保存失败", "方案名称不能为空。"); return
        }
        if mode == "manual" {
            guard IPDialog.isValidIPv4(ip), IPDialog.isValidIPv4(mask) else {
                sendToast("error", "保存失败", "IP 地址或子网掩码格式不正确。"); return
            }
            if !router.isEmpty && !IPDialog.isValidIPv4(router) {
                sendToast("error", "保存失败", "网关格式不正确。"); return
            }
            for server in dns where !IPDialog.isValidIPv4(server) {
                sendToast("error", "保存失败", "DNS 格式不正确：\(server)"); return
            }
        }

        let store = (try? Store.load()) ?? ProfileStore.empty()
        let manual = mode == "manual"
        let old = editID.flatMap { id in store.profiles.first { $0.id == id } }
        if editID != nil && old == nil {
            sendToast("error", "保存失败", "要编辑的方案已不存在，请刷新后重试。"); return
        }

        // 编辑时锁定原网卡，避免把方案挪到当前选中的网卡上。
        let device = old?.services.first?.match.device
            ?? (body["device"] as? String ?? "")
        let nic = old?.services.first?.match.serviceName
            ?? (body["nic"] as? String ?? "")
        guard !device.isEmpty, !nic.isEmpty else {
            sendToast("error", "保存失败", "无法确定方案所属的网卡。"); return
        }

        let id: String
        if let editID {
            id = editID
        } else {
            let existing = Set(store.profiles.map { $0.id })
            let slug = manual ? ip.replacingOccurrences(of: ".", with: "-") : "dhcp"
            var candidate = "plan-\(device)-\(slug)"
            var suffix = 2
            while existing.contains(candidate) {
                candidate = "plan-\(device)-\(slug)-\(suffix)"
                suffix += 1
            }
            id = candidate
        }

        var profile = PresetFactory.custom(
            id: id, name: name, nic: nic, device: device, mode: mode,
            ip: manual ? ip : nil, mask: manual ? mask : nil,
            router: manual && !router.isEmpty ? router : nil,
            dns: manual ? dns : [])
        if let old {
            // 表单只编辑 IPv4 / DNS，其余元数据与额外网卡配置保持原样。
            profile.backend = old.backend
            profile.locationName = old.locationName
            profile.note = old.note
            profile.serviceOrder = old.serviceOrder
            profile.verify = old.verify
            if old.services.count > 1 {
                profile.services = [profile.services[0]] + Array(old.services.dropFirst())
            }
        }

        do {
            if old != nil {
                _ = Store.backupCurrent()
                try Store.updateProfile(profile)
            } else {
                try Store.appendProfile(profile)
            }
        } catch {
            sendToast("error", "保存失败", error.localizedDescription); return
        }
        IPSLog.write(old == nil ? "新增方案：\(profile.name)" : "编辑方案：\(profile.name)")

        if bool(body, "applyNow") {
            runCore("正在应用「\(name)」… 请输密码") {
                Applier.apply(profile: profile,
                              store: (try? Store.load()) ?? store)
            }
        } else {
            sendToast("success", old == nil ? "方案已保存" : "方案已更新",
                      old == nil ? "可在该网卡的方案列表中选用。"
                                 : "方案 ID 保持不变，配置文件已自动备份。")
            pushState()
        }
    }

    private func runCore(_ start: String, _ work: @escaping () -> ApplyReport) {
        guard !busy else { return }
        busy = true
        pushState(message: start)
        DispatchQueue.global(qos: .userInitiated).async {
            let report = work()
            DispatchQueue.main.async {
                self.busy = false
                self.lastMessage = report.title
                IPSLog.write("Web 操作结果：\(report.title) · \(report.message)")
                self.pushState()
                let kind = report.succeeded ? "success"
                    : (report.title == "已取消" ? "info" : "error")
                self.sendToast(kind, report.title, report.message)
            }
        }
    }
}
