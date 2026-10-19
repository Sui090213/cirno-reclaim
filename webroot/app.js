/* Cirno Reclaim Hybrid - WebUI 脚本
   无框架、无外部请求。优先用 KernelSU 的异步 ksu.exec(cmd, options, callback)：
   同步版在命令执行期间会卡住整个页面（回收一次要好几秒）。
   老管理器只有同步版时自动退回。 */

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

  function norm(v) {
    if (typeof v === 'string') return { errno: 0, stdout: v, stderr: '' };
    if (!v || typeof v !== 'object') return { errno: 0, stdout: '', stderr: '' };
    return {
      errno: typeof v.errno === 'number' ? v.errno : 0,
      stdout: v.stdout || '',
      stderr: v.stderr || ''
    };
  }

  function q(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'";
  }

  function $(id) { return document.getElementById(id); }

  function toast(msg, bad) {
    var t = $('toast');
    t.textContent = msg;
    t.className = 'toast show' + (bad ? ' bad' : '');
    clearTimeout(toast._t);
    toast._t = setTimeout(function () { t.className = 'toast'; }, 2600);
  }

  function parseJSON(text) {
    try { return JSON.parse(text); } catch (e) { return null; }
  }

  function ago(sec) {
    if (!sec || sec >= 999999) return '--';
    if (sec < 60) return sec + ' 秒前';
    if (sec < 3600) return Math.floor(sec / 60) + ' 分钟前';
    if (sec < 86400) return Math.floor(sec / 3600) + ' 小时前';
    return Math.floor(sec / 86400) + ' 天前';
  }

  function num(v) {
    var n = Number(v);
    return isFinite(n) ? n : 0;
  }

  /* ------------------------------------------------------------ 页面切换 */

  var currentPage = 'home';

  function showPage(name) {
    currentPage = name;
    ['home', 'settings', 'feedback'].forEach(function (p) {
      $('page-' + p).classList.toggle('active', p === name);
    });
    Array.prototype.forEach.call(document.querySelectorAll('.tab'), function (b) {
      b.classList.toggle('active', b.dataset.page === name);
    });
    if (name === 'home') refreshStatus();
    if (name === 'settings') loadConfig();
    if (name === 'feedback') loadDiag(true);
  }

  /* ------------------------------------------------------------ 状态 */

  var busy = false;

  function refreshStatus() {
    if (!isKsu || busy) return;
    busy = true;
    sh(CTL + ' status --json').then(function (r) {
      var s = parseJSON(r.stdout);
      if (!s || !s.ok) return;
      renderStatus(s);
    }).catch(function () {
      /* 静默失败，下次轮询再试 */
    }).then(function () { busy = false; });
  }

  function renderStatus(s) {
    var total = num(s.total) || 1;
    var avail = num(s.avail);
    var pct = Math.max(0, Math.min(100, Math.round(avail / total * 100)));

    $('ver').textContent = s.version || '--';
    $('memAvail').textContent = avail;
    $('memTotal').textContent = num(s.total);
    $('memSwap').textContent = num(s.swap_total);

    var bar = $('memBar');
    bar.style.width = pct + '%';
    var low = num(s.mem_low) || 0;
    bar.classList.toggle('low', avail < low);

    var pill = $('memPill');
    if (avail < low) {
      pill.textContent = '偏低';
    } else if (avail < low * 1.25) {
      pill.textContent = '接近阈值';
    } else {
      pill.textContent = '充足';
    }
    pill.textContent += ' · ' + pct + '%';

    var healthy = num(s.daemon) === 1;
    var dot = $('statusDot');
    dot.className = 'dot ' + (healthy ? 'on' : 'off');
    dot.title = healthy ? '守护运行中' : '守护未运行';

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
    });
  }

  /* ------------------------------------------------------------ 动作 */

  function withBusy(btn, p, okMsg) {
    if (!isKsu) {
      if (p && p.catch) p.catch(function () { });
      toast('请在 KernelSU / KsuWebUI 中打开本页面', true);
      return Promise.resolve();
    }
    var old = btn ? btn.disabled : false;
    if (btn) btn.disabled = true;
    toast('执行中…');
    return p.then(function (r) {
      var j = parseJSON(r.stdout) || {};
      if (r.errno !== 0 && !j.ok) {
        toast('失败: ' + (r.stderr || 'errno ' + r.errno), true);
        return;
      }
      if (j.ok === 0) {
        toast('失败: ' + (j.err || r.stderr || '未知错误'), true);
        return;
      }
      if (okMsg) {
        toast(typeof okMsg === 'function' ? okMsg(j) : okMsg);
      }
      refreshStatus();
    }).catch(function (e) {
      toast('执行出错: ' + (e && e.message ? e.message : e), true);
    }).then(function () {
      if (btn) btn.disabled = old;
    });
  }

  function doRun(btn) {
    withBusy(btn, sh(CTL + ' run --json'), function (j) {
      if (j.skipped) return '本次跳过：' + (j.reason || '');
      if (num(j.dry_run) === 1) return '演练完成：会做的事已写进日志';
      return '压缩 ' + num(j.paged) + ' MB，结束 ' + num(j.kills) + ' 个进程，可用 +' + num(j.freed) + ' MB';
    });
  }

  function doRelief(btn) {
    withBusy(btn, sh(CTL + ' apprelief --force --json'), function (j) {
      if (!j.pkg) return '没检测到前台应用';
      return '前台 ' + j.pkg + '：' + j.pss_before + '→' + j.pss_after + ' MB，可用 +' + j.freed + ' MB';
    });
  }

  function doScan(btn) {
    if (!isKsu) { toast('请在 KernelSU / KsuWebUI 中打开本页面', true); return; }
    btn.disabled = true;
    sh(CTL + ' scan').then(function (r) {
      var out = $('scanOut');
      out.textContent = (r.stdout || '') + (r.stderr ? '\n' + r.stderr : '');
      out.classList.remove('hidden');
      toast('扫描完成');
    }).catch(function (e) {
      toast('扫描失败: ' + e.message, true);
    }).then(function () { btn.disabled = false; });
  }

  function doRestart(btn) {
    withBusy(btn, sh(CTL + ' restart'), '守护已重启');
  }

  function loadLog() {
    if (!isKsu) return;
    sh(CTL + ' log 120').then(function (r) {
      $('logOut').textContent = r.stdout || '（暂无日志）';
    }).catch(function () { });
  }

  /* ------------------------------------------------------------ 设置 */

  var BASIC = [
    { k: 'dry_run', t: 'switch', label: '演练模式', hint: '只记录不动手；首次安装默认开' },
    { k: 'enable', t: 'switch', label: '启用模块', hint: '关闭后守护仍在跑，但不再回收' },
    { k: 'mem_low_mb', t: 'number', label: '触发阈值', unit: 'MB', hint: '可用内存低于它就回收' },
    { k: 'mem_target_mb', t: 'number', label: '目标内存', unit: 'MB', hint: '回到这个值就停手' },
    { k: 'max_kills_per_run', t: 'number', label: '单轮最多回收', unit: '个' },
    { k: 'max_kills_per_hour', t: 'number', label: '每小时上限', unit: '个' },
    { k: 'min_frozen_min', t: 'number', label: '至少冻结', unit: '分钟', hint: '防止刚切后台就被杀' },
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
    { k: 'high_pss_mb', t: 'number', label: '大进程看门狗', unit: 'MB', hint: '单个冻结进程超过它就回收' },
    { k: 'high_pss_interval', t: 'number', label: '看门狗周期', unit: '秒' },
    { k: 'min_oom_score_adj', t: 'number', label: '最低 oom_score_adj', hint: '900 = 只碰缓存进程' },
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
    { k: 'psi_some_avg10', t: 'number', label: 'PSI 阈值', hint: 'avg10 超过它视为内存紧张' },
    { k: 'mem_low_pct', t: 'number', label: '阈值百分比', unit: '%', hint: '0 = 只看绝对值' },
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
      options: [['lz4', 'lz4（快）'], ['lz4hc', 'lz4hc（更省）'], ['zstd', 'zstd'], ['lzo-rle', 'lzo-rle']]
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
    { k: 'exclude_packages', t: 'text', label: '永不回收的包', hint: '分号分隔，支持 * 通配' }
  ];

  var CFG = {};
  var configLoaded = false;

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
        input.checked = num(CFG[f.k]) === 1;
      } else if (f.t === 'select') {
        input = document.createElement('select');
        f.options.forEach(function (o) {
          var op = document.createElement('option');
          op.value = o[0];
          op.textContent = o[1];
          input.appendChild(op);
        });
        input.value = CFG[f.k] || f.options[0][0];
      } else {
        input = document.createElement('input');
        input.type = f.t === 'number' ? 'number' : 'text';
        input.value = CFG[f.k] !== undefined ? CFG[f.k] : '';
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
      v = v.replace(/\s+#.*$/, '');
      if (QUOTED[k]) v = v.replace(/^'(.*)'$/, '$1');
      out[k] = v;
    });
    return out;
  }

  function loadConfig() {
    if (!isKsu) return;
    sh(CTL + ' config').then(function (r) {
      var text = r.stdout || '';
      if (r.errno !== 0 || text.indexOf('enable=') < 0) {
        // 读不到配置就绝不进入可保存状态，否则会把所有开关写成 0
        configLoaded = false;
        $('btnSave').disabled = true;
        toast('读取配置失败，已禁用保存', true);
        return;
      }
      configLoaded = true;
      $('btnSave').disabled = false;
      CFG = parseConfig(text);
      buildForm($('formBasic'), BASIC);
      buildForm($('formAdvanced'), ADVANCED);
      Array.prototype.forEach.call(document.querySelectorAll('.chip[data-preset]'), function (c) {
        c.classList.toggle('active', c.dataset.preset === CFG.profile);
      });
    }).catch(function (e) {
      configLoaded = false;
      $('btnSave').disabled = true;
      toast('读取配置失败: ' + e.message, true);
    });
  }

  function saveConfig(btn) {
    if (!isKsu) { toast('请在 KernelSU / KsuWebUI 中打开本页面', true); return; }
    if (!configLoaded) { toast('配置未成功加载，拒绝保存', true); return; }

    var lines = [];
    Array.prototype.forEach.call(document.querySelectorAll('[data-k]'), function (el) {
      var k = el.dataset.k;
      var v;

      if (el.type === 'checkbox') {
        // 配置里本来没有这个键时，不要凭「没勾选」给它写 0
        if (!(k in CFG)) return;
        v = el.checked ? 1 : 0;
      } else {
        v = el.value.trim();
        // 名单类允许清空，其余空值视为「不修改」
        if (v === '' && !QUOTED[k]) return;
      }

      if (QUOTED[k]) v = "'" + String(v).replace(/'/g, '') + "'";
      lines.push(k + '=' + v);
    });
    if (!lines.length) { toast('没有可保存的内容', true); return; }
    var cmd = "printf '%s\\n' " + lines.map(q).join(' ') + ' | ' + CTL + ' save';
    withBusy(btn, sh(cmd), '设置已保存');
  }

  function applyPreset(name, btn) {
    withBusy(btn, sh(CTL + ' preset ' + name), '已切换到「' + name + '」预设').then(function () {
      setTimeout(loadConfig, 400);
    });
  }

  /* ------------------------------------------------------------ 诊断 / 反馈 */

  var diagCache = '';

  function loadDiag(preview) {
    if (!isKsu) return Promise.resolve('');
    return sh(CTL + ' diag').then(function (r) {
      diagCache = r.stdout || '';
      if (preview) $('diagOut').textContent = diagCache || '（诊断信息为空）';
      return diagCache;
    }).catch(function (e) {
      toast('获取诊断信息失败: ' + e.message, true);
      return '';
    });
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
      } catch (e) {
        reject(e);
      }
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
      btn.disabled = false;
    });
  }

  function doCopyRepo() {
    copyText(REPO + '/issues').then(function () {
      toast('链接已复制，用浏览器打开即可');
    }).catch(function () {
      toast('复制失败，请手动记下：' + REPO, true);
    });
  }

  /* ------------------------------------------------------------ 绑定 */

  function bind() {
    $('btnRefresh').addEventListener('click', function () {
      refreshStatus();
      loadLog();
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
    Array.prototype.forEach.call(document.querySelectorAll('.chip[data-preset]'), function (c) {
      c.addEventListener('click', function () { applyPreset(c.dataset.preset, c); });
    });

    var d = document.querySelector('#page-home details');
    if (d) d.addEventListener('toggle', function () { if (d.open) loadLog(); });

    document.addEventListener('visibilitychange', function () {
      if (!document.hidden && currentPage === 'home') refreshStatus();
    });
  }

  function noRootBanner() {
    var div = document.createElement('div');
    div.className = 'card';
    div.innerHTML =
      '<div class="card-head"><span>缺少 root 接口</span></div>' +
      '<p class="muted small">这个页面需要通过 KernelSU 或 KsuWebUI 打开，' +
      '普通浏览器里没有 <code>ksu.exec</code>，所有按钮都不可用。<br>' +
      'Magisk 用户可以在终端里执行：<br><code>sh ' + MOD + '/bin/ctl.sh status</code></p>';
    var main = document.querySelector('main');
    main.insertBefore(div, main.firstChild);
  }

  function init() {
    bind();
    if (!isKsu) {
      noRootBanner();
      $('logOut').textContent = '需要在 KernelSU / KsuWebUI 里打开才能读取日志。';
      return;
    }
    refreshStatus();
    loadLog();
    loadDiag(false);
    setInterval(function () {
      if (currentPage === 'home' && !document.hidden) refreshStatus();
    }, 15000);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
