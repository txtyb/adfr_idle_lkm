#!/system/bin/sh
# adfr_idle 控制脚本 —— 供 KernelSU WebUI 调用
# 所有动作都以 root 执行，输出统一为 key=value 或纯文本

DATA=/data/adb/adfr_idle
MODDIR=${0%/*}
NODE=/sys/module/adfr_idle/parameters/fps
DPMS=/sys/class/drm/card0-DSI-1/dpms
CONF=$DATA/config
DAEMON=$MODDIR/ltpo_idle.sh

mkdir -p "$DATA"

status() {
    if [ -d /sys/module/adfr_idle ]; then echo "loaded=1"; else echo "loaded=0"; fi
    if [ -f "$DATA/disabled" ]; then echo "enabled=0"; else echo "enabled=1"; fi
    if [ -r "$NODE" ]; then echo "fps=$(cat "$NODE" 2>/dev/null)"; else echo "fps=-"; fi
    echo "applied=$(cat /sys/module/adfr_idle/parameters/applied 2>/dev/null || echo 0)"
    echo "screen=$(cat "$DPMS" 2>/dev/null || echo unknown)"
    pid=$(cat "$DATA/.pid" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then echo "daemon=$pid"; else echo "daemon=0"; fi
    lvl=$(dumpsys battery 2>/dev/null | grep -m1 'level:' | tr -dc 0-9)
    echo "level=${lvl:-0}"
    echo "config=$(cat "$CONF" 2>/dev/null | tr '\n' ';' )"
}

start_daemon() {
    pid=$(cat "$DATA/.pid" 2>/dev/null)
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null
        i=0
        while [ $i -lt 20 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i+1)); done
    fi
    pkill -f "ltpo_idle.sh" 2>/dev/null
    sleep 0.5
    rm -f "$DATA/.pid"
    setsid env LTPO_DATA="$DATA" LTPO_NODE="$NODE" "$DAEMON" >/dev/null 2>&1 </dev/null &
    sleep 0.5
    newpid=$(cat "$DATA/.pid" 2>/dev/null)
    if [ -n "$newpid" ] && kill -0 "$newpid" 2>/dev/null; then
        echo "ok=restarted pid=$newpid"
    else
        echo "error=daemon did not start"
    fi
}

case "$1" in
    status)
        status
        ;;
    on)
        rm -f "$DATA/disabled"
        echo "ok=on"
        ;;
    off)
        touch "$DATA/disabled"
        [ -w "$NODE" ] && echo 120 > "$NODE" 2>/dev/null
        echo "ok=off"
        ;;
    fps)
        v=$2
        case "$v" in
            ''|*[!0-9]*) echo "error=bad fps"; exit 1 ;;
        esac
        if [ -w "$NODE" ]; then
            echo "$v" > "$NODE"
            echo "ok=$v"
        else
            echo "error=module not loaded"
        fi
        ;;
    set)
        shift
        for kv in "$@"; do
            k=${kv%%=*}
            case "$k" in
                ''|*[!A-Za-z0-9_]*) continue ;;
            esac
            if [ -f "$CONF" ] && grep -q "^$k=" "$CONF"; then
                sed -i "s|^$k=.*|$kv|" "$CONF"
            else
                echo "$kv" >> "$CONF"
            fi
        done
        echo "ok=saved"
        ;;
    restart)
        start_daemon
        ;;
    log)
        tail -n 40 "$DATA/ltpo.log" 2>/dev/null || echo "(no log yet)"
        ;;
    *)
        echo "usage: ctl.sh {status|on|off|fps N|set K=V ...|restart|log}"
        ;;
esac
