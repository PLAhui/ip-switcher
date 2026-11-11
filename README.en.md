# ip-switcher

English | [简体中文](README.md)

A macOS network interface IP switcher. Save multiple presets per NIC (static IP or DHCP), switch with one click, create and edit presets in place — plus live traffic monitoring.

Built for developers and sysadmins who constantly move between networks: office LAN, data center, lab bench, internal debugging.

## Quick start (TL;DR)

**After changing code, run it like this:**

```bash
cd ip-switcher
swift build --disable-sandbox -c debug
.build/debug/IPSwitcher        # dev run; quits when the window closes; just re-run after changes
```

To build the packaged app instead, run `./build.sh` and double-click `IPSwitcher.app`.

**How to install & use:**

- For yourself: after `./build.sh`, just double-click `IPSwitcher.app` — no install step (dropping it in /Applications keeps things tidy)
- For others: zip up `IPSwitcher.app` and send it. The recipient right-clicks → Open once to get past Gatekeeper (ad-hoc signing), then uses it normally. If it still won't open: `xattr -dr com.apple.quarantine /Applications/IPSwitcher.app`

Details below and in the [documentation](#documentation).

## Documentation

- [Development guide](docs/DEVELOPMENT.md) (Chinese): environment setup, debugging, code structure, self-test hooks and logs
- [Build & release](docs/RELEASE.md) (Chinese): release builds, signing & notarization, DMG packaging, end-user installation

## Features

- **One-click switching** — Multiple presets per interface; the active preset is marked with ✓ automatically
- **Create / edit / delete** — A modal form for static IP, subnet mask, gateway and DNS, validated before saving
- **Back to DHCP** — One click to return to automatic configuration
- **Network locations** — Browse macOS network locations and import an existing location's configuration as presets
- **Live traffic monitor** — Per-NIC up/down throughput chart (60-second window), cumulative totals and peaks; disconnected interfaces are clearly marked
- **Precise rollback** — On failure or cancellation, rollback mirrors exactly the commands that were issued — no over-restoring
- **Snapshot restore** — The config file is backed up before every mutation

## Safety by design

- All network changes go through the standard `networksetup` interface — **never** shell string concatenation
- A system snapshot is taken before changes; failures roll back to the previous state
- `profiles.json` is backed up before editing or deleting presets
- Applying a preset asks for admin authorization **once**; issue, verify and (if needed) rollback all happen inside that single authorization

## Build

Requirements: macOS 13+, Swift 5.9+ (Xcode or the Swift toolchain).

```bash
git clone https://github.com/PLAhui/ip-switcher.git
cd ip-switcher
./build.sh
```

The script generates the initial config (first run only), compiles in release mode, assembles `IPSwitcher.app`, bundles the web assets and ad-hoc signs the app.

For distribution, build a universal binary with an explicit version:

```bash
UNIVERSAL=1 VERSION=1.0.0 ./build.sh   # arm64 + x86_64
```

See [Build & release](docs/RELEASE.md) for signing, notarization and DMG packaging.

Artifacts:

| Artifact | Description |
|---|---|
| `IPSwitcher.app` | The app — double-click to run |
| `.build/release/ipswctl` | Command-line tool |

## Usage

Open `IPSwitcher.app`. The sidebar has three pages:

1. **Interfaces & presets** — Pick an NIC on the left, its presets appear on the right. Click "Apply" and enter your password once. No matching preset? Click "+ New preset", fill in the IP and choose "Save only" or "Save and apply".
2. **Network locations** — View / switch system network locations, or import a location's current configuration as presets (rarely needed; mainly a data source).
3. **Traffic monitor** — Live throughput charts per NIC.

The app behaves like a normal Mac app: it opens its main window on launch and **quits when the window is closed** — nothing lingers in the background.

## CLI: ipswctl

```bash
.build/release/ipswctl list              # list all presets
.build/release/ipswctl state             # current NIC state and preset matching
.build/release/ipswctl preview <preset>  # dry-run: print the commands (nothing executed)
.build/release/ipswctl script <preset>   # export the privileged script
.build/release/ipswctl apply <preset>    # apply a preset
.build/release/ipswctl locations         # list system network locations
```

## Configuration

Presets live in `~/Library/Application Support/IPSwitcher/profiles.json`.

The file is generated on first build by `ipswctl init-config` from your current interfaces and locations, and is **not committed** (to avoid leaking personal network details). Core structure:

```jsonc
{
  "profiles": [
    {
      "id": "plan-en0-192-168-1-50",
      "name": "Office LAN",
      "services": [{
        "match": { "device": "en0", "serviceName": "Wi-Fi" },
        "ipv4": { "mode": "manual", "ip": "192.168.1.50",
                  "mask": "255.255.255.0", "router": "192.168.1.1" },
        "dns": { "servers": ["223.5.5.5"] }
      }],
      "verify": { "pingGateway": false, "rollbackOnFail": true, "timeoutSec": 5 }
    }
  ]
}
```

Logs: `~/Library/Logs/IPSwitcher/ipswitcher.log`.

## Project layout

```
.
├── Package.swift              # SwiftPM: three targets
├── Sources/
│   ├── IPSwitcherCore/        # Core: models, networksetup wrapper, privileged execution, rollback, location migration
│   ├── IPSwitcherApp/         # App: WKWebView bridge window, state, traffic sampling
│   └── ipswctl/               # CLI
├── Resources/
│   ├── Info.plist
│   └── web/index.html         # Front end (plain HTML/CSS/JS, Tauri-compatible)
├── build.sh                   # One-shot build script
├── docs/
│   ├── DEVELOPMENT.md         # Development guide (Chinese)
│   └── RELEASE.md             # Build, release & install (Chinese)
├── LICENSE
└── README.md / README.en.md
```

Architecture notes:

- **Core separated from UI** — Every system operation lives in `IPSwitcherCore`; the GUI is just a shell. The `ipswctl` CLI shares the exact same core, so both behave identically.
- **Web front end talks to Swift over a JS bridge** — Swift aggregates and pushes state; the web layer only sends actions. No framework on the front end, so it can move into a Tauri shell later without rewrites.

## Platform notes

macOS only. Admin authorization is required to change network settings; modifying DNS, IPv4 or static routes briefly interrupts connectivity.

## License

[MIT](LICENSE) © 2026 PLAhui
