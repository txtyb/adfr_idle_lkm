#!/system/bin/sh
# 卸载：停守护、卸载模块（模块 exit 会把地板恢复成 120）、清数据
pid=$(cat /data/adb/adfr_idle/.pid 2>/dev/null)
[ -n "$pid" ] && kill "$pid" 2>/dev/null
pkill -f ltpo_idle.sh 2>/dev/null
[ -d /sys/module/adfr_idle ] && rmmod adfr_idle 2>/dev/null
rm -rf /data/adb/adfr_idle
