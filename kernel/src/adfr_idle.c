// SPDX-License-Identifier: GPL-2.0
/*
 * adfr_idle - drive OnePlus/OPPO panel ADFR (LTPO) min-fps from userspace
 *
 * 背景：
 *   /sys/kernel/oplus_display/min_fps 只改驱动内部状态，不会下发 DSI 命令；
 *   真正下发 qcom,mdss-dsi-adfr-min-fps-X-command 的是 msm_drm 里的
 *   oplus_adfr_min_fps_update(display, fps)，而它只在 HWC 提交时才被调用。
 *
 * 做法：
 *   userspace 在 /proc/kallsyms 里解析出
 *     oplus_display_get_current_display()   拿到 dsi_display*
 *     oplus_adfr_min_fps_update(display, f)  直接下发命令
 *   的地址，通过 insmod 参数传进来。之后每次写本模块的 fps 参数，
 *   就立刻调用一次 update，命令即时生效，不依赖 HWC 提交。
 *
 * 注意：
 *   - 必须用 __nocfi 调用解析出来的函数（GKI 开了 CFI）
 *   - 地址每次开机都变（KASLR），由 service.sh 运行时解析
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/types.h>
#include <linux/string.h>
#include <linux/mutex.h>
#include <linux/kstrtox.h>
#include <linux/moduleparam.h>

#ifndef __nocfi
#define __nocfi
#endif

#define TAG "adfr_idle"

/* arm64 内核地址下界，防止把垃圾值当函数指针调用 */
#define KERNEL_ADDR_MIN 0xffff000000000000UL

static unsigned long addr_gcd;      /* oplus_display_get_current_display */
module_param(addr_gcd, ulong, 0444);
MODULE_PARM_DESC(addr_gcd, "address of oplus_display_get_current_display()");

static unsigned long addr_update;   /* oplus_adfr_min_fps_update */
module_param(addr_update, ulong, 0444);
MODULE_PARM_DESC(addr_update, "address of oplus_adfr_min_fps_update(void *display, uint fps)");

static unsigned int applied;        /* 成功下发次数，排障用 */
module_param(applied, uint, 0444);
MODULE_PARM_DESC(applied, "how many times min-fps was pushed to the panel");

static unsigned int last_fps;
module_param(last_fps, uint, 0444);
MODULE_PARM_DESC(last_fps, "last requested min fps");

static DEFINE_MUTEX(adfr_lock);

static int __nocfi adfr_push(unsigned int fps)
{
	void *display;
	int (*update)(void *, unsigned int);
	int ret = 0;

	if (!addr_gcd || !addr_update)
		return -EINVAL;
	if (addr_gcd < KERNEL_ADDR_MIN || addr_update < KERNEL_ADDR_MIN)
		return -EINVAL;

	if (!mutex_trylock(&adfr_lock))
		return -EBUSY;

	display = ((void *(*)(void))addr_gcd)();
	if (!display) {
		pr_debug(TAG ": no active display\n");
		ret = -ENODEV;
		goto out;
	}

	update = (int (*)(void *, unsigned int))addr_update;
	update(display, fps);

	applied++;
	if (fps != last_fps)
		pr_info(TAG ": pushed min_fps=%u (total %u)\n", fps, applied);
	else
		pr_debug(TAG ": re-pushed min_fps=%u\n", fps);
	last_fps = fps;

out:
	mutex_unlock(&adfr_lock);
	return ret;
}

static int fps_set(const char *val, const struct kernel_param *kp)
{
	unsigned int v = 0;
	int ret;

	ret = kstrtouint(val, 10, &v);
	if (ret)
		return ret;

	/* 先把值存进 param 存储，读回来才是最后一次写入 */
	*(unsigned int *)kp->arg = v;

	/* 0 = 只记录不推送，方便临时停用 */
	if (v)
		ret = adfr_push(v);

	return ret;
}

static const struct kernel_param_ops fps_ops = {
	.set = fps_set,
	.get = param_get_uint,
};

static unsigned int fps = 120;
module_param_cb(fps, &fps_ops, &fps, 0644);
MODULE_PARM_DESC(fps, "requested minimum refresh rate (write triggers a push)");

static int __init adfr_idle_init(void)
{
	pr_info(TAG ": loaded, gcd=%px update=%px\n",
		(void *)addr_gcd, (void *)addr_update);
	return 0;
}

static void __exit adfr_idle_exit(void)
{
	/* 退出时把地板恢复成 120，避免面板卡在 1Hz */
	adfr_push(120);
	pr_info(TAG ": unloaded\n");
}

module_init(adfr_idle_init);
module_exit(adfr_idle_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Push OPPO ADFR min-fps to the panel from userspace");
MODULE_AUTHOR("dsh");
