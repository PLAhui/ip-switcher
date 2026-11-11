#!/bin/bash
# 以演示模式启动 IP Switcher：渲染内置的虚构示例数据，纯只读预览。
# 演示模式下所有写操作（应用方案 / 恢复 DHCP / 切换位置等）都会被拦截，
# 不会触碰任何真实网络配置与 profiles.json。
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/IPSwitcher.app/Contents/MacOS/IPSwitcher" --demo
