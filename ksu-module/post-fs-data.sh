#!/system/bin/sh
# 开机早期：建目录、清残留
MODDIR=${0%/*}
DATA=/data/adb/adfr_idle
mkdir -p "$DATA"
rm -f "$DATA/.pid"
chmod 755 "$MODDIR/bin/ltpo_idle.sh" 2>/dev/null
chown 0:0 "$MODDIR/bin/ltpo_idle.sh" 2>/dev/null
