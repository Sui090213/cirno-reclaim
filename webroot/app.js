/* Cirno Reclaim Hybrid - WebUI
   无框架、无外部请求。KernelSU / KsuWebUI 的 ksu.exec 是同步接口，
   这里统一包一层，兼容返回 Promise 的版本。

   设计要点：
   - 所有命令走 /system/bin/sh + 绝对路径，避免 WebUI 环境 PATH 不完整；
   - 配置读取失败时禁用保存并显示原始 stderr，绝不把开关写成 0；
   - 日志直接展示模块 log 文件（带路径与大小）；
   - 主题/背景/透明度：设备端 theme.conf + localStorage（本地图片）。 */

'use strict';

(function () {
  var MOD = '/data/adb/modules/cirno_reclaim';
  var CTL = MOD + '/bin/ctl.sh';
  var CONF = '/data/adb/cirno_reclaim/config.conf';
  var SH = '/system/bin/sh';
  var MAIL = 'asui20090213@outlook.com';
  var QUOTED = { include_packages: 1, exclude_packages: 1 };

  var isKsu = !!(window.ksu && typeof window.ksu.exec === 'function');

  var state = {
    configLoaded: false,
    cfg: {},
    cfgMeta: '',
    status: null,
    info: null,
    page: 'home',
    busy: 0,
    lastSave: null,
    diagText: ''
  };

  /* ------------------------------------------------------------ 基础 */
  function norm(v) {
    if (typeof v === 'string') return { errno: 0, stdout: v, stderr: '' };
    if (!v || typeof v !== 'object') return { errno: 0, stdout: '', stderr: '' };
    return {
      errno: typeof v.errno === 'number' ? v.errno : 0,
      stdout: v.stdout || '',
      stderr: v.stderr || ''
    };
  }

  function sh(args) {
    if (!isKsu) return Promise.reject(new Error('缺少 root 接口（请用 KernelSU / KsuWebUI 打开）'));
    var line = SH + ' ' + CTL + ' ' + args;
    try {
      var r = window.ksu.exec(line);
      if (r && typeof r.then === 'function') return r.then(norm);
      return Promise.resolve(norm(r));
    } catch (e) {
      return Promise.reject(e);
    }
  }

  function raw(script) {
    if (!isKsu) return Promise.reject(new Error('缺少 root 接口'));
    try {
      var r = window.ksu.exec(script);
      if (r && typeof r.then === 'function') return r.then(norm);
      return Promise.resolve(norm(r));
    } catch (e) {
      return Promise.reject(e);
    }
  }

  function q(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }
  function $(id) { return document.getElementById(id); }

  function toast(msg, bad) {
    var t = $('toast');
    t.textContent = msg;
    t.className = 'toast show' + (bad ? ' bad' : '');
    clearTimeout(toast._t);
    toast._t = setTimeout(function () { t.className = 'toast'; }, 2800);
  }

  function parseJSON(text) {
    try { return JSON.parse(text); } catch (e) { return null; }
  }

  function num(v) { var n = Number(v); return isFinite(n) ? n : 0; }

  function pct(part, total) {
    if (!total) return 0;
    return Math.max(0, Math.min(100, (part / total) * 100));
  }

  /* ------------------------------------------------------------ 页面 */
  function showPage(name) {
    if (state.page === name) return;
    state.page = name;
    ['home', 'scene', 'look', 'about'].forEach(function (p) {
      var el = $('page-' + p);
      if (el) el.classList.toggle('active', p === name);
    });
    Array.prototype.forEach.call(document.querySelectorAll('.tab'), function (b) {
      b.classList.toggle('active', b.dataset.page === name);
    });
    requestAnimationFrame(movePill);
    if (name === 'home') { refreshStatus(); loadLog(); }
    if (name === 'scene') { loadConfig(); loadProfile(); }
    if (name === 'look') loadTheme();
    if (name === 'about') refreshStatus();
  }

  /* ------------------------------------------------------------ 状态 */
  var statusBusy = false;
  var lastStatusKey = '';

  function applyStatus(s) {
    if (!s || !s.ok) return false;
    var key = [s.avail, s.total, s.daemon, s.pageout, s.total_kills, s.total_freed,
               s.profile, s.engine, s.hb_age, s.device_profile, s.detected, s.rom,
               s.order, s.relief_gate].join('|');
    if (key === lastStatusKey) return true;
    lastStatusKey = key;
    state.status = s;
    renderStatus(s);
    return true;
  }

  // 一次 exec 同时取状态和设备信息：ksu.exec 是同步的，调用次数越少 UI 越不容易顿
  function refreshStatus() {
    if (!isKsu) return Promise.resolve();
    if (statusBusy) return Promise.resolve();
    statusBusy = true;

    return sh('snapshot').then(function (r) {
      var j = parseJSON(r.stdout);
      if (j && j.status && j.status.ok) {
        if (j.info) renderInfo(j.info);
        applyStatus(j.status);
        return null;
      }
      // 旧版 ctl 没有 snapshot 命令时，退回单次 status，避免整页空白
      return sh('status --json').then(function (r2) {
        var s = parseJSON(r2.stdout);
        if (!applyStatus(s) && r2.stderr) {
          toast('状态读取失败: ' + r2.stderr, true);
        }
        return null;
      });
    }).catch(function (e) {
      toast('状态读取失败: ' + e.message, true);
    }).then(function () {
      statusBusy = false;
    });
  }

  function renderInfo(j) {
    state.info = j;
    if (j.model) $('dvModel').textContent = j.model;
    if (j.android) $('dvAndroid').textContent = 'Android ' + j.android;
    if (j.kernel) $('dvKernel').textContent = j.kernel;
    if (j.engine) $('dvEngine').textContent = j.engine === 'cpp' ? 'C++ 守护' : 'Shell 守护';
    if (j.log_size) {
      $('logMeta').textContent = j.log_path + ' · ' + j.log_size + ' 字节';
    }
    renderGuard(state.status || {});
  }

  function renderStatus(s) {
    var total = num(s.total) || 1;
    var avail = num(s.avail);
    var p = pct(avail, total);
    var low = num(s.mem_low) || 0;

    $('ver').textContent = s.version || '--';
    $('abVer').textContent = s.version || '--';

    $('gaugeNum').textContent = p.toFixed(1);
    $('gaugeSub').textContent = avail + ' / ' + num(s.total) + ' MB';

    var C = 527.8;
    var fg = $('gaugeFg');
    fg.style.strokeDashoffset = String(C * (1 - p / 100));
    fg.classList.toggle('warn', avail >= low && avail < low * 1.25);
    fg.classList.toggle('bad', avail < low);

    $('tileAvail').textContent = avail;
    var alive = num(s.daemon) === 1;
    $('tileState').textContent = alive ? '运行中' : '已停止';
    $('tileStateSub').textContent = alive ? '守护状态' : '点重启守护';

    var dot = $('statusDot');
    dot.className = 'dot ' + (alive ? 'on' : 'off');
    $('brandSub').textContent = alive
      ? '内存回收 · 心跳 ' + (num(s.hb_age) >= 999999 ? '--' : num(s.hb_age) + 's')
      : '守护未运行';

    var eng = s.engine === 'cpp' ? 'C++ 守护' : (s.engine === 'shell' ? 'Shell 守护' : '未知');
    $('chipProfile').textContent = ({ conservative: '保守', balanced: '均衡', aggressive: '激进' })[s.profile] || '均衡';
    $('dvEngine').textContent = eng;
    $('dvPageout').textContent = num(s.pageout) === 1 ? '可用' : '不可用（仅 trim）';
    $('dvKills').textContent = num(s.total_kills);
    $('dvFreed').textContent = num(s.total_freed) + ' MB';

    if (num(s.pageout) === 1) {
      $('hintLine').className = 'hint';
      $('hintLine').textContent = '页换出可用：前台可把匿名页换到 zram';
    } else {
      $('hintLine').className = 'hint warn';
      $('hintLine').textContent = '页换出不可用：helper 缺失或内核不支持，前台只做 trim';
    }

    Array.prototype.forEach.call(document.querySelectorAll('.preset'), function (b) {
      b.classList.toggle('active', b.dataset.preset === s.profile);
    });

    // snapshot 顺手带上系统适配字段时，直接同步卡片，不用多发一次 exec
    if (s.device_profile || s.detected || s.rom) {
      if (s.device_profile) profileState.current = String(s.device_profile);
      if (s.detected) profileState.detected = String(s.detected);
      if (s.rom) profileState.rom = String(s.rom);
      profileState.supported = true;
      profileState.tried = true;
      renderProfile();
    }
    renderGuard(s);
  }

  /* ------------------------------------------------------------ 系统适配档案 */
  var PROFILE_META = {
    hyperos: { name: 'HyperOS / MIUI', short: 'HyperOS' },
    coloros: { name: 'ColorOS / OPlus', short: 'ColorOS' },
    generic: { name: '通用', short: '通用' }
  };
  var PROFILE_ORDER = ['hyperos', 'coloros', 'generic'];
  var profileState = {
    current: '',
    detected: '',
    rom: '',
    list: PROFILE_ORDER.slice(),
    supported: false,
    tried: false
  };
  var profileBusy = false;

  function profileName(id) {
    return PROFILE_META[id] ? PROFILE_META[id].name : (id || '未知');
  }

  function profileShort(id) {
    return PROFILE_META[id] ? PROFILE_META[id].short : (id || '未知');
  }

  function renderProfile() {
    var tag = $('romDetected');
    if (tag) {
      if (profileState.rom) tag.textContent = '检测到：' + profileState.rom;
      else if (profileState.detected) tag.textContent = '检测到：' + profileShort(profileState.detected);
      else tag.textContent = '检测到：--';
    }
    Array.prototype.forEach.call(document.querySelectorAll('#profileList .profile-item'), function (b) {
      var on = b.dataset.profile === profileState.current;
      b.classList.toggle('active', on);
      b.setAttribute('aria-pressed', on ? 'true' : 'false');
    });
    var hint = $('profileHint');
    if (!hint) return;
    if (profileState.current) {
      hint.textContent = '当前档案：' + profileName(profileState.current) +
        '（点其他项切换，会覆盖该档案包含的参数）';
    } else if (profileState.supported) {
      hint.textContent = '还没有记录系统档案，选一个应用即可。';
    } else if (profileState.tried) {
      hint.textContent = '当前 ctl 未提供 profile 命令（旧版本），升级模块后可用；' +
        '也可在终端执行 ctl.sh profile apply <名字>。';
    } else {
      hint.textContent = '正在读取系统适配…';
    }
  }

  // 合并 ctl 的 profile 输出；字段缺失或类型不对一律忽略，绝不让格式变化把页面搞崩
  function applyProfileJSON(j) {
    if (!j || typeof j !== 'object') return;
    if (Array.isArray(j.list)) {
      var allowed = [];
      j.list.forEach(function (id) {
        if (typeof id === 'string' && PROFILE_META[id] && allowed.indexOf(id) < 0) allowed.push(id);
      });
      if (allowed.length) profileState.list = allowed;
    }
    if (typeof j.device_profile === 'string' && j.device_profile) profileState.current = j.device_profile;
    if (typeof j.current === 'string' && j.current) profileState.current = j.current;
    if (typeof j.detected === 'string' && j.detected) profileState.detected = j.detected;
    if (typeof j.rom === 'string' && j.rom) profileState.rom = j.rom;
    if (num(j.ok) === 1) profileState.supported = true;
    renderProfile();
  }

  function loadProfile() {
    if (!isKsu) {
      profileState.tried = true;
      renderProfile();
      return Promise.resolve();
    }
    if (profileBusy) return Promise.resolve();
    profileBusy = true;
    return sh('profile list').then(function (r) {
      var j = parseJSON(r.stdout);
      if (j && num(j.ok) === 1) {
        applyProfileJSON(j);
        return null;
      }
      // 旧版 ctl 没有 profile 命令（会打印用法文本），再试一次 JSON 形式，仍失败就静默降级
      return sh('profile --json').then(function (r2) {
        var j2 = parseJSON(r2.stdout);
        if (j2 && num(j2.ok) === 1) applyProfileJSON(j2);
        return null;
      }).catch(function () { return null; });
    }).catch(function () {
      return null;
    }).then(function () {
      profileState.tried = true;
      profileBusy = false;
      renderProfile();
    });
  }

  /* 控制台「守护配置」行：engine / device_profile / order / relief_gate，
     wakeups / tight 是可选信息，ctl 带了才显示。 */
  function renderGuard(s) {
    s = s || state.status || {};
    var parts = [];
    if (s.engine === 'cpp') parts.push('C++ 守护');
    else if (s.engine === 'shell') parts.push('Shell 守护');
    if (s.device_profile) parts.push(profileShort(s.device_profile));
    if (s.order) parts.push(s.order === 'kill_first' ? '先杀进程' : '页换出优先');
    if (s.relief_gate !== undefined && s.relief_gate !== null && s.relief_gate !== '') {
      parts.push(num(s.relief_gate) === 1 ? '舒缓门控开' : '舒缓常开');
    }
    var el = $('dvGuard');
    if (el) el.textContent = parts.length ? parts.join(' · ') : '--';

    var info = state.info || {};
    var wake = info.wakeups !== undefined ? info.wakeups : s.wakeups;
    var tight = info.tight !== undefined ? info.tight : s.tight;
    var seg = [];
    if (wake !== undefined && wake !== null && wake !== '' && isFinite(Number(wake))) {
      seg.push('唤醒 ' + num(wake) + ' 次');
    }
    if (tight !== undefined && tight !== null && tight !== '') {
      seg.push(num(tight) === 1 ? '内存紧张' : '内存正常');
    }
    var row = $('rowGuardLive');
    var live = $('dvGuardLive');
    if (!row || !live) return;
    if (seg.length) {
      live.textContent = seg.join(' · ');
      row.classList.remove('hidden');
    } else {
      row.classList.add('hidden');
    }
  }

  /* ------------------------------------------------------------ 确认弹层
     不用 window.confirm：部分 WebView 不弹原生对话框，点确认会像「没反应」。 */
  var confirmResolve = null;

  function confirmDialog(title, text, okLabel) {
    var modal = $('modal');
    if (!modal || !$('modalTitle') || !$('modalText')) return Promise.resolve(false);
    if (confirmResolve) {
      var old = confirmResolve;
      confirmResolve = null;
      old(false);
    }
    $('modalTitle').textContent = title;
    $('modalText').textContent = text;
    if (okLabel && $('modalOk')) $('modalOk').textContent = okLabel;
    modal.classList.add('show');
    modal.setAttribute('aria-hidden', 'false');
    return new Promise(function (resolve) { confirmResolve = resolve; });
  }

  function closeConfirm(result) {
    var modal = $('modal');
    if (modal) {
      modal.classList.remove('show');
      modal.setAttribute('aria-hidden', 'true');
    }
    var r = confirmResolve;
    confirmResolve = null;
    if (r) r(!!result);
  }

  function applyProfile(id, el) {
    if (profileBusy) return;
    if (!isKsu) { toast('请在 KernelSU / KsuWebUI 中打开', true); return; }
    if (!PROFILE_META[id]) { toast('未知的系统档案', true); return; }
    if (id === profileState.current) { toast('已经是「' + profileName(id) + '」档案'); return; }
    if (!profileState.supported) {
      toast('当前 ctl 未提供 profile 命令，请先升级模块', true);
      loadProfile();
      return;
    }
    var text = id === 'generic'
      ? '「通用」只记录系统类型，不覆盖任何参数。确认应用？'
      : '应用「' + profileName(id) + '」会覆盖该档案包含的参数' +
        '（回收周期、内存阈值、页换出、包名保护等），当前自定义设置会被覆盖。确认应用？';
    confirmDialog('切换系统适配', text, '应用').then(function (ok) {
      if (!ok) return;
      profileBusy = true;
      withBusy(el, sh('profile apply ' + q(id)), '已应用：' + profileName(id)).then(function () {
        profileBusy = false;
        setTimeout(function () { loadProfile(); loadConfig(); }, 500);
      });
    });
  }

  /* ------------------------------------------------------------ 动作 */
  function withBusy(el, promise, okText) {
    if (!isKsu) {
      if (promise && promise.catch) promise.catch(function () { });
      toast('请在 KernelSU / KsuWebUI 中打开', true);
      return Promise.resolve();
    }
    state.busy++;
    var was = el ? el.disabled : false;
    if (el) el.disabled = true;
    toast('执行中…');
    return promise.then(function (r) {
      var j = parseJSON(r.stdout) || {};
      if (r.errno !== 0) {
        toast('失败（errno ' + r.errno + '）: ' + (r.stderr || '无输出'), true);
        return;
      }
      if (j.ok === 0) {
        toast('失败: ' + (j.err || r.stderr || '未知错误'), true);
        return;
      }
      if (okText) toast(typeof okText === 'function' ? okText(j) : okText);
      refreshStatus();
    }).catch(function (e) {
      toast('执行出错: ' + (e && e.message ? e.message : e), true);
    }).then(function () {
      state.busy--;
      if (el) el.disabled = was;
    });
  }

  function doRun(el) {
    withBusy(el, sh('run --json'), function (j) {
      if (j.skipped) return '跳过：' + (j.reason || '');
      return '释放 ' + j.freed + ' MB，回收 ' + j.kills + ' 个进程';
    });
  }

  function doRelief(el) {
    withBusy(el, sh('apprelief --force --json'), function (j) {
      if (!j.pkg) return '没检测到前台应用';
      return j.pkg + '：' + j.pss_before + '→' + j.pss_after + ' MB';
    });
  }

  function doScan(el) {
    if (!isKsu) { toast('请在 KernelSU / KsuWebUI 中打开', true); return; }
    el.disabled = true;
    sh('scan').then(function (r) {
      var out = $('scanOut');
      out.textContent = (r.stdout || '（无候选）') + (r.stderr ? '\n' + r.stderr : '');
      out.classList.remove('hidden');
      toast('扫描完成');
    }).catch(function (e) {
      toast('扫描失败: ' + e.message, true);
    }).then(function () { el.disabled = false; });
  }

  function doRestart(el) {
    withBusy(el, sh('restart'), '守护已重启');
  }

  /* ------------------------------------------------------------ 日志 */
  var lastLogText = '';

  function loadLog(force) {
    if (!isKsu) {
      $('logOut').textContent = '需要在 KernelSU / KsuWebUI 中打开才能读取日志。';
      return Promise.resolve();
    }
    // 只取 120 行，且内容没变化时不重写 DOM，避免长文本反复布局造成卡顿
    return sh('log 120').then(function (r) {
      var text = r.stdout || '';
      if (r.errno !== 0 && r.stderr) text += '\n[stderr] ' + r.stderr;
      if (!text) text = '（日志为空）';
      if (force || text !== lastLogText) {
        lastLogText = text;
        $('logOut').textContent = text;
      }
      var m = text.match(/# size\s*:\s*(\d+) bytes,\s*(\d+) lines/);
      if (m) {
        $('logMeta').textContent = MOD + '/log/reclaim.log · ' + m[1] + ' 字节 · ' + m[2] + ' 行';
      } else {
        $('logMeta').textContent = MOD + '/log/reclaim.log';
      }
    }).catch(function (e) {
      $('logOut').textContent = '读取日志失败: ' + e.message;
    });
  }

  function doDoctor(el) {
    if (!isKsu) { toast('请在 KernelSU / KsuWebUI 中打开', true); return; }
    el.disabled = true;
    sh('doctor').then(function (r) {
      $('doctorOut').textContent = (r.stdout || '') + (r.stderr ? '\n[stderr]\n' + r.stderr : '');
      toast('自检完成');
    }).catch(function (e) {
      $('doctorOut').textContent = '自检失败: ' + e.message;
    }).then(function () { el.disabled = false; });
  }

  /* ------------------------------------------------------------ 配置 */
  var BASIC = [
    { k: 'enable', t: 'switch', label: '启用模块', hint: '关闭后不再回收（VM 调参也会停）' },
    { k: 'mem_low_mb', t: 'number', label: '触发阈值', unit: 'MB', hint: '可用内存低于它就回收' },
    { k: 'mem_target_mb', t: 'number', label: '目标内存', unit: 'MB' },
    { k: 'max_kills_per_run', t: 'number', label: '单轮最多', unit: '个' },
    { k: 'max_kills_per_hour', t: 'number', label: '每小时上限', unit: '个' },
    { k: 'min_frozen_min', t: 'number', label: '至少冻结', unit: '分钟' },
    { k: 'min_process_mb', t: 'number', label: '忽略小进程', unit: 'MB' },
    { k: 'app_reclaim', t: 'switch', label: '前台舒缓' },
    { k: 'relief_gate', t: 'switch', label: '舒缓门控', hint: '只在内存紧张时舒缓前台，省电' },
    { k: 'app_pss_mb', t: 'number', label: '前台阈值', unit: 'MB' },
    { k: 'app_pageout', t: 'switch', label: '前台页换出' },
    { k: 'screen_off_only', t: 'switch', label: '仅息屏回收' },
    { k: 'dry_run', t: 'switch', label: '演练模式', hint: '只记录，不杀也不 trim' }
  ];

  var ADVANCED = [
    { k: 'interval', t: 'number', label: '检查周期', unit: '秒' },
    { k: 'max_rounds', t: 'number', label: '单轮批次数' },
    { k: 'cooldown_sec', t: 'number', label: '回收冷却', unit: '秒' },
    { k: 'high_pss_mb', t: 'number', label: '大进程看门狗', unit: 'MB' },
    { k: 'high_pss_interval', t: 'number', label: '看门狗周期', unit: '秒' },
    { k: 'min_oom_score_adj', t: 'number', label: '最低 oom_score_adj' },
    { k: 'only_frozen', t: 'switch', label: '只回收已冻结进程' },
    { k: 'kill_mode', t: 'select', label: '回收方式', options: [['pid', '精确 PID'], ['am', 'am kill 整包']] },
    { k: 'protect_foreground', t: 'switch', label: '保护前台应用' },
    { k: 'deep_reclaim', t: 'switch', label: '深回收' },
    { k: 'deep_pageout_max_mb', t: 'number', label: '深回收上限', unit: 'MB' },
    {
      k: 'reclaim_order', t: 'select', label: '回收顺序',
      options: [['pageout_first', '先换出（推荐）'], ['kill_first', '先杀进程']]
    },
    { k: 'drop_caches', t: 'switch', label: '清页缓存' },
    { k: 'drop_caches_cooldown', t: 'number', label: '清页缓存冷却', unit: '秒' },
    { k: 'psi_enable', t: 'switch', label: 'PSI 压力触发' },
    { k: 'psi_some_avg10', t: 'number', label: 'PSI 阈值' },
    { k: 'mem_low_pct', t: 'number', label: '阈值百分比', unit: '%' },
    { k: 'mem_target_pct', t: 'number', label: '目标百分比', unit: '%' },
    { k: 'app_reclaim_interval', t: 'number', label: '前台检查周期', unit: '秒' },
    { k: 'app_reclaim_cooldown', t: 'number', label: '前台冷却', unit: '秒' },
    {
      k: 'app_trim_level', t: 'select', label: 'trim 级别',
      options: [['RUNNING_MODERATE', 'MODERATE'], ['RUNNING_LOW', 'LOW'], ['RUNNING_CRITICAL', 'CRITICAL']]
    },
    { k: 'app_trim_all_pids', t: 'switch', label: 'trim 全部进程' },
    { k: 'app_pageout_max_mb', t: 'number', label: '前台换出上限', unit: 'MB' },
    { k: 'app_pageout_passes', t: 'number', label: '前台换出轮数' },
    { k: 'daemon_engine', t: 'select', label: '守护引擎', options: [['cpp', 'C++（推荐）'], ['shell', 'Shell（兼容）']] },
    { k: 'vm_tune', t: 'switch', label: 'VM 调参' },
    { k: 'zram_enable', t: 'switch', label: '启用 zram' },
    { k: 'zram_disksize_mb', t: 'number', label: 'zram 大小', unit: 'MB' },
    {
      k: 'zram_algorithm', t: 'select', label: 'zram 算法',
      options: [['lz4', 'lz4（快）'], ['lz4hc', 'lz4hc'], ['zstd', 'zstd'], ['lzo-rle', 'lzo-rle']]
    },
    { k: 'swapfile_enable', t: 'switch', label: '启用 swapfile' },
    { k: 'swapfile_mb', t: 'number', label: 'swapfile 大小', unit: 'MB' },
    { k: 'swappiness', t: 'number', label: 'swappiness' },
    { k: 'vfs_cache_pressure', t: 'number', label: 'vfs_cache_pressure' },
    { k: 'keepalive', t: 'switch', label: '保活看门狗' },
    { k: 'watchdog_interval', t: 'number', label: '看门狗周期', unit: '秒' },
    { k: 'heartbeat_timeout', t: 'number', label: '心跳超时', unit: '秒' },
    { k: 'heartbeat_sec', t: 'number', label: '心跳间隔', unit: '秒' },
    { k: 'oom_protect', t: 'switch', label: '守护进程防 LMK' },
    { k: 'log_max_kb', t: 'number', label: '日志上限', unit: 'KB' },
    { k: 'exclude_packages', t: 'text', label: '永不回收的包', hint: '分号分隔，支持 *' }
  ];

  function buildForm(el, spec) {
    el.innerHTML = '';
    spec.forEach(function (f) {
      var row = document.createElement('div');
      row.className = 'row';

      var main = document.createElement('div');
      main.className = 'row-main';
      var lab = document.createElement('span');
      lab.className = 'row-label';
      lab.textContent = f.label;
      // 开关类加一个行内状态位：保存中 / 已保存 / 失败
      if (f.t === 'switch') {
        var st = document.createElement('span');
        st.className = 'row-state';
        lab.appendChild(st);
      }
      main.appendChild(lab);
      if (f.hint) {
        var h = document.createElement('span');
        h.className = 'row-hint';
        h.textContent = f.hint;
        main.appendChild(h);
      }

      var input;
      if (f.t === 'switch') {
        input = document.createElement('input');
        input.type = 'checkbox';
        input.className = 'sw';
        input.checked = num(state.cfg[f.k]) === 1;
      } else if (f.t === 'select') {
        input = document.createElement('select');
        f.options.forEach(function (o) {
          var op = document.createElement('option');
          op.value = o[0];
          op.textContent = o[1];
          input.appendChild(op);
        });
        input.value = state.cfg[f.k] || f.options[0][0];
      } else {
        input = document.createElement('input');
        input.type = f.t === 'number' ? 'number' : 'text';
        input.value = state.cfg[f.k] !== undefined ? state.cfg[f.k] : '';
        input.inputMode = f.t === 'number' ? 'numeric' : 'text';
      }
      input.dataset.k = f.k;
      // 非开关控件记「脏」标记：只有改过的字段才会被「保存设置」提交
      if (f.t !== 'switch') {
        input.addEventListener('change', function () { this.dataset.dirty = '1'; });
        input.addEventListener('input', function () { this.dataset.dirty = '1'; });
      }

      row.appendChild(main);
      if (f.unit) {
        var wrap = document.createElement('div');
        wrap.style.display = 'flex';
        wrap.style.alignItems = 'center';
        var u = document.createElement('span');
        u.className = 'unit';
        u.textContent = f.unit;
        wrap.appendChild(input);
        wrap.appendChild(u);
        row.appendChild(wrap);
      } else {
        row.appendChild(input);
      }
      el.appendChild(row);
    });
  }

  function parseConfig(text) {
    var out = {};
    (text || '').split('\n').forEach(function (line) {
      var l = line.trim();
      if (!l || l.charAt(0) === '#') return;
      var i = l.indexOf('=');
      if (i <= 0) return;
      var k = l.slice(0, i).trim();
      var v = l.slice(i + 1).trim();
      if (v.indexOf('#') > 0 && /[ \t]#/.test(v)) v = v.replace(/[ \t]#.*$/, '');
      // ctl.sh save 会把「所有」值写成单引号（exclude_packages='a;b'、enable='1'），
      // 这里统一剥一层引号。以前只对 QUOTED 里的键剥，导致保存过一次之后
      // enable 变成 '1'，num("'1'") = 0，切页面回来开关就显示成关闭。
      v = v.replace(/^'(.*)'$/, '$1').replace(/^"(.*)"$/, '$1');
      out[k] = v;
    });
    return out;
  }

  function applyConfigText(text, note) {
    state.configLoaded = true;
    $('btnSave').disabled = false;
    $('saveHint').textContent = '配置已加载' + (note ? '（' + note + '）' : '') + ' · 修改后守护会自动重读';
    state.cfg = parseConfig(text);
    state.cfgMeta = 'text:' + Object.keys(state.cfg).length + ' keys';
    buildForm($('formBasic'), BASIC);
    buildForm($('formAdvanced'), ADVANCED);
    Array.prototype.forEach.call(document.querySelectorAll('.preset'), function (b) {
      b.classList.toggle('active', b.dataset.preset === state.cfg.profile);
    });
  }

  // 用 ctl.sh configjson 的单行 JSON 填表：不再让前端去解析多行配置文本
  // （配置文件有注释 / 行内注释 / 单引号，历史上就是这里出的问题）
  function applyConfigJSON(j) {
    var cfg = {};
    Object.keys(j).forEach(function (k) {
      if (k === 'ok' || k.charAt(0) === '_') return;
      cfg[k] = (j[k] === null || j[k] === undefined) ? '' : String(j[k]);
    });
    var n = Object.keys(cfg).length;
    state.cfg = cfg;
    state.configLoaded = n > 0;
    state.cfgMeta = 'JSON:' + n + ' keys';
    $('btnSave').disabled = !state.configLoaded;
    $('saveHint').textContent = state.configLoaded
      ? '配置已加载（' + n + ' 项 / 文件 ' + (j._bytes || '?') + ' 字节）· 修改后守护会自动重读'
      : '配置是空的，已禁用保存';
    buildForm($('formBasic'), BASIC);
    buildForm($('formAdvanced'), ADVANCED);
    Array.prototype.forEach.call(document.querySelectorAll('.preset'), function (b) {
      b.classList.toggle('active', b.dataset.preset === state.cfg.profile);
    });
  }

  function loadConfigText() {
    return sh('config').then(function (r) {
      var text = r.stdout || '';
      if (r.errno === 0 && /^[a-z_][a-z0-9_]*=/m.test(text)) {
        applyConfigText(text, '');
        return null;
      }
      // 兜底：ctl 失败或输出异常时，直接读配置文件再试一次
      return raw('cat ' + CONF).then(function (r2) {
        if (r2.errno === 0 && /^[a-z_][a-z0-9_]*=/m.test(r2.stdout || '')) {
          applyConfigText(r2.stdout || '', '直接读取');
          return null;
        }
        state.configLoaded = false;
        $('btnSave').disabled = true;
        var err = (r.stderr || '') + (r2.stderr ? ' | ' + r2.stderr : '');
        $('saveHint').textContent =
          '读取配置失败（' + CONF + '）' +
          (err ? '：' + err : '，文件可能不存在。') +
          ' 请点「自检」查看路径与权限；若刚刷入还没重启，请先重启（KernelSU 安装后位于 modules_update）。';
        toast('配置读取失败，已禁用保存', true);
        return null;
      });
    }).catch(function (e) {
      state.configLoaded = false;
      $('btnSave').disabled = true;
      $('saveHint').textContent = '读取配置失败：' + e.message;
      toast('配置读取失败: ' + e.message, true);
    });
  }

  function loadConfig() {
    if (!isKsu) {
      $('saveHint').textContent = '需要在 KernelSU / KsuWebUI 中打开才能读写配置。';
      return Promise.resolve();
    }
    // 首选单行 JSON（新版 ctl）；失败再退回解析配置文本（老版 ctl）
    return sh('configjson').then(function (r) {
      var j = parseJSON(r.stdout);
      if (j && j.ok && j._loaded) { applyConfigJSON(j); return null; }
      return loadConfigText();
    }).catch(function () { return loadConfigText(); });
  }

  function saveConfig(el) {
    if (!isKsu || !state.configLoaded) { toast('配置未成功加载，拒绝保存', true); return; }
    var pairs = [];
    // 只提交「用户真正改过」的字段：避免表单没读到配置时把空值写回去
    // （以前会把 exclude_packages 写成空串，等于清空排除名单）
    Array.prototype.forEach.call(document.querySelectorAll('[data-k]'), function (input) {
      var k = input.dataset.k;
      var v;
      if (input.type === 'checkbox') {
        if (!(k in state.cfg)) return;
        v = input.checked ? '1' : '0';
        if (String(state.cfg[k]) === v) return;
      } else {
        if (input.dataset.dirty !== '1') return;
        v = String(input.value).trim();
        if (v === '' && !QUOTED[k]) return;
        var old = state.cfg[k] === undefined ? '' : String(state.cfg[k]);
        if (old === v) return;
      }
      pairs.push(k + '=' + v);
    });
    if (!pairs.length) { toast('没有需要保存的改动'); return; }

    var was = el ? el.disabled : false;
    if (el) el.disabled = true;
    savePairs(pairs).then(function (res) {
      if (el) el.disabled = was;
      if (!res || !res.ok) { toast('保存失败：' + saveErrText(res), true); return; }
      toast('设置已保存');
      setTimeout(loadConfig, 500);
    }).catch(function (e) {
      if (el) el.disabled = was;
      toast('保存失败：' + e.message, true);
    });
  }

  /* ------------------------------------------------------------ 保存通道
     ksu.exec 是同步的；不同管理器的实现细节不一样（有的命令串会经过 sh -c，
     有的场景下 stdin / 管道不按预期工作）。这里用两条通道：
       1) 参数形式：sh ctl.sh set 'k=v' 'k=v'   —— 不依赖 stdin / 管道
       2) 兜底通道：printf ... | sh ctl.sh save —— 旧通道
     并且把保存串行化，避免连点时先后顺序错乱。 */
  var saveChain = Promise.resolve();

  function savePairs(pairs) {
    var job = saveChain.then(function () { return doSavePairs(pairs); });
    saveChain = job.then(function () { return null; }, function () { return null; });
    return job;
  }

  function doSavePairs(pairs) {
    var quoted = pairs.map(q).join(' ');
    var argCmd = SH + ' ' + CTL + ' set ' + quoted;
    return raw(argCmd).then(function (r) {
      var j = parseJSON(r.stdout);
      if (j && j.ok) {
        recordSave('set', argCmd, r);
        return { ok: true, via: 'set', r: r };
      }
      var pipeCmd = "printf '%s\\n' " + quoted + ' | ' + SH + ' ' + CTL + ' save';
      return raw(pipeCmd).then(function (r2) {
        var j2 = parseJSON(r2.stdout);
        if (j2 && j2.ok) {
          recordSave('pipe', pipeCmd, r2);
          return { ok: true, via: 'pipe', r: r2 };
        }
        recordSave('fail', pipeCmd, r2, r);
        return { ok: false, via: 'both', first: r, second: r2 };
      });
    });
  }

  function saveErrText(res) {
    if (!res) return '无返回';
    var out = [];
    [res.first, res.second, res.r].forEach(function (r) {
      if (!r) return;
      var j = parseJSON(r.stdout);
      if (j && j.err) out.push(j.err);
      else if (r.stderr) out.push(String(r.stderr).trim());
      else if (r.stdout) out.push(String(r.stdout).trim());
      if (r.errno) out.push('errno=' + r.errno);
    });
    return out.length ? out.join(' / ') : '未知错误';
  }

  function recordSave(via, cmd, r, first) {
    state.lastSave = {
      at: new Date().toLocaleString(),
      via: via,
      cmd: cmd,
      errno: r ? r.errno : -1,
      stdout: r ? String(r.stdout || '') : '',
      stderr: r ? String(r.stderr || '') : '',
      first: first ? { errno: first.errno, stdout: String(first.stdout || ''), stderr: String(first.stderr || '') } : null
    };
    var pre = $('saveDiagOut');
    if (pre && via === 'fail') { pre.textContent = saveDiagText(); }
  }

  function saveDiagText() {
    var L = [];
    var s = state.lastSave;
    L.push('# 配置: ' + CONF);
    L.push('# 通道: ' + (s ? s.via : '未保存过'));
    if (s) {
      L.push('# 时间: ' + s.at);
      L.push('# 命令: ' + s.cmd);
      L.push('# errno=' + s.errno + '  stdout=' + JSON.stringify(s.stdout) + '  stderr=' + JSON.stringify(s.stderr));
      if (s.first) {
        L.push('# 通道1(set) errno=' + s.first.errno + ' stdout=' + JSON.stringify(s.first.stdout) + ' stderr=' + JSON.stringify(s.first.stderr));
      }
    }
    L.push('# 界面缓存: ' + JSON.stringify({
      configLoaded: state.configLoaded,
      meta: state.cfgMeta || '?',
      keys: Object.keys(state.cfg).length,
      enable: state.cfg.enable, dry_run: state.cfg.dry_run,
      app_reclaim: state.cfg.app_reclaim, relief_gate: state.cfg.relief_gate
    }));
    return L.join('\n');
  }

  // 核对：把配置文件重新读一遍，和界面上的开关逐项比对
  function diagConfig() {
    var head = saveDiagText();
    var pre = $('saveDiagOut');
    if (pre) pre.textContent = head + '\n# 正在读取配置…';
    var jsonInfo = '';
    return sh('configjson').then(function (rj) {
      var j = parseJSON(rj.stdout);
      if (j && j.ok && j._loaded) {
        var ks = Object.keys(j).filter(function (k) { return k !== 'ok' && k.charAt(0) !== '_'; });
        jsonInfo = '# configjson: OK keys=' + ks.length + ' _bytes=' + j._bytes + ' _lines=' + j._lines +
          '\n#   enable=' + j.enable + ' dry_run=' + j.dry_run + ' app_reclaim=' + j.app_reclaim +
          ' relief_gate=' + j.relief_gate +
          '\n#   exclude_packages(前60)=' + String(j.exclude_packages || '').slice(0, 60);
      } else {
        jsonInfo = '# configjson: FAILED errno=' + rj.errno +
          ' out=' + String(rj.stdout || '').slice(0, 120) +
          ' err=' + String(rj.stderr || '').slice(0, 120);
      }
      return sh('config');
    }).then(function (r) {
      var text = r.stdout || '';
      if (r.errno !== 0 || !/^[a-z_][a-z0-9_]*=/m.test(text)) {
        return raw('cat ' + CONF).then(function (r2) {
          return { text: r2.stdout || '', note: 'ctl config 失败(errno=' + r.errno + ' stderr=' + (r.stderr || '') + ')，改用 cat，errno=' + r2.errno + (r2.stderr ? ' stderr=' + r2.stderr : '') };
        });
      }
      return { text: text, note: 'ctl config ok' };
    }).then(function (res) {
      var parsed = parseConfig(res.text);
      var keys = Object.keys(parsed);
      var diffs = [];
      ['enable', 'dry_run', 'app_reclaim', 'relief_gate', 'only_frozen', 'deep_reclaim',
       'keepalive', 'oom_protect', 'protect_foreground', 'psi_enable'].forEach(function (k) {
        if (parsed[k] === undefined) { diffs.push(k + ' 文件里没有'); return; }
        if (state.cfg[k] !== undefined && String(state.cfg[k]) !== String(parsed[k])) {
          diffs.push(k + ' 界面=' + state.cfg[k] + ' 文件=' + parsed[k]);
        }
      });
      var out = head +
        '\n' + jsonInfo +
        '\n# ' + res.note +
        '\n# 前端从文本里解析到 ' + keys.length + ' 个键' +
        '\n# 界面已加载 ' + Object.keys(state.cfg).length + ' 个键 (' + (state.cfgMeta || '?') + ')' +
        '\n# 不一致: ' + (diffs.length ? diffs.join('; ') : '无') +
        '\n\n--- 原始配置（前 3000 字符） ---\n' + String(res.text).slice(0, 3000);
      state.diagText = out;
      var pre2 = $('saveDiagOut');
      if (pre2) pre2.textContent = out;
      return out;
    }).catch(function (e) {
      var out = head + '\n' + jsonInfo + '\n# 读取失败: ' + e.message;
      state.diagText = out;
      var pre3 = $('saveDiagOut');
      if (pre3) pre3.textContent = out;
      return out;
    });
  }

  function setRowState(row, cls, text, autoClear) {
    if (!row || !row.querySelector) return;
    var s = row.querySelector('.row-state');
    if (!s) return;
    s.className = 'row-state' + (cls ? ' ' + cls : '');
    s.textContent = text || '';
    if (autoClear) {
      clearTimeout(s._t);
      s._t = setTimeout(function () {
        s.className = 'row-state';
        s.textContent = '';
      }, 1800);
    }
  }

  // 开关改动立即保存：先乐观标记「保存中」，失败才回滚并说明原因
  function autoSaveSwitch(el) {
    if (!isKsu || !state.configLoaded) {
      el.checked = !el.checked;
      toast('配置还没加载成功，改动不会保存', true);
      return;
    }
    var k = el.dataset.k;
    var v = el.checked ? '1' : '0';
    var row = el.closest ? el.closest('.row') : null;
    el.disabled = true;
    setRowState(row, 'saving', '保存中');
    savePairs([k + '=' + v]).then(function (res) {
      el.disabled = false;
      if (res && res.ok) {
        state.cfg[k] = v;
        setRowState(row, 'ok', '已保存', true);
        toast('已保存：' + k + ' = ' + v);
        refreshStatus();
      } else {
        el.checked = !el.checked;
        setRowState(row, 'fail', '失败');
        toast('保存失败，已还原：' + saveErrText(res), true);
      }
    }).catch(function (e) {
      el.disabled = false;
      el.checked = !el.checked;
      setRowState(row, 'fail', '失败');
      toast('保存失败，已还原：' + e.message, true);
    });
  }

  function applyPreset(name, el) {
    withBusy(el, sh('preset ' + name), function () {
      return '已切换到「' + ({ conservative: '保守', balanced: '均衡', aggressive: '激进' }[name] || name) + '」';
    }).then(function () {
      setTimeout(function () { loadConfig(); refreshStatus(); }, 600);
    });
  }

  /* ------------------------------------------------------------ 日志 / 诊断 */
  function doDoctorForCopy() {
    return sh('doctor').then(function (r) {
      return (r.stdout || '') + (r.stderr ? '\n' + r.stderr : '');
    }).catch(function () { return ''; });
  }

  function copyText(text) {
    // 剪贴板在 WebView 里经常不可用：navigator.clipboard 可能因为非安全上下文直接 reject，
    // 所以失败后必须退回 textarea + execCommand 的老办法，两步都失败才算失败。
    function fallback() {
      return new Promise(function (resolve, reject) {
        var ta = null;
        try {
          ta = document.createElement('textarea');
          ta.value = text;
          ta.setAttribute('readonly', '');
          ta.style.position = 'fixed';
          ta.style.top = '0';
          ta.style.left = '0';
          ta.style.width = '1px';
          ta.style.height = '1px';
          ta.style.opacity = '0.02';
          ta.style.userSelect = 'text';
          ta.style.webkitUserSelect = 'text';
          document.body.appendChild(ta);
          ta.focus();
          ta.select();
          var ok = false;
          try { ok = document.execCommand('copy'); } catch (e2) { ok = false; }
          document.body.removeChild(ta);
          ta = null;
          ok ? resolve() : reject(new Error('此 WebView 不支持剪贴板'));
        } catch (e) {
          if (ta && ta.parentNode) { try { ta.parentNode.removeChild(ta); } catch (e3) { } }
          reject(e);
        }
      });
    }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(text).catch(function () { return fallback(); });
    }
    return fallback();
  }

  // 把一段文本追加写到设备文件（不经过剪贴板，也不依赖 stdin）
  function writeTextFile(text) {
    return sh('diagfile').then(function (r) {
      var j = parseJSON(r.stdout) || {};
      if (!j.ok || !j.path) throw new Error(j.err || r.stderr || 'ctl.sh diagfile 不可用（旧版 ctl）');
      var cmd = "printf '%s\\n' " + q(text) + ' >> ' + q(j.path);
      return raw(cmd).then(function () { return j.path; });
    });
  }

  function doCopyDiag(el) {
    if (!isKsu) { toast('请在 KernelSU / KsuWebUI 中打开', true); return; }
    el.disabled = true;
    var text = '';
    doDoctorForCopy().then(function (t) {
      if (!t) throw new Error('自检为空');
      text = t;
      $('doctorOut').textContent = t;
      return copyText(t);
    }).then(function () {
      toast('诊断信息已复制');
    }).catch(function (e) {
      // 剪贴板不可用时直接落盘，信息总能带出来
      return writeTextFile(text + '\n').then(function (path) {
        toast('剪贴板不可用，已保存到 ' + path);
      }).catch(function (e2) {
        toast('复制失败: ' + e.message + '；落盘也失败: ' + e2.message, true);
      });
    }).then(function () { el.disabled = false; });
  }

  // 场景页：把 ctl 侧诊断 + WebUI 侧诊断一起写成文件
  function saveDiagToFile(el) {
    if (!isKsu) { toast('请在 KernelSU / KsuWebUI 中打开', true); return; }
    var was = el ? el.disabled : false;
    if (el) el.disabled = true;
    var uiText = '\n===== WebUI 侧诊断 =====\n' + saveDiagText() + '\n' +
      'UA: ' + (navigator.userAgent || '?') + '\n';
    writeTextFile(uiText).then(function (path) {
      state.diagFile = path;
      var out = '已保存到：' + path + '\n（用文件管理器打开 /sdcard/Download 即可发邮件）\n\n' +
        (state.diagText || '');
      var pre = $('saveDiagOut');
      if (pre) pre.textContent = out;
      toast('已保存到 ' + path);
    }).catch(function (e) {
      toast('保存失败：' + e.message, true);
    }).then(function () { if (el) el.disabled = was; });
  }

  function doMail(el) {
    el.disabled = true;
    doDoctorForCopy().then(function (text) {
      var ver = ($('ver').textContent || '').trim();
      var body = [
        '问题描述：', '', '',
        '复现步骤：', '1. ', '2. ', '',
        '--- 自检 / 诊断 ---',
        (text || '').slice(0, 2400),
        '',
        '（如被截断，请把「复制诊断」的完整内容粘贴到这里）'
      ].join('\n');
      var url = 'mailto:' + MAIL +
        '?subject=' + encodeURIComponent('[Cirno Reclaim ' + ver + '] 问题反馈') +
        '&body=' + encodeURIComponent(body);
      window.location.href = url;
      el.disabled = false;
    });
  }

  /* ------------------------------------------------------------ 外观 */
  var theme = {
    theme: 'auto', bg: 'solid', bgurl: '', alpha: 92, accent: 'green',
    radius: 28, dim: 78, nav: 'pill', perf: 0, liquid: 1
  };

  function numOr(v, d) {
    var n = Number(v);
    return isFinite(n) && n > 0 ? n : d;
  }

  function movePill() {
    var bar = $('tabbar');
    var pill = $('tabPill');
    if (!bar || !pill) return;
    var active = bar.querySelector('.tab.active');
    if (!active) return;
    var br = bar.getBoundingClientRect();
    var ar = active.getBoundingClientRect();
    pill.style.width = ar.width + 'px';
    pill.style.transform = 'translateX(' + (ar.left - br.left - 8) + 'px)';
    // 液态玻璃滤镜依赖滑块的宽高：尺寸变了才重建滤镜，纯位移不重建
    applyLiquidPill();
  }

  /* ------------------------------------------------------------ 液态玻璃（移植）
     getDisplacementMap / getDisplacementFilter 移植自 MIT 开源项目：
       nikdelvin/liquid-glass — https://github.com/nikdelvin/liquid-glass
       MIT License © Nik Delvin（许可见 THIRD-PARTY-NOTICES.md）
     上游把 SVG 位移贴图 + 色散滤镜塞进 backdrop-filter 做真实折射；
     这里把同一套滤镜用在「底栏滑块」上：面积只有几十像素、只在切换标签时
     重绘一次，Android WebView 也扛得住；不支持 backdrop-filter: url() 时自动跳过。 */
  var lgSupported = (function () {
    try {
      var el = document.createElement('div');
      el.style.cssText = 'backdrop-filter: url(#test)';
      return el.style.backdropFilter === 'url(#test)' ||
        el.style.backdropFilter === 'url("#test")';
    } catch (e) { return false; }
  })();

  function lgDisplacementMap(o) {
    var h = o.height, w = o.width, r = o.radius, d = o.depth;
    return 'data:image/svg+xml;utf8,' + encodeURIComponent(
      '<svg height="' + h + '" width="' + w + '" viewBox="0 0 ' + w + ' ' + h +
      '" xmlns="http://www.w3.org/2000/svg"><style>.mix{mix-blend-mode:screen}</style><defs>' +
      '<linearGradient id="Y" x1="0" x2="0" y1="' + Math.ceil(r / h * 15) + '%" y2="' +
      Math.floor(100 - r / h * 15) + '%"><stop offset="0%" stop-color="#0F0"/>' +
      '<stop offset="100%" stop-color="#000"/></linearGradient>' +
      '<linearGradient id="X" x1="' + Math.ceil(r / w * 15) + '%" x2="' +
      Math.floor(100 - r / w * 15) + '%" y1="0" y2="0"><stop offset="0%" stop-color="#F00"/>' +
      '<stop offset="100%" stop-color="#000"/></linearGradient></defs>' +
      '<rect x="0" y="0" height="' + h + '" width="' + w + '" fill="#808080"/>' +
      '<g filter="blur(2px)">' +
      '<rect x="0" y="0" height="' + h + '" width="' + w + '" fill="#000080"/>' +
      '<rect x="0" y="0" height="' + h + '" width="' + w + '" fill="url(#Y)" class="mix"/>' +
      '<rect x="0" y="0" height="' + h + '" width="' + w + '" fill="url(#X)" class="mix"/>' +
      '<rect x="' + d + '" y="' + d + '" height="' + (h - 2 * d) + '" width="' + (w - 2 * d) +
      '" fill="#808080" rx="' + r + '" ry="' + r + '" filter="blur(' + d + 'px)"/></g></svg>');
  }

  function lgDisplacementFilter(o) {
    var h = o.height, w = o.width, r = o.radius, d = o.depth;
    var s = o.strength == null ? 100 : o.strength;
    var c = o.chromaticAberration == null ? 0 : o.chromaticAberration;
    var map = lgDisplacementMap({ height: h, width: w, radius: r, depth: d });
    return 'data:image/svg+xml;utf8,' + encodeURIComponent(
      '<svg height="' + h + '" width="' + w + '" viewBox="0 0 ' + w + ' ' + h +
      '" xmlns="http://www.w3.org/2000/svg"><defs><filter id="displace" color-interpolation-filters="sRGB">' +
      '<feImage x="0" y="0" height="' + h + '" width="' + w + '" href="' + map +
      '" result="displacementMap"/>' +
      '<feDisplacementMap in="SourceGraphic" in2="displacementMap" scale="' + (s + c * 2) +
      '" xChannelSelector="R" yChannelSelector="G"/>' +
      '<feColorMatrix type="matrix" values="1 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 1 0" result="displacedR"/>' +
      '<feDisplacementMap in="SourceGraphic" in2="displacementMap" scale="' + (s + c) +
      '" xChannelSelector="R" yChannelSelector="G"/>' +
      '<feColorMatrix type="matrix" values="0 0 0 0 0  0 1 0 0 0  0 0 0 0 0  0 0 0 1 0" result="displacedG"/>' +
      '<feDisplacementMap in="SourceGraphic" in2="displacementMap" scale="' + s +
      '" xChannelSelector="R" yChannelSelector="G"/>' +
      '<feColorMatrix type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 1 0 0  0 0 0 1 0" result="displacedB"/>' +
      '<feBlend in="displacedR" in2="displacedG" mode="screen"/>' +
      '<feBlend in2="displacedB" mode="screen"/></filter></defs></svg>') + '#displace';
  }

  var lgLastW = -1, lgLastH = -1, lgApplied = false;

  function applyLiquidPill() {
    var bar = $('tabbar');
    var pill = $('tabPill');
    if (!bar || !pill) return;
    var root = document.documentElement;
    var perf = theme.perf === 1 || theme.perf === '1';
    var want = num(theme.liquid === undefined ? 1 : theme.liquid) === 1 && !perf && lgSupported;

    if (!want) {
      root.classList.remove('liquid-on');
      if (lgApplied) {
        pill.style.backdropFilter = '';
        pill.style.webkitBackdropFilter = '';
        lgApplied = false;
        lgLastW = -1;
        lgLastH = -1;
      }
      return;
    }
    root.classList.add('liquid-on');

    var active = bar.querySelector('.tab.active');
    var w = active ? Math.round(active.getBoundingClientRect().width) : 0;
    var h = Math.round(pill.getBoundingClientRect().height);
    if (w < 12 || h < 12) return;
    if (w === lgLastW && h === lgLastH) return;

    var radius = 22;
    try {
      if (window.getComputedStyle) {
        var cs = window.getComputedStyle(pill);
        if (cs) {
          var rr = parseFloat(cs.borderTopLeftRadius);
          if (isFinite(rr) && rr > 0) radius = rr;
        }
      }
    } catch (e) { radius = 22; }
    var depth = Math.max(4, Math.round(h / 6));
    if (depth > Math.floor(h / 3)) depth = Math.max(3, Math.floor(h / 3));
    var strength = Math.round(Math.min(24, h * 0.6));
    try {
      var url = lgDisplacementFilter({
        height: h, width: w,
        radius: Math.min(radius, h / 2),
        depth: depth, strength: strength, chromaticAberration: 2
      });
      var css = "blur(.5px) url('" + url + "') blur(.4px) saturate(1.35) brightness(1.05)";
      pill.style.backdropFilter = css;
      pill.style.webkitBackdropFilter = css;
      lgApplied = true;
      lgLastW = w;
      lgLastH = h;
    } catch (e) {
      root.classList.remove('liquid-on');
      lgApplied = false;
    }
  }

  function applyTheme() {
    var root = document.documentElement;
    root.setAttribute('data-theme', theme.theme);
    root.setAttribute('data-accent', theme.accent || 'green');

    var a = numOr(theme.alpha, 92);
    root.style.setProperty('--alpha', String(a / 100));
    root.style.setProperty('--radius', numOr(theme.radius, 28) + 'px');
    root.style.setProperty('--dim', String(numOr(theme.dim, 78) / 100));

    if (theme.perf === 1 || theme.perf === '1') root.classList.add('no-blur');
    else root.classList.remove('no-blur');

    var img = '';
    if (theme.bg === 'image') {
      img = theme.bgurl || localStorage.getItem('cr.bg') || '';
    }
    root.style.setProperty('--bg-image', img ? 'url("' + img.replace(/"/g, '%22') + '")' : 'none');

    var dark = theme.theme === 'dark' ||
      (theme.theme !== 'light' && window.matchMedia &&
       window.matchMedia('(prefers-color-scheme: dark)').matches);
    var meta = document.getElementById('metaTheme');
    if (meta) meta.setAttribute('content', dark ? '#0b1016' : '#f4f5f7');
    root.style.colorScheme = dark ? 'dark' : 'light';

    Array.prototype.forEach.call(document.querySelectorAll('#segTheme button'), function (b) {
      b.classList.toggle('active', b.dataset.theme === theme.theme);
    });
    Array.prototype.forEach.call(document.querySelectorAll('#segBg button'), function (b) {
      b.classList.toggle('active', b.dataset.bg === theme.bg);
    });
    Array.prototype.forEach.call(document.querySelectorAll('#segNav button'), function (b) {
      b.classList.toggle('active', b.dataset.nav === theme.nav);
    });
    Array.prototype.forEach.call(document.querySelectorAll('#swatches .sw'), function (b) {
      b.classList.toggle('active', b.dataset.accent === theme.accent);
    });

    var bar = $('tabbar');
    if (bar) bar.classList.toggle('nav-bar', theme.nav === 'bar');

    $('alphaRange').value = String(a);
    $('alphaVal').textContent = a + '%';
    $('alphaRange').style.setProperty('--fill', a + '%');

    var r = numOr(theme.radius, 28);
    $('radiusRange').value = String(r);
    $('radiusVal').textContent = r + 'px';
    $('radiusRange').style.setProperty('--fill', ((r - 8) / 28 * 100) + '%');

    var d = numOr(theme.dim, 78);
    $('dimRange').value = String(d);
    $('dimVal').textContent = d + '%';
    $('dimRange').style.setProperty('--fill', d + '%');

    var perf = theme.perf === 1 || theme.perf === '1';
    $('blurSwitch').checked = perf;
    $('blurVal').textContent = perf ? '已开启' : '关闭';

    var liquidOn = num(theme.liquid === undefined ? 1 : theme.liquid) === 1 && !perf;
    var ls = $('liquidSwitch');
    if (ls) ls.checked = liquidOn;
    var lv = $('liquidVal');
    if (lv) lv.textContent = !lgSupported ? '不支持' : (liquidOn ? '已开启' : '关闭');

    $('bgUrl').value = theme.bgurl || '';
    requestAnimationFrame(function () { movePill(); applyLiquidPill(); });
  }

  function loadTheme() {
    var local = null;
    try { local = JSON.parse(localStorage.getItem('cr.theme') || 'null'); } catch (e) { local = null; }
    if (local) theme = Object.assign(theme, local);
    applyTheme();

    if (!isKsu) return;
    sh('ui get').then(function (r) {
      var j = parseConfig(r.stdout || '');
      ['theme', 'bg', 'bgurl', 'alpha', 'accent', 'radius', 'dim', 'nav', 'perf', 'liquid'].forEach(function (k) {
        if (j[k] !== undefined && j[k] !== '') theme[k] = j[k];
      });
      theme.alpha = numOr(theme.alpha, 92);
      theme.radius = numOr(theme.radius, 28);
      theme.dim = numOr(theme.dim, 78);
      theme.perf = (theme.perf === 1 || theme.perf === '1') ? 1 : 0;
      theme.liquid = (theme.liquid === 1 || theme.liquid === '1') ? 1 : 0;
      applyTheme();
    }).catch(function () { });
  }

  function persistTheme() {
    try { localStorage.setItem('cr.theme', JSON.stringify(theme)); } catch (e) { }
    if (!isKsu) return;
    var lines = [
      'theme=' + theme.theme,
      'bg=' + theme.bg,
      'bgurl=' + (theme.bgurl || ''),
      'alpha=' + numOr(theme.alpha, 92),
      'accent=' + theme.accent,
      'radius=' + numOr(theme.radius, 28),
      'dim=' + numOr(theme.dim, 78),
      'nav=' + (theme.nav || 'pill'),
      'perf=' + (theme.perf === 1 || theme.perf === '1' ? 1 : 0),
      'liquid=' + (num(theme.liquid === undefined ? 1 : theme.liquid) === 1 ? 1 : 0)
    ];
    var cmd = "printf '%s\\n' " + lines.map(q).join(' ') + " | " + SH + ' ' + CTL + ' ui set';
    raw(cmd).catch(function () { });
  }

  function pickImage(file) {
    return new Promise(function (resolve, reject) {
      var fr = new FileReader();
      fr.onerror = function () { reject(new Error('读取图片失败')); };
      fr.onload = function () {
        var img = new Image();
        img.onerror = function () { reject(new Error('图片解码失败')); };
        img.onload = function () {
          var max = 1600;
          var w = img.width, h = img.height;
          var scale = Math.min(1, max / Math.max(w, h));
          var c = document.createElement('canvas');
          c.width = Math.round(w * scale);
          c.height = Math.round(h * scale);
          c.getContext('2d').drawImage(img, 0, 0, c.width, c.height);
          var data = c.toDataURL('image/jpeg', 0.82);
          if (data.length > 1400000) {
            data = c.toDataURL('image/jpeg', 0.6);
          }
          resolve(data);
        };
        img.src = fr.result;
      };
      fr.readAsDataURL(file);
    });
  }

  /* ------------------------------------------------------------ 绑定 */
  function bind() {
    $('btnRefresh').addEventListener('click', function () {
      refreshStatus(); loadLog();
      toast('已刷新');
    });

    $('btnRun').addEventListener('click', function () { doRun(this); });
    $('btnRelief').addEventListener('click', function () { doRelief(this); });
    $('btnScan').addEventListener('click', function () { doScan(this); });
    $('btnRestart').addEventListener('click', function () { doRestart(this); });
    $('btnSave').addEventListener('click', function () { saveConfig(this); });
    $('btnDiagCfg').addEventListener('click', function () { diagConfig(); });
    $('btnDiagSave').addEventListener('click', function () { saveDiagToFile(this); });
    $('btnDiagCopy').addEventListener('click', function () {
      var el = this;
      var p = state.diagText ? Promise.resolve(state.diagText) : diagConfig();
      var text = '';
      p.then(function (t) {
        text = t || saveDiagText();
        return copyText(text);
      }).then(function () {
        toast('诊断已复制');
      }).catch(function (e) {
        // 复制不了就直接落盘
        return writeTextFile('\n===== WebUI 侧诊断 =====\n' + text + '\n').then(function (path) {
          toast('剪贴板不可用，已保存到 ' + path);
        }).catch(function (e2) {
          toast('复制失败: ' + e.message + '；落盘也失败: ' + e2.message, true);
        });
      }).then(function () { el.disabled = false; });
      el.disabled = true;
    });

    // 事件委托：开关是动态生成的，绑在 document 上
    document.addEventListener('change', function (e) {
      var el = e.target;
      if (el && el.tagName === 'INPUT' && el.classList.contains('sw') && el.dataset.k) {
        autoSaveSwitch(el);
      }
    });
    $('btnLogRefresh').addEventListener('click', function () { loadLog(); toast('日志已刷新'); });
    $('btnDoctor').addEventListener('click', function () { doDoctor(this); });
    $('btnMail').addEventListener('click', function () { doMail(this); });
    $('btnCopyDiag').addEventListener('click', function () { doCopyDiag(this); });

    $('chipProfile').addEventListener('click', function () { showPage('scene'); });
    $('chevPanel').addEventListener('click', function () {
      document.querySelector('.panel').classList.toggle('collapsed');
    });

    Array.prototype.forEach.call(document.querySelectorAll('.tab'), function (b) {
      b.addEventListener('click', function () { showPage(b.dataset.page); });
    });
    Array.prototype.forEach.call(document.querySelectorAll('.preset'), function (b) {
      b.addEventListener('click', function () { applyPreset(b.dataset.preset, b); });
    });
    Array.prototype.forEach.call(document.querySelectorAll('#profileList .profile-item'), function (b) {
      b.addEventListener('click', function () { applyProfile(b.dataset.profile, b); });
    });

    /* 确认弹层 */
    if ($('modalOk')) $('modalOk').addEventListener('click', function () { closeConfirm(true); });
    if ($('modalCancel')) $('modalCancel').addEventListener('click', function () { closeConfirm(false); });
    if ($('modalMask')) $('modalMask').addEventListener('click', function () { closeConfirm(false); });
    document.addEventListener('keydown', function (e) {
      if (confirmResolve && (e.key === 'Escape' || e.key === 'Esc')) closeConfirm(false);
    });

    /* 外观 */
    Array.prototype.forEach.call(document.querySelectorAll('#segTheme button'), function (b) {
      b.addEventListener('click', function () { theme.theme = b.dataset.theme; applyTheme(); });
    });
    Array.prototype.forEach.call(document.querySelectorAll('#segBg button'), function (b) {
      b.addEventListener('click', function () {
        var next = b.dataset.bg;
        var src = theme.bgurl || localStorage.getItem('cr.bg') || '';
        if (next === 'image' && !src) {
          theme.bg = 'image';
          applyTheme();
          toast('先填图片链接或选择本地图片');
          return;
        }
        theme.bg = next;
        applyTheme();
        toast(next === 'solid' ? '已切回纯色背景' : '背景图已应用');
      });
    });
    Array.prototype.forEach.call(document.querySelectorAll('#swatches .sw'), function (b) {
      b.addEventListener('click', function () { theme.accent = b.dataset.accent; applyTheme(); });
    });
    $('alphaRange').addEventListener('input', function () {
      theme.alpha = num(this.value);
      applyTheme();
    });
    $('radiusRange').addEventListener('input', function () {
      theme.radius = num(this.value);
      applyTheme();
    });
    $('dimRange').addEventListener('input', function () {
      theme.dim = num(this.value);
      applyTheme();
    });
    $('blurSwitch').addEventListener('change', function () {
      theme.perf = this.checked ? 1 : 0;
      applyTheme();
      toast(this.checked ? '性能模式：已关闭模糊与动画' : '已恢复玻璃效果');
    });
    var liq = $('liquidSwitch');
    if (liq) liq.addEventListener('change', function () {
      theme.liquid = this.checked ? 1 : 0;
      applyTheme();
      persistTheme();
      toast(this.checked ? '液态玻璃折射：已开启（多耗一点 GPU）' : '液态玻璃折射：已关闭');
    });
    // 屏幕旋转 / 分屏后滑块尺寸变了，滤镜要重建
    var lgResizeTimer = 0;
    window.addEventListener('resize', function () {
      if (lgResizeTimer) clearTimeout(lgResizeTimer);
      lgResizeTimer = setTimeout(function () {
        lgResizeTimer = 0;
        lgLastW = -1;
        movePill();
      }, 120);
    });
    Array.prototype.forEach.call(document.querySelectorAll('#segNav button'), function (b) {
      b.addEventListener('click', function () {
        theme.nav = b.dataset.nav;
        applyTheme();
      });
    });
    $('btnBgApply').addEventListener('click', function () {
      theme.bgurl = $('bgUrl').value.trim();
      theme.bg = theme.bgurl ? 'image' : 'solid';
      applyTheme();
      toast(theme.bgurl ? '背景链接已应用' : '已切回纯色');
    });
    $('btnBgUpload').addEventListener('click', function () { $('bgFile').click(); });
    $('bgFile').addEventListener('change', function () {
      var f = this.files && this.files[0];
      if (!f) return;
      pickImage(f).then(function (data) {
        try { localStorage.setItem('cr.bg', data); } catch (e) {
          toast('图片太大，无法保存到本地', true);
          return;
        }
        theme.bg = 'image';
        theme.bgurl = '';
        applyTheme();
        toast('本地背景已应用（仅本 WebView）');
      }).catch(function (e) { toast('图片处理失败: ' + e.message, true); });
    });
    $('btnLookSave').addEventListener('click', function () {
      persistTheme();
      toast('外观已保存');
    });
    $('btnLookReset').addEventListener('click', function () {
      theme = { theme: 'auto', bg: 'solid', bgurl: '', alpha: 92, accent: 'green', radius: 28, dim: 78, nav: 'pill', perf: 0, liquid: 1 };
      try { localStorage.removeItem('cr.bg'); localStorage.removeItem('cr.theme'); } catch (e) { }
      applyTheme();
      persistTheme();
      toast('已恢复默认外观');
    });
  }

  /* ------------------------------------------------------------ 启动 */
  function noRootBanner() {
    var div = document.createElement('div');
    div.className = 'card';
    div.innerHTML =
      '<div class="card-title">缺少 root 接口</div>' +
      '<p class="muted small">本页面需要通过 KernelSU 或 KsuWebUI 打开，普通浏览器里没有 ksu.exec。<br>' +
      'Magisk 用户可在终端执行：<br><code>sh ' + MOD + '/bin/ctl.sh status</code></p>';
    var main = document.querySelector('main');
    main.insertBefore(div, main.firstChild);
  }

  // 用户触摸/滚动后短暂暂停轮询，避免同步 exec 抢主线程造成“点了没反应”
  var pauseUntil = 0;
  function noteInteraction() {
    pauseUntil = Date.now() + 3500;
  }

  function init() {
    bind();
    loadTheme();
    renderProfile();
    requestAnimationFrame(movePill);

    if (!isKsu) {
      noRootBanner();
      $('logOut').textContent = '需要在 KernelSU / KsuWebUI 里打开才能读取日志。';
      $('doctorOut').textContent = '需要在 KernelSU / KsuWebUI 里打开才能自检。';
      return;
    }

    ['touchstart', 'pointerdown', 'scroll', 'wheel'].forEach(function (evt) {
      window.addEventListener(evt, noteInteraction, { passive: true });
    });

    // 首屏先让浏览器画完，再发同步 exec
    setTimeout(function () {
      refreshStatus();
      loadLog();
    }, 60);

    // setTimeout 链：上一次跑完才排下一次，不会叠加
    (function statusLoop() {
      setTimeout(function () {
        if (!document.hidden && state.page === 'home' &&
            Date.now() > pauseUntil && !state.busy) {
          refreshStatus();
        }
        statusLoop();
      }, 30000);
    })();

    (function logLoop() {
      setTimeout(function () {
        if (!document.hidden && state.page === 'home' && Date.now() > pauseUntil) {
          loadLog();
        }
        logLoop();
      }, 90000);
    })();

    window.addEventListener('resize', function () { requestAnimationFrame(movePill); });

    document.addEventListener('visibilitychange', function () {
      if (!document.hidden && state.page === 'home') {
        refreshStatus();
        loadLog();
      }
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
