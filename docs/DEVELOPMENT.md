# 开发指南

本文件说明如何在本地搭建开发环境、调试运行，以及代码结构与调试技巧。发布与安装见 [RELEASE.md](RELEASE.md)。

## 环境要求

| 项目 | 要求 |
|---|---|
| 系统 | macOS 13 (Ventura) 及以上 |
| 工具链 | Xcode 15+ 或 Command Line Tools（Swift 5.9+） |
| 架构 | Apple Silicon 与 Intel 均可（构建时默认只编本机架构） |

检查环境：

```bash
swift --version      # 应显示 Swift 5.9 或更高
xcode-select -p      # 未安装时会提示
```

## 拉取与首次构建

```bash
git clone https://github.com/PLAhui/ip-switcher.git
cd ip-switcher
./build.sh
```

首次构建会自动执行 `ipswctl init-config`，根据**你当前机器**的网卡与网络位置生成 `profiles.json`（该文件已被 `.gitignore` 排除，不会提交）。

## 开发调试

### 直接跑源码编译产物

```bash
swift build --disable-sandbox -c debug
.build/debug/IPSwitcher
```

说明：

- `--disable-sandbox` 是必要的：受限环境下 SwiftPM 自身的沙箱会导致 `sandbox_apply: Operation not permitted`，`build.sh` 里也统一加了该参数。
- 调试版直接运行时，App 会在源码树里找前端资源（`Resources/web/index.html`），因此**改完前端重启应用即可看到效果**，无需重新打包 `.app`。
- 也可以通过环境变量指定前端目录，便于把前端放到别处调试：

```bash
IPSW_WEB_ROOT=/path/to/web .build/debug/IPSwitcher
```

### 只读调试（重要）

修改网络配置是**有风险**的操作。开发时优先使用 CLI 的只读子命令核对逻辑，它们不会真正下发命令：

```bash
.build/debug/ipswctl list                 # 预设列表
.build/debug/ipswctl state                # 网卡现状与预设匹配情况
.build/debug/ipswctl preview <预设ID>      # 预演将要执行的 networksetup 命令
.build/debug/ipswctl script <预设ID>       # 导出提权脚本，可人工审查
.build/debug/ipswctl locations            # 系统网络位置
```

只有 `apply` 会真正修改系统配置，测试时请确认目标网卡与预设内容一致。

### 运行模式：真实 / 演示

应用有两种运行模式：

| 模式 | 数据来源 | 写操作 | 启动方式 |
|---|---|---|---|
| **真实模式**（默认） | 本机真实网卡与配置 | 允许（走授权流程） | `open IPSwitcher.app` |
| **演示模式** | 前端内置虚构示例数据 | **全部拦截**，界面顶部显示「演示模式 · 只读」角标 | 见下 |

进入演示模式的三种方式（任选其一）：

```bash
./demo.sh                                        # 快捷脚本（推荐）
IPSWitcher.app/Contents/MacOS/IPSwitcher --demo  # 裸跑可执行文件，带 --demo 参数
IPSW_DEMO=1 IPSwitcher.app/Contents/MacOS/IPSwitcher   # 环境变量方式
```

另外，直接用浏览器打开 `Resources/web/index.html`（无原生桥）也会自动渲染演示数据，便于纯前端调试样式。

注意：macOS 的 `open --args --demo` 在本机实测**不会**把参数传进应用（argv 只有进程路径），所以演示模式不要通过 `open --args` 进入。

演示模式的安全设计：

- 前端 `DEMO` 数据中的设备名（如 `en0`）与真机可能重名，因此 Swift 层对 `apply` / `dhcp` / `rollback` / `saveProfile` / `deleteProfile` / 位置切换等所有写操作做了硬拦截，并弹 toast 提示。
- 自检钩子 `web-demo-guard` 专用于验证该拦截：演示模式下它模拟一次「恢复 DHCP」请求，日志应出现「演示模式：已拦截动作 dhcp」。该钩子带 `where demoMode` 保护，非演示模式下绝不会执行。

### 无人值守界面自检

通过环境变量驱动界面跳到指定状态，便于配合 `screencapture` 截图核对：

```bash
IPSW_SELFTEST=web-traffic .build/debug/IPSwitcher
```

| 取值 | 效果 |
|---|---|
| `web-click` | 主视图（触发一次刷新） |
| `web-locations` | 切到「网络位置」页 |
| `web-loc-modal` | 打开「新建位置」弹窗 |
| `web-traffic` | 切到「流量监控」页 |
| `web-modal` | 打开「新增方案」弹窗 |
| `web-edit-static` | 打开某张静态 IP 方案的编辑弹窗 |
| `web-close` | 关闭窗口（用于验证「关窗口即退出」） |
| `web-demo-guard` | 演示模式下模拟写操作（验证只读拦截生效） |

注意：`open --env` 给 `.app` 传环境变量并不可靠，自检请直接运行裸可执行文件。

### 日志

```bash
tail -f ~/Library/Logs/IPSwitcher/ipswitcher.log
```

日志覆盖：启动初始化、界面资源定位、Web 动作、方案应用结果、JS 执行异常。

## 代码结构

```
Sources/
├── IPSwitcherCore/            # 与 UI 完全无关的核心逻辑
│   ├── Models.swift           # Profile / ServiceConfig / ConfigSnapshot 等模型
│   ├── NetworkSetup.swift     # networksetup 命令封装（只构建参数数组，不拼 shell 字符串）
│   ├── PrivilegedExecutor.swift # 一次授权执行脚本 + 自动回滚
│   ├── Applier.swift          # 应用预设、回滚（严格镜像本次下发的命令）、回读校验
│   ├── CurrentState.swift     # 当前网卡状态与预设的匹配判定
│   ├── ServiceResolver.swift  # 枚举网卡服务
│   ├── Store.swift            # profiles.json 读写、备份、增删改
│   ├── LocationManager.swift  # 系统网络位置：列表/切换/创建/删除/导入为预设
│   ├── LocationMigrator.swift # 免 root 解析 preferences.plist
│   ├── PresetFactory.swift    # 预设构造（DHCP / 静态 / 自定义）
│   ├── TrafficCounters.swift  # getifaddrs 采集网卡流量
│   └── Logger.swift
├── IPSwitcherApp/             # 薄壳：窗口与桥接
│   ├── main.swift             # 静态强引用持有 AppDelegate（NSApplication.delegate 是 assign）
│   ├── AppDelegate.swift      # 启动开窗、Dock 重开、关窗退出
│   ├── WebWindowController.swift # WKWebView、JS 桥、状态聚合、自检钩子
│   ├── TrafficSampler.swift   # 每秒采样并推给前端
│   ├── IPDialog.swift         # IPv4 校验
│   └── ProfileEditor.swift    # 预设摘要文案
└── ipswctl/                   # 命令行工具（与 App 共用同一套 Core）
```

前端为单文件 `Resources/web/index.html`（原生 HTML/CSS/JS，无框架），与 Swift 只通过三个入口通信：

| 方向 | 接口 |
|---|---|
| Swift → JS | `window.__ipswRender(json)` 全量状态、`window.__ipswTraffic(json)` 流量增量、`window.__ipswToast(json)` 提示 |
| JS → Swift | `window.webkit.messageHandlers.ipsw.postMessage({action, ...})` |

中文字符串统一用 base64 + `TextDecoder('utf-8')` 传递，避免 `atob()` 按 Latin-1 拆坏多字节字符。

## 开发注意事项

0. **免密切换的实现**：`PasswordlessSwitch`（Core）管理 `/etc/sudoers.d/ipswitcher`（内容仅一行，NOPASSWD 限定 `/usr/sbin/networksetup`）。`PrivilegedExecutor.run(apply:)` 每次先用 `sudo -n -l` 探测：命中规则则走 `runPlain`（脚本内逐条 `sudo -n networksetup`，无对话框）；未命中则走 osascript 授权对话框。开启/关闭规则的脚本写入前都经 `visudo -cf` 校验。沙箱化的终端里 `sudo` 会被拦截（exit 127），探测逻辑要在真实环境验证。
1. **不要在开发时对生产网卡执行 `apply`**。需要验证下发链路时，优先 `preview` / `script` 审查命令，或使用一块未使用的 USB 网卡。
2. **改动 `profiles.json` 前先备份**：

   ```bash
   cp "$HOME/Library/Application Support/IPSwitcher/profiles.json" /tmp/profiles.backup.json
   ```

3. 不要用 `HOME=/tmp/xxx` 之类的方式隔离配置——macOS 的 `homeDirectoryForCurrentUser` 不跟随 `HOME` 环境变量，会直接写到真实配置。
4. 所有系统命令必须走 `Process` + `arguments` 数组，禁止拼接 shell 字符串。
