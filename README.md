# adfr_idle — 让 OnePlus 15 的 LTPO 真正降频

在 LineageOS / AOSP 类 ROM 上，面板的 ADFR 低频档（30/20/10/1Hz）**代码齐全但从不下发**：

- `oplus_adfr.c` 完整支持 ADFR，面板 DTS 里有 `oplus,adfr-min-fps-mapping-table = <120 60 30 20 10 1>`
- 但 `/sys/kernel/oplus_display/min_fps` 只是改驱动内部状态，**不会发 DSI 命令**
- 真正下发命令的 `oplus_adfr_min_fps_update(display, fps)` 只在 HWC 提交时被调用，而静止画面没有提交

本模块用一个极小的 LKM 直接调用那个函数，把命令实时打下去。

## 结构

```
.
├── .github/workflows/build.yml   # DDK 容器里编译 + 打包 + artifact
├── kernel/
│   ├── Makefile                  # obj-m := adfr_idle.o
│   └── src/adfr_idle.c           # 模块本体（~120 行）
└── ksu-module/
    ├── module.prop
    ├── service.sh                # 解析符号地址 → insmod → 启动守护
    ├── post-fs-data.sh
    ├── uninstall.sh
    └── bin/ltpo_idle.sh          # 阶梯策略（触摸/媒体/息屏感知）
```

## 构建（fork + Actions）

1. **Fork** 这个仓库到你自己的 GitHub。
2. 进入 **Actions → Build adfr_idle LKM → Run workflow**（默认 `android16-6.12`，匹配 OnePlus 15 的内核 `6.12.81-android16`）。
3. 跑完在 **Artifacts** 里下载 `adfr_idle-ksu.zip`。
4. 打 tag（`git tag v1.0 && git push --tags`）会自动发 Release。

构建环境来自 [LKM-PathMask](https://github.com/Andrea-lyz/LKM-PathMask) 同款 DDK 镜像：
`ghcr.io/ylarod/ddk-min:android16-6.12-20260828`

## 安装

KernelSU 管理器里「安装模块」选择那个 zip，重启。

或者手动：

```bash
adb push adfr_idle-ksu.zip /data/local/tmp/
adb shell su -c 'mkdir -p /data/adb/modules/adfr_idle && cd /data/adb/modules/adfr_idle && unzip -o /data/local/tmp/adfr_idle-ksu.zip'
# 重启
```

## 验证

```bash
# 1. 模块是否加载
adb shell su -c 'ls /sys/module/adfr_idle/parameters/'
#   fps  applied  last_fps  addr_gcd  addr_update

# 2. service.sh 有没有解析到地址
adb shell su -c 'cat /data/adb/adfr_idle/service.log'
#   resolve: gcd=ffff... update=ffff...
#   module loaded

# 3. 手动压一下地板，看面板是否真的收到命令
adb shell su -c 'echo 10 > /sys/module/adfr_idle/parameters/fps'
adb shell 'dmesg | grep adfr-min-fps | tail -3'
#   期望：dsi_cmd: qcom,mdss-dsi-adfr-min-fps-4-command   （索引 4 = 10Hz）

adb shell su -c 'echo 1 > /sys/module/adfr_idle/parameters/fps'
adb shell 'dmesg | grep adfr-min-fps | tail -2'
#   期望：... adfr-min-fps-5-command                        （索引 5 = 1Hz）

# 4. 阶梯是否在工作
adb shell su -c 'tail -20 /data/adb/adfr_idle/ltpo.log'
```

## 策略

| 距上次触摸 | fps 参数 | 面板行为 |
|---|---|---|
| < 0.5 s | 120 | 满帧 |
| 0.5–2 s | 60 | |
| 2–5 s | 30 | |
| 5–10 s | 10 | |
| > 10 s | 1 | 静止画面每秒刷一次 |

改 `/data/adb/adfr_idle/config` 可调阈值，例如保守版：

```sh
T4=60000; F4=10
```

改完 `kill $(cat /data/adb/adfr_idle/.pid)`，重启后 service.sh 会重新拉起。

## 原理备注

- `service.sh` 临时把 `kptr_restrict` 设为 0 读 `/proc/kallsyms`，**读完立刻恢复原值**。
- 地址每次开机都变（KASLR），所以必须运行时解析。
- 调用解析出来的函数指针必须加 `__nocfi`（GKI 开了 CFI），否则内核 panic。
- 模块 `exit` 时会主动 `push(120)`，防止面板卡在 1Hz。

## 风险

- **黑屏/花屏**：如果 `min_fps_update` 的参数理解有误，最坏是面板停在低帧率；`uninstall.sh` 会 `rmmod` 并恢复 120。
- **只支持 120/90/60 timing**：面板 DTS 里 144/165 没有 ADFR 表，写这些值会被驱动钳回原帧率。
- **视频/游戏误判**：用 `media_session` 兜底，浏览器内嵌视频可能漏判；介意就把 `T4` 调大或临时 `kill` 守护进程。
- **ROM 更新后**：符号名不变就能继续用；如果 OPPO 改函数名，`service.log` 会报 `cannot resolve`，模块不会加载，系统保持原状（安全失败）。

## 致谢

构建脚手架与 CFI/kallsyms 经验来自 [LKM-PathMask](https://github.com/Andrea-lyz/LKM-PathMask)。
