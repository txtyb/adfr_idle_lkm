/* adfr_idle WebUI —— 通过 KernelSU 的 ksu.exec 以 root 执行 ctl.sh */
(() => {
	'use strict';

	const CTL = '/data/adb/modules/adfr_idle/bin/ctl.sh';
	const $ = (s) => document.querySelector(s);
	const DEFAULT = { T1: 3, T2: 8, T3: 15, T4: 30, F4: 1 };

	let busy = false;

	/* ---------- KernelSU bridge ---------- */
	function getBridge() {
		if (window.ksu && typeof window.ksu.exec === 'function') return window.ksu;
		if (typeof ksu !== 'undefined' && ksu && typeof ksu.exec === 'function') return ksu;
		return null;
	}

	function exec(args) {
		return new Promise((resolve) => {
			const b = getBridge();
			if (!b) {
				resolve({ errno: -1, stdout: '', stderr: 'KernelSU WebUI 接口不可用，请在 KernelSU 管理器内打开' });
				return;
			}
			const cb = '__adfr_' + Date.now() + '_' + Math.random().toString(16).slice(2);
			let settled = false;
			const finish = (errno, stdout, stderr) => {
				if (settled) return;
				settled = true;
				delete window[cb];
				resolve({ errno: errno || 0, stdout: stdout || '', stderr: stderr || '' });
			};
			window[cb] = finish;
			try {
				const ret = b.exec('sh ' + CTL + ' ' + args, cb);
				if (ret && typeof ret.then === 'function') {
					ret.then((v) => {
						if (v && typeof v === 'object') finish(v.errno, v.stdout, v.stderr);
						else finish(0, v == null ? '' : String(v), '');
					}).catch((e) => finish(-1, '', String(e)));
				}
			} catch (e) {
				finish(-1, '', String(e));
			}
		});
	}

	/* ---------- UI helpers ---------- */
	let toastTimer = null;
	function toast(msg, isErr) {
		const el = $('#toast');
		el.textContent = msg;
		el.className = 'toast show' + (isErr ? ' err' : '');
		clearTimeout(toastTimer);
		toastTimer = setTimeout(() => { el.className = 'toast'; }, 2200);
	}

	function setPill(text, cls) {
		const el = $('#pill');
		el.textContent = text;
		el.className = 'pill ' + (cls || 'gray');
	}

	/* ---------- 状态 ---------- */
	async function refresh() {
		const r = await exec('status');
		if (r.errno !== 0 && !r.stdout) {
			setPill('不可用', 'warn');
			$('#enabledText').textContent = r.stderr || '执行失败';
			return;
		}
		const kv = {};
		r.stdout.split('\n').forEach((line) => {
			const i = line.indexOf('=');
			if (i > 0) kv[line.slice(0, i).trim()] = line.slice(i + 1).trim();
		});

		const loaded = kv.loaded === '1';
		const enabled = kv.enabled === '1';
		const daemon = kv.daemon && kv.daemon !== '0';

		$('#fpsVal').textContent = kv.fps && kv.fps !== '-' ? kv.fps : '—';
		$('#appliedVal').textContent = kv.applied || '0';
		$('#screenVal').textContent = kv.screen || '—';
		$('#levelVal').textContent = kv.level || '—';

		$('#enableSwitch').checked = enabled && loaded;
		$('#enableSwitch').disabled = !loaded;

		if (!loaded) {
			setPill('模块未加载', 'off');
			$('#enabledText').textContent = 'LKM 未加载，检查 service.log';
		} else if (!enabled) {
			setPill('已停用', 'off');
			$('#enabledText').textContent = '保持满帧，不降频';
		} else if (!daemon) {
			setPill('守护未运行', 'warn');
			$('#enabledText').textContent = '开关已开，但进程不在了';
		} else {
			setPill('运行中', 'ok');
			$('#enabledText').textContent = '按阶梯自动降频';
		}

		if (kv.config) {
			const cfg = {};
			kv.config.split(';').forEach((item) => {
				const i = item.indexOf('=');
				if (i > 0) cfg[item.slice(0, i).trim()] = item.slice(i + 1).trim();
			});
			['T1', 'T2', 'T3', 'T4'].forEach((k) => {
				if (cfg[k] && !document.activeElement.matches('#' + k)) {
					$('#' + k).value = (Number(cfg[k]) / 1000).toString();
				}
			});
			if (cfg.F4 && !document.activeElement.matches('#F4')) {
				$('#F4').value = cfg.F4;
			}
		} else {
			if (!document.activeElement.matches('.fields input')) {
				$('#T1').value = DEFAULT.T1;
				$('#T2').value = DEFAULT.T2;
				$('#T3').value = DEFAULT.T3;
				$('#T4').value = DEFAULT.T4;
				$('#F4').value = DEFAULT.F4;
			}
		}
	}

	/* ---------- 动作 ---------- */
	async function setEnabled(on) {
		if (busy) return;
		busy = true;
		const r = await exec(on ? 'on' : 'off');
		busy = false;
		if (r.errno !== 0 && !r.stdout.includes('ok=')) {
			toast(r.stderr || '操作失败', true);
		} else {
			toast(on ? '已启用' : '已停用');
		}
		await refresh();
	}

	async function setFps(v) {
		if (busy) return;
		busy = true;
		const r = await exec('fps ' + v);
		busy = false;
		if (r.stdout.includes('error=')) toast(r.stdout.replace('error=', ''), true);
		else toast('已下发 ' + v + 'Hz');
		await refresh();
	}

	async function saveConfig() {
		const sec = (id) => {
			const v = Number($('#' + id).value);
			if (!isFinite(v) || v <= 0) return null;
			return Math.round(v * 1000);
		};
		const t1 = sec('T1'), t2 = sec('T2'), t3 = sec('T3'), t4 = sec('T4');
		const f4 = Number($('#F4').value);
		if (t1 == null || t2 == null || t3 == null || t4 == null || !isFinite(f4) || f4 < 1) {
			toast('阈值需要是正数', true);
			return;
		}
		if (!(t1 <= t2 && t2 <= t3 && t3 <= t4)) {
			toast('阈值要递增：T1 ≤ T2 ≤ T3 ≤ T4', true);
			return;
		}
		if (busy) return;
		busy = true;
		const r1 = await exec(`set T1=${t1} T2=${t2} T3=${t3} T4=${t4} F4=${f4}`);
		const r2 = await exec('restart');
		busy = false;
		if (r1.stdout.includes('error=')) {
			toast('保存失败', true);
		} else if (r2.stdout.includes('ok=')) {
			toast('已保存，守护已重启');
		} else {
			toast('已保存，重启守护失败', true);
		}
		await refresh();
	}

	async function loadLog() {
		const r = await exec('log');
		$('#logBox').textContent = (r.stdout || r.stderr || '(空)').trim();
	}

	/* ---------- 绑定 ---------- */
	function bind() {
		$('#refreshBtn').addEventListener('click', refresh);
		$('#enableSwitch').addEventListener('change', (e) => setEnabled(e.target.checked));
		$('#chips').addEventListener('click', (e) => {
			const btn = e.target.closest('button[data-fps]');
			if (btn) setFps(btn.dataset.fps);
		});
		$('#saveBtn').addEventListener('click', saveConfig);
		$('#logBtn').addEventListener('click', loadLog);
	}

	bind();
	refresh();
	setInterval(() => {
		if (document.visibilityState === 'visible' && !busy) refresh();
	}, 3000);
})();
