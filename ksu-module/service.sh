#!/system/bin/sh
# ============================================================
# adfr_idle service.sh
#   1. 从 /proc/kallsyms 解析 msm_drm 里两个函数地址
#   2. insmod adfr_idle.ko（地址作为模块参数）
#   3. 启动用户态阶梯守护（写 /sys/module/adfr_idle/parameters/fps）
# ============================================================

MODDIR=${0%/*}
DATA=/data/adb/adfr_idle
KO=$MODDIR/lib/adfr_idle.ko
LOG=$DATA/service.log
PIDF=$DATA/.pid
NODE=/sys/module/adfr_idle/parameters/fps

mkdir -p "$DATA"
log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"; }

# 等系统起来、面板驱动就绪
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 1; done
sleep 15

[ -f "$KO" ] || { log "FATAL: $KO missing"; exit 1; }

# 清理上一个实例
if [ -f "$PIDF" ]; then
    kill "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null
    rm -f "$PIDF"
fi
[ -d /sys/module/adfr_idle ] && { log "rmmod old"; rmmod adfr_idle 2>/dev/null; }

# ---- 解析符号地址 ----------------------------------------------------
# msm_drm 是 vendor 模块，符号只出现在 /proc/kallsyms（需要 kptr_restrict=0）
kptr=$(cat /proc/sys/kernel/kptr_restrict 2>/dev/null)
echo 0 > /proc/sys/kernel/kptr_restrict 2>/dev/null

A_GCD=$(grep -m1 ' oplus_display_get_current_display' /proc/kallsyms | cut -d' ' -f1)
A_UPD=$(grep -m1 ' oplus_adfr_min_fps_update' /proc/kallsyms | cut -d' ' -f1)

[ -n "$kptr" ] && echo "$kptr" > /proc/sys/kernel/kptr_restrict 2>/dev/null

log "resolve: gcd=$A_GCD update=$A_UPD (kptr_restrict was $kptr)"

case "$A_GCD" in ffff*) ;; *) log "FATAL: cannot resolve display helper"; exit 1 ;; esac
case "$A_UPD" in ffff*) ;; *) log "FATAL: cannot resolve min_fps_update"; exit 1 ;; esac

# ---- 加载模块 --------------------------------------------------------
insmod "$KO" "addr_gcd=0x$A_GCD" "addr_update=0x$A_UPD"
if [ ! -w "$NODE" ]; then
    log "FATAL: insmod failed (no $NODE)"
    exit 1
fi
log "module loaded"

# ---- 启动阶梯守护 ----------------------------------------------------
chmod 755 "$MODDIR/bin/ltpo_idle.sh"
LTPO_DATA="$DATA" LTPO_NODE="$NODE" "$MODDIR/bin/ltpo_idle.sh" >>"$DATA/ltpo.log" 2>&1 &
echo $! > "$PIDF"
log "daemon started pid=$(cat "$PIDF")"
