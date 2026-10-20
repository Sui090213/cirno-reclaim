# HyperOS / ColorOS 双平台档案

v2.3.0 起，模块按系统套用**档案（profile）**。档案里只写需要覆盖的键，
不会改动你其它参数；两套档案共享同一份脚本，差异只体现在这些键上。

- `hyperos`：小米 / 红米 / POCO（HyperOS、MIUI）；
- `coloros`：OPPO / OnePlus / realme（ColorOS、OPlus / OPPO 系）；
- `generic`：识别不出来或其它 ROM，**不覆盖任何值**，只记录 `device_profile=generic`。

> 本版档案的取值来自两套平台的适配经验（HyperOS 侧沿用本项目默认值，
> ColorOS 侧合并 yishisanren 的 ColorOS 17 适配版），**尚未在全部机型验证**。
> 遇到识别错误或参数不合适，请按文末方式反馈。

---

## 一、两套档案的差异

| 键 | `hyperos` | `coloros` | 说明 |
|---|---|---|---|
| `device_profile` | `hyperos` | `coloros` | 档案标记 |
| `interval` | `20` | `15` | 守护探测周期（秒）；守护会按压力自适应放宽 |
| `vm_tune` | `1` | `0` | HyperOS 只写 sysctl；ColorOS 不动系统内存参数 |
| `zram_enable` | `0` | `0` | 都不接管 OEM zram |
| `swapfile_enable` | `0` | `0` | 都不建 swapfile |
| `reclaim_order` | `pageout_first` | `pageout_first` | 都先压 zram，不够再结束 |
| `deep_pageout_max_mb` | `192` | `256` | 单次页换出上限（ColorOS 更积极） |
| `app_reclaim_interval` | `60` | `45` | 前台舒缓周期（秒） |
| `app_reclaim_cooldown` | `120` | `90` | 前台舒缓冷却（秒） |
| `relief_gate` | `1` | `1` | 前台舒缓只在内存紧张时自动执行 |
| `exclude_packages` | 见下 | 见下 | 平台系统应用前缀不同 |

`exclude_packages` 的具体差异（均由默认名单扩展而来）：

| 档案 | 在公共名单之外追加 |
|---|---|
| `hyperos` | `com.miui.*`、`com.xiaomi.*`、`com.mi.*` |
| `coloros` | `com.oplus.*`、`com.coloros.*`、`com.heytap.*`、`com.oppo.*`、`com.nearme.*`、`com.finshell.*` |

公共部分（两套都保护）：微信、QQ、支付宝、淘宝、京东、抖音。

除了档案文件，`bin/common.sh` 里还有一层硬保护名单（系统界面、桌面、输入法、电话、
蓝牙、NFC、GMS、Magisk / KernelSU 管理器、Cirno 本体等），从 `exclude_packages` 里删掉也不会被回收。

---

## 二、系统怎么识别

识别顺序（命中即返回）：

1. 有 `ro.mi.os.version.name` 或 `ro.miui.ui.version.name` → **HyperOS**；
2. 有 `ro.build.version.oplusrom` 或 `ro.build.version.opporom`，或存在 `/my_product` 目录 → **ColorOS**；
3. 否则 → **generic**。

安装时会打印检测结果，例如：

```text
- 检测到的系统: HyperOS 2.0（hyperos）
```

也可以随时手工核对：

```sh
getprop ro.mi.os.version.name
getprop ro.miui.ui.version.name
getprop ro.build.version.oplusrom
getprop ro.build.version.opporom
ls -d /my_product
```

`rom_name` 会尽量给出人读名字（如 `HyperOS 2.0`、`ColorOS 15`、`MIUI 14`）；
只有 `/my_product` 没有版本属性时输出 `ColorOS (OPlus base)`，
完全识别不出时输出 `Other ROM (Android <版本>)`。

---

## 三、安装时选择（音量键）

刷入模块时，安装脚本会读音量键，**8 秒**超时：

| 操作 | 结果 |
|---|---|
| 按**音量上** | 选择 `hyperos`（HyperOS / MIUI，小米） |
| 按**音量下** | 选择 `coloros`（ColorOS / realmeUI / OxygenOS） |
| 不按 / 读不到输入设备 | 自动检测 |
| 环境变量 `CR_PROFILE=hyperos\|coloros\|generic\|auto` | 优先于按键，直接生效（脚本化刷入用；`auto` = 按检测结果套用） |

选择结果写入 `profile.pending`，首次开机由 `post-fs-data.sh` 的 `profile_bootstrap` 处理：

- **全新安装**且未按键：`auto` → 按检测结果套用对应档案；
- **升级安装**且未按键：`keep` → 只把 `device_profile` 更新为检测结果，**不覆盖**已有参数；
  这一行很关键：升级时不想被动改参数，就什么都别按；
- 其它情况（按键 / `CR_PROFILE`）：直接 `profile_apply <名字>`，覆盖档案里列出的键。

处理完成后会删除 `profile.pending`，并写 `state/profile.applied=<名字>` 作为记录。

> 8 秒不按键不会卡住安装，脚本会自动往下走。

---

## 四、查看当前档案

```sh
ctl=/data/adb/modules/cirno_reclaim/bin/ctl.sh

sh $ctl profile            # k=v 文本
```

输出示例：

```text
device_profile=hyperos
detected=hyperos
rom=HyperOS 2.0
```

- `device_profile`：当前实际生效的档案（来自配置文件）；
- `detected`：按属性实时检测的结果；
- `rom`：给人看的系统名，实际取系统属性值（例如 `ColorOS V15.0.0`、`HyperOS 2.0`；
  无版本号时是 `ColorOS (OPlus base)` / `Other ROM (Android N)`）。

两者不一致通常说明：你手动切过档案，或者 ROM 属性被改动过。

JSON 版本（WebUI / 脚本用）：

```sh
sh $ctl profile --json
# {"ok":1,"device_profile":"hyperos","detected":"hyperos","rom":"HyperOS 2.0","applied":1}

sh $ctl profile list
# {"ok":1,"list":["hyperos","coloros","generic"],"detected":"hyperos","current":"hyperos"}

sh $ctl profile detect
# hyperos
```

`profile --json` 的 `applied` 表示 `state/profile.applied` 是否与当前 `device_profile` 一致
（安装 / 切换后会写这个标记，1 = 一致）。

`snapshot` 的状态对象里也有对应字段：
`device_profile`、`detected`、`rom`、`order`（回收顺序）、`relief_gate`、
`total_paged`（累计页换出量）、`last_paged`（最近一次页换出量），
以及 `tight` / `wakeups` / `cpu_ms`（与守护统计同源，取不到时为 `-1`）。
`info` 段里同样有 `rom` / `device_profile` / `tight` / `wakeups` / `cpu_ms`。

守护的 `--status` 也会带上档案和自身开销：

```sh
sh /data/adb/modules/cirno_reclaim/bin/cirno_daemon --status
# {"ok":1,"engine":"cpp","pid":1234,"alive":1,"heartbeat_age":3,"log_size":4096,
#  "config_bad_lines":0,"interval":20,"app_interval":60,"heartbeat_sec":45,
#  "profile":"hyperos","tight":0,"avail":2400,"total":11264,"low":901,"psi":0.12,
#  "relief_gate":1,"children":0,"wakeups":42,"probes":42,"cpu_ms":118,"uptime":1800}
```

- `wakeups` / `probes`：累计唤醒 / 压力探测次数，旧版空闲时约 60 次/分钟，新版空闲约 1.5~3 次/分钟；
- `cpu_ms`：守护自身累计 CPU 时间（utime+stime），验证功耗最硬的指标；
- `uptime`：守护已运行秒数。

同样的统计也可以直接看 `cat /data/adb/cirno_reclaim/state/cpp.stats`，
或者 `sh ctl.sh status --json` / `sh ctl.sh info` / `sh ctl.sh snapshot`。

> `heartbeat_sec` 实际夹在 `10..min(120, heartbeat_timeout/2)`：
> 把 `heartbeat_timeout` 调小会同时压低 `heartbeat_sec` 的上限。

---

## 五、手动切换档案

```sh
ctl=/data/adb/modules/cirno_reclaim/bin/ctl.sh

sh $ctl profile apply hyperos
# {"ok":1,"profile":"hyperos"}

sh $ctl profile apply coloros
sh $ctl profile apply generic
# 非法名字：
# {"ok":0,"err":"invalid_profile"}
```

或者打开 WebUI →「场景」→「系统适配」卡片，点对应平台并确认。
卡片顶部会显示「检测到：<rom>」，当前档案高亮。

### 注意：`apply` 会覆盖参数

`profile apply` 不是只改 `device_profile` 一行，而是把档案文件里的键**全部写入**
`/data/adb/cirno_reclaim/config.conf`；档案里没有列出的键保持你当前的值。所以：

- 你自己把 `interval`、`deep_pageout_max_mb`、`exclude_packages` 调过的话，套档案后会被改回档案值；
- 想保留自定义值，先备份配置：

```sh
cp /data/adb/cirno_reclaim/config.conf /data/adb/cirno_reclaim/config.conf.bak
```

- `generic` 不建档案文件，`profile apply generic` 只会把 `device_profile` 写成 `generic`，
  不会改其它参数（等于「不套用任何平台预设」）。

### `profile` 与 `preset` 的关系

档案和预设是两个维度，但都包含 `interval` 这类键，**以最后一次操作为准**：

- `preset conservative|balanced|aggressive` 只改回收额度 / `interval` / `reclaim_order` 等键，
  不会改 `device_profile`；
- 先套档案再切预设，`interval` 会变回预设里的值；再套一次档案才能恢复档案值；
- 想稳一点：先选好预设，最后再 `profile apply` 一次，把档案值固定下来。

---

## 六、常见问题

### Q1：ColorOS 上为什么不要开 zram 接管？

ColorOS 的 zram（「内存扩展」）带写回存储，由系统守护进程管理，大小、算法、
写回策略都与系统内存管理强绑定。本模块一旦 `swapoff` + reset + `mkswap`，轻则系统
重新接管、参数被冲掉，重则内存扩展失效甚至卡开机。

所以 `coloros` 档案里 `zram_enable=0`、`vm_tune=0`，模块只往已有的 zram 里压缩页面，
不改设备。**不要**为了「多压一点」去手动打开它。

### Q2：我把 `zram_enable=1` 了，会重建吗？

默认不会（HyperOS / ColorOS 上）：只有同时满足「`zram_enable=1`」且「`zram_disksize_mb>0`」时
才会接管重建。`zram_disksize_mb=0` 表示「自动」，而在 HyperOS / ColorOS 上系统本身自管 zram，
模块会认为你没有明确要求接管，直接跳过。`generic` ROM 没有 OEM 自管判断，
`zram_enable=1` + `zram_disksize_mb=0` 仍会按自动大小（总内存一半，上限 6GB）处理。
另外，`/proc/swaps` 里 zram 正在使用时，模块也永远保持现状、不重建。

### Q3：HyperOS 的 `vm_tune=1` 到底改了什么？

只写 sysctl（`swappiness`、`vfs_cache_pressure`、`dirty_*`、`page_cluster` 等），
**不碰 zram 设备**。`zram_enable=0` 时不会 `swapoff`、不会 `mkswap`、不会改大小。
如果某项 sysctl 被系统重置，`vm_reassert` 会尝试写回。

### Q4：为什么两套档案的 `interval` / 回收额度不一样？

两套平台的 zram 策略、后台管理强度、系统服务数量都不同。ColorOS 档案更积极
（`interval=15`、`deep_pageout_max_mb=256`、`app_reclaim_interval=45`），
HyperOS 档案更保守（`20` / `192` / `60`）。这些值来自适配经验而非大规模实测，
**没有在全部机型验证**，觉得不合适可以直接改配置或换 `generic`。

### Q5：为什么 `generic` 没有 `profiles/generic.conf`？

`generic` 的语义就是「不覆盖任何值」。没有档案文件，`profile apply generic`
只会写 `device_profile=generic`，其余键保持你当前配置。这样第三方 ROM 不会被强行套上平台预设。

### Q6：自动检测错了怎么办？

用第五节的命令手工 `profile apply` 正确档案即可，不需要重刷。然后确认：

```sh
sh $ctl profile
```

如果 `detected` 与真实系统不符，说明识别属性与预期不同；把 `sh $ctl diag` 的输出
（含 ROM / oplusrom / props 过滤）发到反馈邮箱，后续可以补规则。

### Q7：升级安装会改我的参数吗？

不会（默认）。升级时如果没按音量键，走的是 `keep`：只更新 `device_profile`。
只有以下情况会覆盖：

- 刷入时按了音量键（上下）；
- 设置了 `CR_PROFILE`；
- 你手动执行了 `profile apply`。

### Q8：套完档案后悔了，能自动恢复吗？

没有自动备份，`apply` 是直接写配置。能做的只有：

- 有备份就恢复备份；
- 或者 `profile apply generic` + 手动改回想保留的值；
- 或 `rm /data/adb/cirno_reclaim/config.conf` 后重启：`post-fs-data.sh` 会从模块默认值
  重新生成一份配置（注意：这是模块默认值，不等于某个档案值，且会重置你所有手改参数）。

### Q9：ColorOS 上 `vm_tune=0`，是不是什么都不调？

是的，ColorOS 档案不改任何 VM / 内存参数，也不碰 zram。回收、冻结检测、
前台舒缓这些核心功能照常工作，只是把「调参」交给系统。

### Q10：`profile apply` 需要重启吗？

不需要。配置写完守护会在下一轮重读（也可以 `sh $ctl restart` 立即生效）。
WebUI 会重新拉一次 `snapshot`，控制台能看到新的 `device_profile` / `order` / `relief_gate`。

### Q11：怎么确认档案真的生效了？

三个地方任选：

```sh
sh $ctl profile                          # device_profile / detected / rom
grep '^device_profile=' /data/adb/cirno_reclaim/config.conf
sh /data/adb/modules/cirno_reclaim/bin/cirno_daemon --status   # "profile":"hyperos"
```

再看日志里 `RECLAIM start` 的频率是否和档案的 `interval` 相符。

---

## 七、未验证声明

- ColorOS / HyperOS / MIUI 的版本差异很多，属性判断、cgroup 布局、zram 实现、
  `dumpsys` 输出格式都可能因机型 / 版本不同而变化；
- 本版**没有在全部机型验证**，也没有真机功耗实测数据；
- 两个档案的数值是适配经验值，不保证对所有设备最优。

反馈请附：机型、系统版本、Android / 内核版本、root 方案、`sh ctl.sh diag` 的输出、日志。
邮箱：**asui20090213@outlook.com**。
