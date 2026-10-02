# 开发文档

面向继续开发 / 维护本模块的开发者（或 agent）。分六部分：

- **系统知识** — 目标应用与接口的逆向结论（维护的地基）
- **模块架构** — 代码结构与运行时行为
- **调试手册** — 已知坑与排查方法
- **重新逆向** — 当学校系统改版时的完整恢复流程
- **测试方法** — 本地 / 设备 / 端到端验证
- **维护约定** — 发布方式与协作规范

> 使用与发布流程见 [README](../README.md)；版本历史见 [CHANGELOG](../CHANGELOG.md)。
> 全流程已于 2026-09-14 验证通过（详见 §5.3）。

---

## 一、系统知识（逆向结论）

### 1.1 目标应用

- **数字FAFU**（`cn.edu.fafu.iportal`）——基于华为 WeLink 的校园 App
- 打卡入口链路：桌面快捷方式「打卡」→ `W3SplashScreenActivity` → 路由分发 → H5 页面
- H5 应用：`http://stuhealth.fafu.edu.cn/declarew/#/fafu/login`
- 接口服务：`http://stuhtapi.fafu.edu.cn/health-api`

### 1.2 认证机制

- 登录态为 **token**，格式 `2_<32位十六进制>`，存于 App 的 WebView localStorage
- 有效期：**滑动过期**——每次调用续期，持续调用下长期有效（2026-09-14 全流程实测：
  同一 token 经 32 次保活连续有效 12 小时以上，签到全程无刷新）；闲置则会失效
  （实测边界：46 分钟仍有效、5.4 小时后已失效；精确阈值未测定。保活间隔 15 分钟，远低于实测下限）
- 获取 / 刷新方式：打开打卡页触发**免密登录**
  （`HWH5.getAuthorizationCode()` → `third_party/welink/login` 换取 token）
- 没有独立的 refresh 接口——刷新只能通过"打开页面"完成

### 1.3 请求签名

所有接口请求需携带 `Authorization` 头，格式：

```
base64( 时间戳:随机数:MD5(密钥 + 签名URL + 时间戳 + 随机数):token )
```

- **密钥**：`AtPs2O1xEnhwkKDV`（从 H5 混淆代码中解出，见 §4）
- **签名 URL**：不含查询串的完整 URL，如
  `http://stuhtapi.fafu.edu.cn/health-api/sign_in/student/my/page`
- 时间戳为秒级；随机数为 16 位字母数字
- 时间戳与北京时间偏差过大会被服务端拒绝（408）

Python 验证片段：

```python
import base64, hashlib, time, random, string
SECRET = "AtPs2O1xEnhwkKDV"
def make_auth(sign_url, token):
    nonce = ''.join(random.choice(string.ascii_letters + string.digits) for _ in range(16))
    ts = int(time.time())
    h = hashlib.md5((SECRET + sign_url + str(ts) + nonce).encode()).hexdigest()
    return base64.b64encode(f"{ts}:{nonce}:{h}:{token}".encode()).decode()
```

### 1.4 关键接口

| 接口 | 方法 | 说明 |
|---|---|---|
| `sign_in/student/my/page` | POST | 查询签到任务（参数 `rows` / `pageNum`） |
| `sign_in/{id}/student/sign` | POST | 提交签到（参数 `lng` / `lat`，本任务不校验位置） |

任务时间字段（毫秒时间戳）：

- `beginTime` ~ `endTime`：主窗口 **21:30 ~ 22:30**
- `supplementEndTime`：补签截止 **23:00**
- `signInStudent.signState`：`0` 未签 / `1` 已签 / `2` 已请假

### 1.5 token 提取（设备端）

token 存放于 App 私有目录的 WebView localStorage（leveldb 格式，UTF-16LE 存储）：

```
/data/data/cn.edu.fafu.iportal/app_webview/Default/Local Storage/leveldb/
```

按文件修改时间排序读取、取最后一个匹配：

```sh
LD="/data/data/cn.edu.fafu.iportal/app_webview/Default/Local Storage/leveldb"
ls -tr "$LD" | while read f; do cat "$LD/$f"; done \
  | tr -d '\000' | grep -o '"token":"2_[0-9A-Fa-f]*"' | tail -1
```

> 需要 root。取最新值即可（每次免密登录会覆盖写入新 token）。

---

## 二、模块架构

### 2.1 文件职责

运行时的模块是「入口 + 库层目录」的多文件形态：入口只做装配与调度，能力实现按职责分 9 层，
改一个功能只需读一到两层。

**模块内（打进 zip）**

| 文件 | 职责 |
|---|---|
| `fafu_checkin.sh` | 入口：定位模块目录 → 加载配置 → 按序加载各层 → 命令分发 → 守护主循环 |
| `lib/base.sh` | 环境与工具：模块/工具链定位、日志与轮转、时间源、原子写、键值读写、JSON 单字段 |
| `lib/state.sh` | 运行时状态：服务开关、签到记录、保活统计、完成标记、四类通知标记 |
| `lib/api.sh` | 接口：token 提取、请求签名、HTTP 调用 |
| `lib/device.sh` | 设备控制：屏幕状态、前端任务枚举、打开/移除打卡页 |
| `lib/notify.sh` | 通知：降权探测、文案表、发送、每日一次去重、打扰冷却 |
| `lib/desc.sh` | 模块描述：读状态生成描述文本并写入（KernelSU 覆盖优先，回退改写元数据） |
| `lib/keepalive.sh` | 刷新 token 与白天保活（15 分钟节流、30 分钟冷却、亮屏延后） |
| `lib/signin.sh` | 签到决策：取任务 / 解析字段 / 判定该做什么 / 提交并记录（三档返回码） |
| `lib/commands.sh` | 9 个子命令的实现（分发与降权探测在入口） |
| `service.sh` | 开机启动（等 `sys.boot_completed` 后拉起守护；已停用则跳过） |
| `action.sh` | 操作按钮 → 切换服务开关 |
| `customize.sh` | 安装脚本（脚本 0755；库层按只读数据文件 0644） |
| `uninstall.sh` | 卸载：停进程 / 关页面 / 清理运行时文件 |
| `update.json` | 更新检测源（`module.prop` 的 `updateJson` 指向它） |

**只在仓库里（不打进 zip）**

| 文件 | 职责 |
|---|---|
| `build.sh` | 打包：清单含 `lib/`，打完后逐个核对产物，缺文件即构建失败 |
| `tools/run-tests.sh` · `tests/` | 断言总入口与用例（§5.1） |
| `tools/check-layer-order.sh` · `tools/layer-whitelist.txt` | 层序守卫与它的动态分派白名单 |
| `tools/lib.sh` | 共用小函数：busybox 定位、层清单读取（`read_layers`） |

**层结构的约定**（这几条是结构不变量，改结构时先读这里）：

- **加载顺序**（入口 `fafu_checkin.sh` 里的 `FAFU_LAYERS`，唯一真源）：
  `base → state → api → device → notify → desc → keepalive → signin → commands`。顺序即依赖方向：
  **一层只能引用更早加载的层**，由 `tools/check-layer-order.sh` 守着（注释里提到更后层的名字不算引用）；
  断言（`tests/harness.sh`）与打包（`build.sh`）也从入口读这份清单，不另存一份。
  注意 `keepalive` 必须早于 `signin`——签到决策会调用刷新流程。
- **缺层即响亮失败**：任一层缺失或不可读时，入口往模块日志写一行
  `模块不完整：缺少库层 <路径>` 并以非 0 退出。半装（入口在、层少一个）是最难排查的失败模式，
  宁可启动失败，也不要「某些功能悄悄不工作」。
- **打包与权限**：`build.sh` 把 `lib/` 一并打进 zip 并逐个核对产物；安装时脚本 0755、库层 0644
  （库层是 source 进来的数据，不需要可执行位）。
- **卸载不删库层**：`uninstall.sh` 只停进程、关页面、清理运行时文件，**不**删 `lib/`。模块目录随后
  由管理器整体移除即可；卸载脚本显式删自己的代码，一旦中途失败反而会留下半残模块
  （入口还在、层没了）——正是上面那条最难的故障。

### 2.1.1 通知机制

纯脚本模块没有自己的 App，通知只能借系统 shell 身份发出。机制与约束如下（均为源码/实测结论）：

| 事项 | 结论 |
|---|---|
| 发送命令 | `cmd notification post -t "<标题>" "<tag>" "<正文>" -S bigtext` |
| **执行身份** | **必须降权 shell**：`su - shell -c '...'`。root 身份发出的通知在部分 ROM 上被静默丢弃（实测 HyperOS 2 / 小米 13 Ultra：命令 `rc=0`，通知栏无任何显示），换 shell 身份后正常出现 |
| **降权探测必须验语义** | `su - shell -c CMD` 在 **KernelSU** 上会让 `-c` 落空：它用 Rust `getopts` 且默认 `StopAtFirstFree`，长度 1 的 `-` 是 free 参数、在那里就停止解析，最终 exec 出**交互式登录 shell**、把 CMD 当多余参数丢掉；`</dev/null` 下立刻 EOF 退出 **0**。只看退出码会记成「可用」，之后每条通知都变成「rc=0 但什么都没发生」。故 `probe_su` 用 `$c 'id -u'` 的输出必须等于 **2000**，并依次尝试 `su - shell -c` / `su shell -c` / `su shell /system/bin/sh -c` |
| 通知 id | **恒为 2020**，不可指定 → 只能靠 `tag` 区分事件；**同 tag 会覆盖**（静默更新，不产生新提示音） |
| channel | 恒为 `shell_cmd`（名为 "Shell command"、重要性 DEFAULT），**不可调整**声音 / 震动 / 图标 |
| 通知归属显示 | 显示为 **Shell**（AOSP 自己的 manifest 里也专门申请 `SUBSTITUTE_NOTIFICATION_APP_NAME` 来给自己的通知改名） |
| ongoing / autoCancel / 按钮 | **均不支持**。通知会一直留在通知栏，直到被同 tag 覆盖或被手动划掉 |
| `POST_NOTIFICATIONS` 权限 | shell 命令路径自身不检查该权限，只校验调用方 uid ∈ {0(root), 2000(shell)} |
| 送达验证 | **`rc=0` 不能证明通知真的出现了**——这正是必须降权的原因。只能靠目视确认 |
| Doze 延迟 | 熄屏久了系统进入 Doze，通知投递会被批处理延迟，**22:00 / 22:30 的时间敏感提醒可能晚到**，不要当成精确闹钟 |

| 关闭页面的兜底 | **绝不主动切换用户前台**。这里原有一条「回桌面兜底」（`am start ... HOME`），它假定用户原本在桌面，于是移除不彻底时把正在用手机的用户直接甩到桌面（设备实测确认）。现改为：清理不彻底就让它留在后台 |
| 缩短中断 | 打卡页会**抢前台**（`open_page` 把它作为新任务启动，无法后台打开——`start-activity` 没有任何"不抢焦点"标志）。因此改为：**一拿到新 token 就立刻 `close_page`**，前台随即回到用户原来的 App，把中断时间从"等满轮询"压缩到"登录所需的那几秒"。拿不到 token 时不提前关页，保持原有兜底时序 |
| 「把原 App 提回前台」已实测否定 | `am start --activity-reorder-to-front` 被接受（回显 `flg=0x20000`）但**无效**：只给 `-n` 组件名、以及加 `MAIN`+`LAUNCHER` 两种写法都**新建任务**，从未复用已有任务。任务管理命令也不可用 → 不存在可行的"移动任务到前台"入口，相关代码已删除 |
| `am stack remove` 的行为 | 能把页面移出前台（前台自动回到用户原 App，这是当前方案的基础），但会**留下不可见的残留记录**（`visible=false`、`sz=1`），清不掉且无实际影响——这正是原代码当初写「回桌面兜底」的原因，**不要试图再"清干净"** |
| 任务管理命令 | 本机（Android 17 / SDK 37）`am task` 与 `am stack` 的子命令**均已不可用**（只剩 `Argument expected` 报错），因此不存在「把任务移到前台」的直接入口 |

**tag 策略**：含日期的「按日滚动」（如 `fafu-sign-20260914`），同事件次日覆盖前一天 → 通知栏条数恒有上限，不会累积。

**实现约定**：

- 文案模板集中在 `_msg_*()` 系列函数里，正文**不含引号与命令替换**，可安全直接展开；
- 所有发送统一走 `notify()` / `notify_once()`，外层用单引号包住 `su - shell -c` 的命令（`$SU_MODE '...'`），
  这样正文里的双引号不会破坏引号配对——**这是本功能最容易写错的地方**；
- `probe_su()` 在启动与手动子命令时探测一次降权写法（依次尝试 `su - shell -c`、`su shell -c`、
  `su shell /system/bin/sh -c`，**以 `id -u` 输出等于 2000 为准**），结果写入 `$SU_MODE` 并记入启动日志 `notify=[...]`；
  由 `start` 派生的守护进程通过 `FAFU_SU_MODE` 继承该结果，不重复探测；
- 探测必须排在子命令 `case` **之前**——各分支会直接 `exit`，放后面就是永远执行不到的死代码；
- 「首次失败」类通知用 `$NFAIL`，「未签到提醒」**三个时点各用一个标记文件**（`$NNOSIGN` / `$NLATE` / `$NMISS`）：
  共用标记会让 22:00 那条把 23:00 那条「今晚未能自动签到」永久挡住；
- `notify_once()` **先发送、成功后才落标记**：反过来的话一次瞬时失败会让该类提醒整天不再出现；
- 预警冷却基准落在 `$NTLAST` 文件里，**不能放普通变量**：`refresh_token` 总在 `$( )` 子 shell 中调用，
  变量赋值会随子 shell 丢弃，导致冷却永不生效；
- `PL`（日期 tag）在主循环中每轮重算，避免守护进程常驻跨日后 tag 仍停在启动那天；
- 预警使用的提前量 `NOTIFY_LEAD` **只在屏幕已亮时生效**（`notify_lead()` 自带判断），
  熄屏路径不做无意义的等待。

> 已实测可用的降权写法（小米 13 Ultra / HyperOS 2 / SDK 37）：`su - shell -c '...'` 与 `su shell -c '...'` **均可**，
> 探测会优先选前者。注意 `su` 由各 root 管理器自行实现，不同设备行为可能不同，故不硬编码。

**为什么是 `cmd notification post`（而非 APK 或 `app_process`）**：

本模块是纯 Shell，**不携带任何 APK/dex**——这是安装轻、更新简单、卸载无残留的前提，也是本方案要守住的东西。
`cmd notification post` 的能力被 AOSP 硬编码限死（见上表：id 恒定、channel 恒定、无 ongoing），
而 `app_process` 跑 Java 能拿到完整的 `Notification.Builder`。**因此一个只看代码的读者会认为后者才是正确选择**——
下面记录被否决的方案与否决理由，避免重复提议：

| 被否决的方案 | 否决理由 |
|---|---|
| `app_process` + `ActivityThread.systemMain()`（参考 KernelSUGrantToast） | 能力完整（可自定义 id / channel / 图标 / ongoing），但要往模块里塞 APK、安装时抽出 `classes.dex` 与 `.so` 再删掉 APK，并引入 `HiddenApiBypass` 解除隐藏 API 限制。对「只发几条固定文案的提醒」而言代价过大，且破坏上面的无 APK 前提 |
| `am broadcast -a android.intent.action.SHOW_TOAST` | 查不到任何 AOSP 源码或官方文档支持该 action 存在（检索到的资料指向的都是 `cmd notification post`），**不可移植，不予采用** |
| `service call notification ...` | 依赖逐版本、逐 ROM 不同的 binder transaction code，且 Android 12+ 对 transaction code 增加了校验，脆弱性过高 |

> 若日后确实需要 ongoing / 按钮等能力，只能整体转向 `app_process`：那是模块结构与构建方式的改动，不是改几行，
> 因此这个选择的切换成本很高——改之前请先读完本节与上面的限制表。

### 2.2 运行时行为

**守护循环**（60 秒一跳，按当前时间分流）：

- **21:30 ~ 22:59**：签到时段。查任务 → 未签则提交；成功后写当日完成标记
  （`run_once` 返回 2 时 4 分钟后重试；每分钟循环天然重试）
- **07:00 ~ 21:25**：保活时段，每 15 分钟一次（`KA_LAST` 节流）
- 其余时间空转

**保活**（`keepalive_ping`）：

1. 调用 `sign_in/student/my/page`（rows=1）——成功即续期
2. 失败时：**熄屏** → 立即静默刷新（30 分钟冷却）；**亮屏** → 延后
   （等熄屏或 21:30 签到流程处理）

**刷新**（`refresh_token`）：

1. 静默优先：不亮屏直接打开打卡页 → 轮询 leveldb 等新 token（每 3 秒，最长 30 秒）
2. 失败且允许唤醒时：`input keyevent 224` + `wm dismiss-keyguard` 后重试
3. 收尾：`am stack remove` 清理页面任务（清理不彻底就留在后台，**不**主动切换用户前台；见 §2.1.1）

**动态描述**（`update_desc` / `desc_text`）：

- 内容：开关状态 + 签到日期时间（绝对日期，如 `🟢 已启用 · ✅ 09-14 已签到 21:30`）
- 写入：KernelSU 用 `ksud module config set override.description`（官方机制）；
  Magisk 回退为改写 `module.prop`
- 触发：签到成功 / 检测到已签 / 开关切换 / 服务启动 / 守护每 10 分钟自检

**服务开关**：状态文件 `fafu-checkin.state`（`enabled` / `disabled`）。
停用 = 停进程 + 开机不启动 + 无网络请求。

**通知**（`notify` / `notify_once`，模板见 `_msg_*`）：

- 触发：签到成功 / 补签成功 / 检测到已签到 / 检测到请假 / **当日首次**签到失败 /
  **当日首次**获取任务失败 / 22:00 与 22:30 与 23:00 未签提醒 / 打开打卡页前的预警
  （屏幕已亮时必发，与静默路径或兜底唤醒无关）
- 去重：失败类与未签提醒用标记文件做「一日一次」；同 tag 的通知相互覆盖（同日同事件不会堆积）
- 预警条件：**屏幕已亮**（本次确实会打开打卡页）且距上次打扰型通知超过 `NOTIFY_COOLDOWN`（默认 300 秒）
  才发，且排在 `open_page` **之前**，并 `sleep NOTIFY_LEAD` 留出阅读时间；
  熄屏时**不发**任何预警——那条路径是静默开页（屏幕不亮），用户看不见，发了也无意义。
  排查历史：最初只把预警挂在「兜底唤醒」分支上，结果**屏幕亮着走静默路径开页时漏报**
  （设备实测发现），故改为按「屏幕已亮 + 即将开页」判定，与走哪条路径无关；
- 机制约束与坑见 §2.1.1

### 2.3 运行时文件（均在模块目录内）

| 文件 | 内容 |
|---|---|
| `fafu_checkin.log` | 日志（超 256KB 自动保留最近 1000 行） |
| `fafu-checkin.state` | 开关状态 |
| `fafu_checkin.status` | 最近签到记录（描述用） |
| `fafu_keepalive.status` | 保活统计（今日成功/失败、最近 token） |
| `.fafu_checkin.pid` | 守护进程 PID |
| `.fafu_checkin_done` | 当日签到完成标记 |
| `.fafu_notify_fail` | 当日「失败类通知」已发标记（`notify_once` 去重） |
| `.fafu_notify_nosign` / `.fafu_notify_late` / `.fafu_notify_miss` | 22:00 / 22:30 / 23:00 三个未签时点各自的已发标记 |
| `.fafu_notify_last` | 预警通知冷却基准（unix 秒；必须落盘，见 §2.1.1） |

---

## 三、调试手册（已知坑）

### 3.1 系统命令必须重定向（KernelSU 特有问题）

`am` / `input` / `wm` 通过 binder 传递自身 fd，KernelSU 的 SELinux 策略会拒绝
向 `/data/adb` 下文件传递 → 命令报 `Failed transaction (2147483646)`。

**规则**：所有系统命令固定 `</dev/null >/dev/null 2>&1`；命令输出只进管道或临时变量。

### 3.2 busybox wget 行为

- 401 等错误响应**不会输出正文**（拿不到服务端 message）
- 判定失败要用**退出码**，不要 grep 响应体
- `-T` 超时选项是编译开关，脚本启动时探测（`WGET_T`），不支持则省略

### 3.3 其他坑（都已在代码中修复，改动时注意保持）

| 坑 | 说明 |
|---|---|
| 变量冲突 | `close_page` 的循环变量不能用 `t`（会覆盖 `refresh_token` 的返回值） |
| 熄屏检测 | `dumpsys power` 直接调用（busybox 无 dumpsys）；检测失败按"亮屏"处理 |
| 页面清理 | 用 `am stack remove <任务ID>`（先 `dumpsys activity activities` 提取）；清理不彻底就留在后台，绝不主动切换用户前台 |
| 描述对比 | `ksud module config get` 无值时回退读 `module.prop`，避免重复写入 |
| 冷却机制 | 保活刷新 30 分钟冷却，防止网络异常时频繁触发 |
| 通知引号 | `su - shell -c '...'` 外层必须用**单引号**包住，正文里的双引号才不会破坏引号配对；含引号或命令替换的正文不要直接内嵌展开 |
| 通知身份 | root 身份发通知会返回 `rc=0` 但不显示（实测 HyperOS 2），必须降权 `su - shell -c`；见 §2.1.1 |

### 3.4 排查入口

```sh
M=/data/adb/modules/fafu-checkin
cat $M/fafu_checkin.log            # 全量日志
sh $M/fafu_checkin.sh status       # 开关/服务/保活/token 一览
sh $M/fafu_checkin.sh notify       # 发一条测试通知（确认通知链路是否真的能送到）
sh $M/fafu_checkin.sh keepalive    # 手动保活（直接看 token 是否有效）
sh $M/fafu_checkin.sh once         # 手动签到检查（幂等）
```

日志关键行：`保活: ✅ token 有效 <token>` / `保活: ✅ 静默刷新成功 <旧> → <新>` /
`✅ 签到成功 [晚查寝签到]` / `获取任务失败: rc=...`。

---

## 四、重新逆向指南（当签到失效且疑似接口变更时）

按顺序执行，每步有验证点：

1. **下载 H5 资源**：从 `http://stuhealth.fafu.edu.cn/declarew/` 的 index.html
   提取 `check/js/*.js` 清单并下载（含 `app.*.js`、`chunk-vendors.*.js`）。
   验证：`app.*.js` 中能搜到 `spliceoken`。
2. **定位签名逻辑**：搜索 `spliceoken` / `hashStr` / `Authorization`。
   验证：找到 `md5(SECRET+url+ts+nonce)` 形态的表达式。
3. **解混淆**（jsjiami.com.v7）：字符串表 + RC4 解密器；注意**运行时数组会先被
   轮转**（自校验循环），静态数组需还原后使用。参考实现与适配步骤见 [`tools/re-analysis/`](../../tools/re-analysis/)。
   验证：解出的 `hashStr` 指向标准 MD5、密钥为 32 位可见字符串。
4. **验证签名**：用**登录接口**（空 token 签名）测试——
   若返回业务错误（如"authorization code does not exist"）而非 401，签名正确。
5. **更新脚本**：同步 `SECRET` / 接口路径 / 时间字段解析。

> 判定"是 token 问题还是接口变更"：先 `keepalive` 手动测 token；
> token 有效但接口报错 → 才需要走本流程。

---

## 五、测试方法

### 5.1 本地（不需要手机 / root / 网络）

```sh
sh -n *.sh lib/*.sh tools/*.sh tests/*.sh   # 语法（入口 + 库层 + 工具 + 断言）
python3 scripts/check_metadata.py           # 元数据
sh tools/check-layer-order.sh               # 层序守卫（清单取自入口的 FAFU_LAYERS）
sh tools/run-tests.sh                       # 全部断言
sh tools/run-tests.sh ^layer                # 只跑某个套件（^ 前缀匹配）
sh build.sh                                 # 构建（含产物文件核对）
```

**断言总入口 `tools/run-tests.sh`**（`tests/` 下的用例文件；harness 见 `tests/harness.sh`）：

- 基线：**170 项**（`layer` 33 + `notify` 87 + `skeleton` 50），改动后应保持全绿；
  任一项失败时脚本以非 0 退出；迁移前草稿版的计数（文档写的 92、提交记录里的 95/100）都不可靠——
  那版测试里有一个 `for` 循环因缺换行整段没执行、断言函数复用变量把部分结果静默覆盖；
  拆层前实测为 115 项。
  本机（Windows）没有 `zip`/`unzip` 时，`skeleton` 里「打包产物校验」整段（13 条断言）会**跳过**
  （计数上记为 `跳过 1 项`，不计入通过，避免「本机没跑」被读成「已验证」），此时报 157 项；
  CI 上全跑，报 170 项；
- 断言只描述**外部行为**——返回码、状态文件产物、交给系统执行的命令字符串、
  「某个时刻会发生什么」；不绑行号，重构搬代码不应制造假红灯；
- 用例通过 `tests/harness.sh` **直接加载真实层文件**：清单由 `tools/lib.sh` 的 `read_layers`
  从入口的 `FAFU_LAYERS` 读出（唯一真源），不再有「从源码里截取库段」的过渡机制；
  静态断言面对的是「各层 + 入口」按加载顺序拼出的全程序文本（`t_write_program`，只读不执行）；
- 注入缝沿用运行时既有开关，不加测试专用后门：时间走 `BB_OVERRIDE` + `tests/mock/busybox`
  （设 `MOCK_DATE_CTL` 即可把 `"$BB" date` 拨到任意时刻，`tests/skeleton.sh` 用它验时间源），
  降权写法走 `SU_MODE`，通知命令走 `NOTIFY_CMD`；
- mock 时间源需要一个**真实 busybox** 承接其余 applet：本机把它放到 `tools/busybox/`
  （该目录不入库）或用 `TEST_BUSYBOX=<路径>` 指定，CI 先装 `busybox-static`
  （见 `.github/workflows/`）；三者统一由 `tools/lib.sh` 的 `find_busybox` 定位；
- 本机（Windows）没有系统 `sh` 时用 `busybox sh tools/run-tests.sh` 跑；
  断言脚本本身保持 POSIX 兼容，CI 直接用系统 `sh`；
- 按关键字筛选用例时，含非 ASCII 的关键字在 Windows 控制台上会因代码页被改写，
  优先用 `^layer` / `^notify` / `^skeleton` 这类纯 ASCII 前缀。

**三个套件**：

- `tests/layer-order.sh`：层序守卫自证——用临时的**反向引用样本**验证守卫确实会失败
  （证明它不是永远为真的摆设），并钉住白名单（含缺失时必须明确失败）、坏清单
  （缺文件 / 重复 / 空）与「注释不算引用」的行为；
- `tests/notify.sh`：通知的调用点、文案模板、tag、冷却、去重、降权命令构造，
  以及少数**相对顺序**不变量（探测排在子命令分发之前、开页预警排在 `open_page` 之前）；
- `tests/skeleton.sh`：base 层原语（键值读写、JSON 单字段、原子写、可拨钟的时间源、日志轮转）、
  入口装配（缺一层时写日志并以非 0 退出；层齐时子命令分发可用）、打包管道
  （产物含每个层文件；少一层即构建失败）。

**覆盖不到的边界**（只能上机目视验证，见 §5.3）：`su` / `cmd notification post` 的真实送达、
Doze 投递延迟、真实 `run_once` 的端到端行为。

### 5.2 设备

```sh
# 安装后（或更新后）
sh /data/adb/modules/fafu-checkin/fafu_checkin.sh status
# 测试项：开关切换（action 按钮或 toggle）、once、refresh、keepalive
```

### 5.3 端到端

- 保活：观察日志出现 `保活: ✅ token 有效`（每 15 分钟）
- 签到：21:30 后日志出现 `✅ 签到成功`；若走补签会标记 `✅ 补签成功`
- 描述：重开管理器模块页，确认描述与 `status` 输出一致

**通知（只能目视验证，`rc=0` 不作数）**，按顺序做：

1. **先验地基**——哪条写法真能用：
   ```sh
   su - shell -c 'id -u'                 # 期望 2000；若 KernelSU 上让 -c 落空则无输出
   su shell -c 'id -u'
   su shell /system/bin/sh -c 'id -u'
   ```
2. **跑一次真通知**：`sh /data/adb/modules/fafu-checkin/fafu_checkin.sh once`，
   确认通知栏出现、标题 emoji 正常；日志里应有
   `通知链路: 降权写法 [...] 可用（id -u = 2000）`，启动行有 `notify=[...]`。
3. **测 Doze 延迟**：熄屏放置 30 分钟后触发一次，记录实际送达时间。
   若延迟超过 10 分钟，22:00 那条「还剩 30 分钟」的时点就需要重算。

**验证记录（2026-09-14，首次全流程）**：32 次保活全部成功（0 失败）→ 21:30:14 自动签到成功
（服务端 `signState=1`、`isSupplement=0`）→ 动态描述更新为 `🟢 已启用 · ✅ 09-14 已签到 21:30`；
同一 token 经 12 小时以上连续有效（保活续期效果的直接证据）。

**验证记录（2026-10-02，通知功能，`dev.135b1f8`）**：

已在设备上验证（小米 13 Ultra / Android 17 / SDK 37）：

- 降权链路可用：日志 `通知链路: 降权写法 [su - shell -c] 可用（id -u = 2000）`
- 通知**真实送达**（目视确认，非依赖 `rc=0`）
- 请假分支正确：服务端 `signState=2` → 弹「🏖 今日查寝已请假」，未误报为「已签到」
- 请假排除生效：请假当天**不发** 22:00 / 22:30 / 23:00 三条未签提醒（设计使然）
- **开页前有通知**：修掉了"屏幕亮着走静默路径开页时不通知"的漏报
- **关闭后正常返回**：不再跳到桌面；能回到用户原来正在用的 App

**尚未验证**（如实标注，勿当成已覆盖）：

- **22:00 / 22:30 / 23:00 三条未签提醒**：验证期间设备处于请假状态，按设计不发这三条，
  故其"三时点各自独立、逐条递进"的行为**尚未在真实场景中跑过**。需要一个正常上课日：
  若 21:30 未签上，三条应**依次都到**（只有第一条到即为缺陷）。
- **Doze 投递延迟**：未实测。若熄屏下延迟超过 10 分钟，22:00 那条「还剩 30 分钟」的时点需重算。
- 熄屏时段刷新"全程无感"：未专门观察。

---

## 六、维护约定

- **发布**：手动流程——CI 只构建（产物见 Actions artifact），Release 由维护者手动创建；
  发布说明以 [CHANGELOG.md](../CHANGELOG.md) 对应小节为唯一来源（构建时提取为 `release-notes.md` 草稿）
- **版本号**：手动维护（`module.prop` 的 `version` / `versionCode`），不自动递增
- **文案**：日期用绝对形式（如 `09-14`），不用「今日」等相对表述——守护进程退出后信息不失真
- **代码**：一次性 / 临时的逻辑不入代码，在会话中给出命令即可
- **文档**：只写读者需要的内容（事实 / 约定 / 方法），不记录会话过程与已取消的方案
