# 发布与安装

本文件说明如何构建可分发版本、签名与公证，以及他人拿到包后如何安装。开发调试见 [DEVELOPMENT.md](DEVELOPMENT.md)。

## 一、构建发布包

```bash
# 通用二进制（同时支持 Apple Silicon 与 Intel），推荐用于分发
UNIVERSAL=1 VERSION=1.0.0 ./build.sh
```

产物：

| 文件 | 说明 |
|---|---|
| `IPSwitcher.app` | 主应用（含内嵌 `ipswctl`） |
| `.build/apple/Products/Release/ipswctl` | 命令行工具，可选一并分发 |

构建脚本支持的环境变量：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `VERSION` | `1.0` | 写入 `CFBundleShortVersionString` |
| `BUILD_NUMBER` | `1` | 写入 `CFBundleVersion` |
| `UNIVERSAL` | `0` | `1` 时同时编译 arm64 + x86_64 |
| `SIGN_IDENTITY` | `-` | 签名身份；`-` 为 ad-hoc 签名 |

## 二、签名方式

### 1. Ad-hoc 签名（默认，个人/内部分发）

无需开发者账号，`./build.sh` 默认就是这个。缺点：别人下载后首次打开会被 Gatekeeper 拦住，需要手动放行（见第三节）。

### 2. Developer ID 签名（正式分发，需要 Apple Developer 账号）

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
VERSION=1.0.0 UNIVERSAL=1 ./build.sh
```

验证签名：

```bash
codesign -dv --verbose=4 IPSwitcher.app
spctl -a -vvv -t install IPSwitcher.app
```

## 三、公证（Notarization，可选但推荐）

未公证的包在别人机器上会提示"无法验证开发者"。公证后可直接双击打开。

```bash
# 1. 先存入钥匙串（只需一次）
xcrun notarytool store-credentials "ipswitcher-notary" \
  --apple-id "you@example.com" --team-id TEAMID --password "app-specific-password"

# 2. 打包为 zip 提交公证
ditto -c -k --keepParent IPSwitcher.app IPSwitcher.zip
xcrun notarytool submit IPSwitcher.zip --keychain-profile "ipswitcher-notary" --wait

# 3. 把公证票据钉到 App 上（必须，离线也能通过校验）
xcrun stapler staple IPSwitcher.app

# 4. 验证
spctl -a -vvv -t install IPSwitcher.app   # 应显示 accepted / Notarized Developer ID
```

> App-specific password 在 Apple ID 后台生成；提交公证需要已用 Developer ID 签名并启用 Hardened Runtime（`build.sh` 的 `SIGN_IDENTITY` 分支已加 `--options runtime`）。

## 四、打包 DMG（可选）

```bash
mkdir -p dist
hdiutil create -volname "IP Switcher" -srcfolder IPSwitcher.app \
  -ov -format UDZO dist/IPSwitcher-1.0.0.dmg
```

若希望用户拖拽安装，可建一个含 `Applications` 快捷方式副本的临时目录再打包：

```bash
rm -rf dist/stage && mkdir -p dist/stage
cp -R IPSwitcher.app dist/stage/
ln -s /Applications dist/stage/Applications
hdiutil create -volname "IP Switcher" -srcfolder dist/stage \
  -ov -format UDZO dist/IPSwitcher-1.0.0.dmg
```

## 五、发布到 GitHub Releases

```bash
# 打标签
git tag v1.0.0 && git push origin v1.0.0

# 创建 Release 并上传产物（需已安装并登录 gh）
gh release create v1.0.0 dist/IPSwitcher-1.0.0.dmg \
  --title "v1.0.0" --notes "首个版本：预设切换、位置管理、流量监控"
```

## 六、他人如何安装使用

1. **下载**：从 GitHub Releases 下载 `.dmg`（或直接下载 `IPSwitcher.app` 压缩包）。
2. **拖入应用程序**：打开 dmg，把 `IPSwitcher.app` 拖到「应用程序」文件夹。
3. **首次打开**：
   - 已公证的包：直接双击即可。
   - ad-hoc 签名的包：首次双击会提示"Apple 无法验证此 App"。处理方式（任选其一）：
     - 右键点击 App →「打开」→ 在弹窗中再点「打开」（只需一次）；
     - 或 系统设置 → 隐私与安全性 → 底部点「仍要打开」；
     - 或终端执行：

       ```bash
       xattr -dr com.apple.quarantine /Applications/IPSwitcher.app
       ```

4. **使用**：启动后左侧选网卡，右侧点方案的「应用此方案」→ 输入一次管理员密码即生效；关窗口即退出。首次启动会自动生成默认预设（基于本机网卡现状）。

## 七、已知限制

- 只支持 macOS；每次应用预设都需要管理员授权（`networksetup` 修改系统网络配置的固有要求）。
- 没有自动更新机制，升级需手动下载替换。
- 应用修改的是系统网络配置，切换过程中网络会短暂中断。
