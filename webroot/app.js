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
  var CTL = 'sh ' + MOD + '/bin/ctl.sh';
  var QUOTED = { include_packages: 1, exclude_packages: 1 };
  var REPO = 'https://github.com/yishisanren/cirno-reclaim';

  var isKsu = !!(window.ksu && typeof window.ksu.exec === 'function');

  /* ------------------------------------------------------------ 基础工具 */

  var cbSeq = 0;

  function sh(cmd) {
    if (!isKsu) return Promise.reject(new Error('缺少 root 接口'));
    return new Promise(function (resolve) {
      var name = 'crExecCb' + Date.now() + '_' + (cbSeq++);
      var timer = setTimeout(function () {
        delete window[name];
        resolve({ errno: -1, stdout: '', stderr: '执行超时' });
      }, 120000);
      window[name] = function (errno, stdout, stderr) {
        clearTimeout(timer);
        delete window[name];
        resolve({ errno: Number(errno) || 0, stdout: stdout || '', stderr: stderr || '' });
      };
      try {
        window.ksu.exec(cmd, '{}', name);
      } catch (e) {
        // 老版本管理器只有同步的 exec(cmd)
        clearTimeout(timer);
        delete window[name];
        var r = window.ksu.exec(cmd);
        if (r && typeof r.then === 'function') {
          r.then(function (v) { resolve(norm(v)); });
        } else {
          resolve(norm(r));
        }
      }
    });
  }
  var CTL = MOD + '/bin/ctl.sh';
  var CONF = '/data/adb/cirno_reclaim/config.conf';
  var SH = '/system/bin/sh';
  var MAIL = 'asui20090213@outlook.com';
  var QUOTED = { include_packages: 1, exclude_packages: 1 };

  var isKsu = !!(window.ksu && typeof window.ksu.exec === 'function');

  var state = {
    configLoaded: false,
    cfg: {},
    status: null,
    info: null,
    page: 'home',
    busy: 0
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
    if (name === 'scene') loadConfig();
    if (name === 'look') loadTheme();
    if (name === 'about') refreshStatus();
  }

  /* ------------------------------------------------------------ 状态 */
  var statusBusy = false;
  var lastStatusKey = '';

  function applyStatus(s) {
    if (!s || !s.ok) return false;
    var key = [s.avail, s.total, s.daemon, s.pageout, s.total_kills, s.total_freed,
               s.profile, s.engine, s.hb_age].join('|');
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

    var hint = $('hintLine');
    if (num(s.dry_run) === 1) {
      hint.className = 'hint warn';
      hint.textContent = '演练模式：只记录不动手。观察日志没问题后，到「设置」关闭演练模式';
    } else if (num(s.cgroup) !== 1) {
      hint.className = 'hint warn';
      hint.textContent = '没找到冻结进程所在的位置：Cirno 可能没在运行，模块不会动作';
    } else if (num(s.pageout) === 1) {
      hint.className = 'hint';
      hint.textContent = '内存紧张时：先把冻结的应用压进 zram，不够再结束最大的';
    } else {
      hint.className = 'hint warn';
      hint.textContent = '页换出不可用（内核不支持），内存紧张时只能结束冻结的应用';
    }

    $('stPaged').textContent = num(s.total_paged);
    $('stKills').textContent = num(s.total_kills);
    $('stFreed').textContent = num(s.total_freed);
    $('stHb').textContent = num(s.hb_age) >= 999999 ? '--' : num(s.hb_age) + 's';

    if (num(s.last_run) > 0) {
      var age = Math.max(0, Math.floor(Date.now() / 1000) - num(s.last_run));
      $('lastRun').textContent = ago(age);
      $('lastInfo').textContent =
        '压缩 ' + num(s.last_paged) + ' MB · 结束 ' + num(s.last_kills) + ' 个进程 · 可用 +' +
        num(s.last_freed) + ' MB' + (s.last_reason ? ' · 触发: ' + s.last_reason : '');
    } else {
      $('lastInfo').textContent = '还没有执行过回收（守护会在内存偏低时自动执行）';
    }

    document.querySelectorAll('.chip[data-preset]').forEach(function (c) {
      c.classList.toggle('active', c.dataset.preset === s.profile);
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

  function doRun(btn) {
    withBusy(btn, sh(CTL + ' run --json'), function (j) {
      if (j.skipped) return '本次跳过：' + (j.reason || '');
      if (num(j.dry_run) === 1) return '演练完成：会做的事已写进日志';
      return '压缩 ' + num(j.paged) + ' MB，结束 ' + num(j.kills) + ' 个进程，可用 +' + num(j.freed) + ' MB';
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
    { k: 'dry_run', t: 'switch', label: '演练模式', hint: '只记录不动手；首次安装默认开' },
    { k: 'enable', t: 'switch', label: '启用模块', hint: '关闭后守护仍在跑，但不再回收' },
    { k: 'mem_low_mb', t: 'number', label: '触发阈值', unit: 'MB', hint: '可用内存低于它就回收' },
    { k: 'mem_target_mb', t: 'number', label: '目标内存', unit: 'MB' },
    { k: 'max_kills_per_run', t: 'number', label: '单轮最多', unit: '个' },
    { k: 'max_kills_per_hour', t: 'number', label: '每小时上限', unit: '个' },
    { k: 'min_frozen_min', t: 'number', label: '至少冻结', unit: '分钟' },
    { k: 'min_process_mb', t: 'number', label: '忽略小进程', unit: 'MB' },
    { k: 'deep_reclaim', t: 'switch', label: '压缩冻结应用', hint: '先把冻结的应用压进 zram，进程不死' },
    { k: 'deep_pageout_max_mb', t: 'number', label: '单次压缩上限', unit: 'MB' },
    { k: 'app_reclaim', t: 'switch', label: '前台舒缓', hint: '只在内存紧张时处理正在用的应用' },
    { k: 'app_pss_mb', t: 'number', label: '前台阈值', unit: 'MB', hint: '前台应用超过就舒缓' },
    { k: 'screen_off_only', t: 'switch', label: '仅息屏回收' },
    { k: 'app_pageout', t: 'switch', label: '前台页换出', hint: '紧张时把少量匿名页换到 zram' }
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
    {
      k: 'reclaim_order', t: 'select', label: '回收顺序',
      options: [['pageout_first', '先压缩后结束'], ['kill_first', '先结束后压缩']]
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
    { k: 'vm_tune', t: 'switch', label: 'VM 调参', hint: 'ColorOS 自己会调，建议保持关闭' },
    { k: 'zram_enable', t: 'switch', label: '启用 zram', hint: 'ColorOS 上无效（不碰内存扩展）' },
    { k: 'zram_disksize_mb', t: 'number', label: 'zram 大小', unit: 'MB', hint: '0 = 自动（内存一半）' },
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
      if (QUOTED[k]) v = v.replace(/^'(.*)'$/, '$1');
      out[k] = v;
    });
    return out;
  }

  function applyConfigText(text, note) {
    state.configLoaded = true;
    $('btnSave').disabled = false;
    $('saveHint').textContent = '配置已加载' + (note ? '（' + note + '）' : '') + ' · 修改后守护会自动重读';
    state.cfg = parseConfig(text);
    buildForm($('formBasic'), BASIC);
    buildForm($('formAdvanced'), ADVANCED);
    Array.prototype.forEach.call(document.querySelectorAll('.preset'), function (b) {
      b.classList.toggle('active', b.dataset.preset === state.cfg.profile);
    });
  }

  function loadConfig() {
    if (!isKsu) {
      $('saveHint').textContent = '需要在 KernelSU / KsuWebUI 中打开才能读写配置。';
      return Promise.resolve();
    }
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

  function saveConfig(el) {
    if (!isKsu || !state.configLoaded) { toast('配置未成功加载，拒绝保存', true); return; }
    var lines = [];
    Array.prototype.forEach.call(document.querySelectorAll('[data-k]'), function (input) {
      var k = input.dataset.k;
      var v;
      if (input.type === 'checkbox') {
        if (!(k in state.cfg)) return;
        v = input.checked ? 1 : 0;
      } else {
        v = input.value.trim();
        if (v === '' && !QUOTED[k]) return;
      }
      if (QUOTED[k]) v = "'" + String(v).replace(/'/g, '') + "'";
      lines.push(k + '=' + v);
    });
    if (!lines.length) { toast('没有可保存的内容', true); return; }

    var cmd = "printf '%s\\n' " + lines.map(q).join(' ') + " | " + SH + ' ' + CTL + ' save';
    withBusy(el, raw(cmd), '设置已保存').then(function () {
      setTimeout(loadConfig, 500);
    });
  }

  // 开关类改动立即保存，避免「点了没反应、还要再点保存」的困惑
  function autoSaveSwitch(el) {
    if (!isKsu || !state.configLoaded) {
      el.checked = !el.checked;
      toast('配置还没加载成功，改动不会保存', true);
      return;
    }
    var k = el.dataset.k;
    var v = el.checked ? 1 : 0;
    el.disabled = true;
    var cmd = "printf '%s\\n' " + q(k + '=' + v) + " | " + SH + ' ' + CTL + ' save';
    raw(cmd).then(function (r) {
      var j = parseJSON(r.stdout) || {};
      if (j.ok) {
        state.cfg[k] = String(v);
        toast('已保存：' + k + ' = ' + v);
        refreshStatus();
      } else {
        el.checked = !el.checked;
        toast('保存失败: ' + (j.err || r.stderr || '未知错误'), true);
      }
    }).catch(function (e) {
      el.checked = !el.checked;
      toast('保存失败: ' + e.message, true);
    }).then(function () { el.disabled = false; });
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
    if (navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(text);
    }
    return new Promise(function (resolve, reject) {
      try {
        var ta = document.createElement('textarea');
        ta.value = text;
        ta.style.position = 'fixed';
        ta.style.opacity = '0';
        document.body.appendChild(ta);
        ta.select();
        var ok = document.execCommand('copy');
        document.body.removeChild(ta);
        ok ? resolve() : reject(new Error('copy rejected'));
      } catch (e) { reject(e); }
    });
  }

  function doCopyDiag(btn) {
    if (!isKsu) { toast('请在 KernelSU / KsuWebUI 中打开本页面', true); return; }
    btn.disabled = true;
    loadDiag(true).then(function (text) {
      if (!text) throw new Error('empty');
      return copyText(text).then(function () {
        toast('诊断信息已复制');
      });
    }).catch(function (e) {
      toast('复制失败，请长按下方文本手动复制：' + e.message, true);
      $('diagOut').parentElement.open = true;
    }).then(function () {
      toast('诊断信息已复制');
    }).catch(function (e) {
      toast('复制失败: ' + e.message, true);
    }).then(function () { el.disabled = false; });
  }

  function doCopyRepo() {
    copyText(REPO + '/issues').then(function () {
      toast('链接已复制，用浏览器打开即可');
    }).catch(function () {
      toast('复制失败，请手动记下：' + REPO, true);
    });
  }

  /* ------------------------------------------------------------ 外观 */
  var theme = {
    theme: 'auto', bg: 'solid', bgurl: '', alpha: 92, accent: 'green',
    radius: 28, dim: 78, nav: 'pill', perf: 0
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

    $('bgUrl').value = theme.bgurl || '';
    requestAnimationFrame(movePill);
  }

  function loadTheme() {
    var local = null;
    try { local = JSON.parse(localStorage.getItem('cr.theme') || 'null'); } catch (e) { local = null; }
    if (local) theme = Object.assign(theme, local);
    applyTheme();

    if (!isKsu) return;
    sh('ui get').then(function (r) {
      var j = parseConfig(r.stdout || '');
      ['theme', 'bg', 'bgurl', 'alpha', 'accent', 'radius', 'dim', 'nav', 'perf'].forEach(function (k) {
        if (j[k] !== undefined && j[k] !== '') theme[k] = j[k];
      });
      theme.alpha = numOr(theme.alpha, 92);
      theme.radius = numOr(theme.radius, 28);
      theme.dim = numOr(theme.dim, 78);
      theme.perf = (theme.perf === 1 || theme.perf === '1') ? 1 : 0;
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
      'perf=' + (theme.perf === 1 || theme.perf === '1' ? 1 : 0)
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
    $('btnCopyDiag').addEventListener('click', function () { doCopyDiag(this); });
    $('btnCopyRepo').addEventListener('click', function () { doCopyRepo(); });

    Array.prototype.forEach.call(document.querySelectorAll('.tab'), function (b) {
      b.addEventListener('click', function () { showPage(b.dataset.page); });
    });
    Array.prototype.forEach.call(document.querySelectorAll('.preset'), function (b) {
      b.addEventListener('click', function () { applyPreset(b.dataset.preset, b); });
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
      theme = { theme: 'auto', bg: 'solid', bgurl: '', alpha: 92, accent: 'green', radius: 28, dim: 78, nav: 'pill', perf: 0 };
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
