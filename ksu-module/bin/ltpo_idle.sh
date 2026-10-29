#!/system/bin/sh
# ============================================================
# ltpo_idle.sh — 静止时按阶梯降低面板 ADFR 地板
#
# 写的是 adfr_idle.ko 暴露的参数：
#   /sys/module/adfr_idle/parameters/fps
# LKM 收到写入后立即调用 oplus_adfr_min_fps_update()，
# 命令直接下发到面板，不依赖 HWC 提交。
#
# 阶梯：触摸刚离开 120 → 0.5s 后 60 → 2s 后 30 → 5s 后 10 → 10s 后 1
# ============================================================

MODDIR=${0%/*}
DATA=${LTPO_DATA:-/data/adb/adfr_idle}
mkdir -p "$DATA" 2>/dev/null
CONF=$DATA/config
LOG=$DATA/ltpo.log
STAMP=$DATA/.last_input
PIDF=$DATA/.pid

NODE=${LTPO_NODE:-/sys/module/adfr_idle/parameters/fps}
DPMS=${LTPO_DPMS:-/sys/class/drm/card0-DSI-1/dpms}

# ---------------- 默认配置（$DATA/config 可覆盖） ----------------
FPS_ACTIVE=120
T1=3000;  F1=60
T2=8000;  F2=30
T3=15000; F3=10
T4=30000; F4=1
REFRESH_MS=2000
MEDIA_GUARD=1
DRYRUN=0
LOG_MAX=262144
# ------------------------------------------------------------------

[ -f "$CONF" ] && . "$CONF"

log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"; }

now_ms() {
    read -r up _ < /proc/uptime
    frac=${up#*.}
    [ ${#frac} -eq 1 ] && frac=${frac}0
    echo $(( ${up%.*} * 1000 + frac * 10 ))
}

write_fps() {
    if [ "$DRYRUN" = "1" ]; then
        log "DRYRUN write $1"
        return 0
    fi
    echo "$1" > "$NODE" 2>/dev/null
}

rotate_log() {
    [ -f "$LOG" ] || return 0
    sz=$(wc -c < "$LOG" 2>/dev/null)
    [ -n "$sz" ] && [ "$sz" -gt "$LOG_MAX" ] && mv -f "$LOG" "$LOG.1"
}

# ---------------- 前置检查 ----------------
[ -w "$NODE" ] || { log "FATAL: $NODE 不存在或不可写"; exit 1; }
[ -r "$DPMS" ] || log "WARN: $DPMS 不可读"
command -v getevent >/dev/null 2>&1 || log "WARN: 没有 getevent"

rotate_log
echo $$ > "$PIDF"
log "start: node=$NODE active=$FPS_ACTIVE ladder=${F1}/${F2}/${F3}/${F4} refresh=${REFRESH_MS}ms"

# ---------------- 输入监听 ----------------
detect_touch_dev() {
    dev=$(grep -A6 'Name="touchpanel"' /proc/bus/input/devices 2>/dev/null \
          | grep 'Handlers=' | grep -o 'event[0-9]*' | head -1)
    [ -n "$dev" ] && echo "/dev/input/$dev"
}

TOUCH_DEV=${LTPO_TOUCH_DEV:-$(detect_touch_dev)}
[ -n "$TOUCH_DEV" ] || { TOUCH_DEV="/dev/input/event"; log "WARN: 找不到 touchpanel"; }

start_listener() {
    (
        last_w=0
        getevent -q 2>/dev/null | while IFS= read -r line; do
            case "$line" in
                "$TOUCH_DEV"*)
                    read -r up _ < /proc/uptime
                    frac=${up#*.}
                    [ ${#frac} -eq 1 ] && frac=${frac}0
                    t=$(( ${up%.*} * 1000 + frac * 10 ))
                    if [ $((t - last_w)) -ge 100 ]; then
                        echo "$t" > "$STAMP" 2>/dev/null
                        last_w=$t
                    fi
                    ;;
            esac
        done
    ) &
    LISTENER=$!
}
start_listener
log "touch device: $TOUCH_DEV"

cleanup() {
    kill "$LISTENER" 2>/dev/null
    pkill -f "getevent -q" 2>/dev/null
    write_fps "$FPS_ACTIVE"
    # 只删自己的 pid 文件，避免重启时把新实例的 pid 文件删掉
    [ "$(cat "$PIDF" 2>/dev/null)" = "$$" ] && rm -f "$PIDF"
    log "stopped, restored $FPS_ACTIVE"
    exit 0
}
trap cleanup INT TERM HUP

# ---------------- 主循环 ----------------
now_ms > "$STAMP"
state=init
cur=-1
last_write=0
tick=0
media=0

while :; do
    # WebUI 的开关：disabled 文件存在时只保持满帧，不做任何降频
    if [ -f "$DATA/disabled" ]; then
        if [ "$state" != "disabled" ]; then
            state=disabled
            write_fps "$FPS_ACTIVE"
            cur=$FPS_ACTIVE
            log "disabled (webui), keep $FPS_ACTIVE"
        fi
        now_ms > "$STAMP"
        sleep 1
        continue
    fi

    read -r dpms < "$DPMS" 2>/dev/null
    if [ "$dpms" != "On" ]; then
        if [ "$state" != "off" ]; then
            state=off
            log "screen off"
        fi
        now_ms > "$STAMP"
        sleep 1
        continue
    fi
    if [ "$state" != "on" ]; then
        state=on
        log "screen on"
        write_fps "$FPS_ACTIVE"
        cur=$FPS_ACTIVE
        now_ms > "$STAMP"
    fi

    read -r up _ < /proc/uptime
    now=$(( ${up%.*} * 1000 + ${up#*.} * 10 ))
    read -r last < "$STAMP" 2>/dev/null
    [ -z "$last" ] && last=$now
    idle=$(( now - last ))
    [ "$idle" -lt 0 ] && idle=0

    if   [ "$idle" -lt "$T1" ]; then target=$FPS_ACTIVE
    elif [ "$idle" -lt "$T2" ]; then target=$F1
    elif [ "$idle" -lt "$T3" ]; then target=$F2
    elif [ "$idle" -lt "$T4" ]; then target=$F3
    else                             target=$F4
    fi

    tick=$((tick + 1))
    if [ $((tick % 15)) -eq 0 ]; then
        if [ "$MEDIA_GUARD" = "1" ] && dumpsys media_session 2>/dev/null | grep -q "state=PlaybackState {state=3"; then
            media=1
        else
            media=0
        fi
        if ! kill -0 "$LISTENER" 2>/dev/null; then
            log "listener died, restart"
            start_listener
        fi
    fi
    [ "$media" = "1" ] && target=$FPS_ACTIVE

    if [ "$target" != "$cur" ]; then
        write_fps "$target"
        log "idle=${idle}ms -> ${target}Hz"
        cur=$target
        last_write=$now
    elif [ "$target" != "$FPS_ACTIVE" ] && [ $((now - last_write)) -ge "$REFRESH_MS" ]; then
        write_fps "$target"
        last_write=$now
    fi

    sleep 0.05
done
