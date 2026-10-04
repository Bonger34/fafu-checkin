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
| `lib/state.sh` | 运行时状态的**唯一读写者**：服务开关、签到记录、保活统计、完成标记、四类通知标记、通知冷却基准；对外只给语义函数，文件格式是它的契约 |
| `lib/api.sh` | 接口：token 提取、请求签名、HTTP 调用（含 wget 超时选项探测）；`http_post` 是全程序唯一的网络出口 |
| `lib/device.sh` | 设备控制：屏幕状态、前端任务枚举、打开/移除打卡页 |
| `lib/notify.sh` | 通知：事件名 → tag 与文案、降权探测、发送、每日一次去重、打扰冷却 |
| `lib/desc.sh` | 模块描述：读状态生成描述文本并写入（KernelSU 覆盖优先，回退改写元数据） |
| `lib/keepalive.sh` | 刷新 token 与白天保活：刷新分三段（`refresh_silent` / `refresh_wake` / `refresh_finish`），保活时段 `ka_in_window`、15 分钟节流 `ka_due`、30 分钟冷却、亮屏延后 |
| `lib/signin.sh` | 签到决策：取任务 / 解析字段 / 判定该做什么 / 提交并记录（三档返回码） |
| `lib/commands.sh` | 9 个子命令与它们的**命令表**：表同时驱动子命令分发、需要降权探测的集合与用法文本（`start` 例外，见 §2.2 的守护循环） |
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

- **注释口径**：文件头只写「用法与配置」（≤15 行），**不写指向文档的指针**——层文件头写职责、
  加载顺序、对外接口与配置，约束写在它所约束的代码旁。文件内注释只留三类：用法与配置、
  一行「改这里会坏什么」的不变量、非直觉技巧的解释。否决方案、实测历史与「曾经……」叙事
  一概不进代码：它们的完整版本在本文件里，代码里只留结论。这条口径由 `tests/headers.sh`
  守着（它用反向样本自证判据真的会失败），改注释时会一起报红。
- **加载顺序**（入口 `fafu_checkin.sh` 里的 `FAFU_LAYERS`，唯一真源）：
  `base → state → api → device → notify → desc → keepalive → signin → commands`。顺序即依赖方向：
  **一层只能引用更早加载的层**，由 `tools/check-layer-order.sh` 守着（注释里提到更后层的名字不算引用）；
  断言（`tests/harness.sh`）与打包（`build.sh`）也从入口读这份清单，不另存一份。
  注意 `keepalive` 必须早于 `signin`——签到决策会调用刷新流程。
- **运行时状态只归 state 层**：模块目录里的运行时文件（开关 / 签到记录 / 保活统计 /
  完成标记 / 通知标记 / 冷却基准）只有 `lib/state.sh` 读写，其余层与入口一律经它的语义函数：
  开关 `svc_is_disabled` / `svc_set`，签到记录 `sign_get` / `sign_set`，
  保活统计 `ka_counts` / `ka_ok_count` / `ka_fail_count` / `ka_last_time` / `ka_last_result` /
  `ka_is_today` / `ka_note`，完成标记 `done_marked` / `done_mark`，
  通知标记 `notify_marked` / `notify_mark`（事件名 `fail` / `nosign` / `late` / `miss`；
  notify 层的 `failsign` 与 `failtask` 都映射到 `fail`），
  冷却基准 `nt_cooldown`。
  文件名、字段名、字段顺序、内容格式是**对外契约**（升级后不丢当日记录），
  「按日滚动」的三处判定（保活统计、完成标记、通知一日一次）也都只在本层发生。
  **唯一例外是 `service.sh`**：它是开机脚本、不加载库层，只在启动前读一次开关文件——
  读的是同一份 `disabled` 字面量，格式未变即不受影响；用一条断言
  （`tests/state.sh` 的「state · 收口边界」）钉住「只有 state 层与这一个例外持有状态文件名」。
  日志与 PID 文件不属于这五类状态，仍由 base 层与入口直接持有。
- **网络调用只经 api 层**：`api()` 负责拼 URL 与签名，**真正发起请求的只有 `http_post()` 一处**
  （wget 的调用参数、`Authorization` 头、被丢弃的 stderr 都写在它里面）；`-T` 超时选项在
  api 层**加载时探测一次**（`WGET_T`）供它使用——探测与调用同层，改网络行为不必跨层找。
  其余层不拼签名、也不直接调网络：`tests/api.sh` 用一条**命令位**判据（行首缩进后的真实调用，
  注释里提到 wget 不算）钉住「命令位的 `$BB wget`/`curl` 全程序只有一处、且只在 api 层」。
  这条缝也是测试的注入点：断言里覆盖同名函数就能离线构造响应体 / 失败 / 超时（见 §5.1）。
- **设备命令只经 device 层**：屏幕状态判定、前端任务枚举、打开打卡页、移除打卡页任务只写在
  `lib/device.sh`，其余层不直接调 `dumpsys` / `am`（`tests/device.sh` 用命令位判据钉住；
  唤醒与熄屏用的 `input` / `wm` 仍在 `keepalive` 层，加固判据一并覆盖它们）。
  两条实测确认过的行为不变量在层内落地：**屏幕判定失败一律按「亮屏」处理**（无输出或字段名
  不认识时返回 0，避免误判成熄屏走静默刷新）、**绝不主动切换用户前台**（清理不彻底只记一行
  「保留在后台」，不再有任何「回桌面」动作）。系统命令的 fd 加固逐处一致（见 §3.1）；
  `dumpsys` 的输出经**变量**承接而不是就地接管道，这样命令自身的 fd 不会流进 `/data/adb`。
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
| **降权探测必须验语义** | `su - shell -c CMD` 在 **KernelSU** 上会让 `-c` 落空：它用 Rust `getopts` 且默认 `StopAtFirstFree`，长度 1 的 `-` 是 free 参数、在那里就停止解析，最终 exec 出**交互式登录 shell**、把 CMD 当多余参数丢掉；`</dev/null` 下立刻 EOF 退出 **0**。只看退出码会记成「可用」，之后每条通知都变成「rc=0 但什么都没发生」。故 `probe_su` 先用 `command -v` 解析出 `su` 的实际路径，再用它依次尝试 `- shell -c` / `shell -c` / `shell /system/bin/sh -c`，并以 `id -u` 输出必须等于 **2000** 为准 |
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

- 业务层**只报事件名**（`sign` / `supp` / `seen` / `leave` / `failsign` / `failtask` /
  `nosign` / `late` / `miss`），tag 与文案都由 notify 层查表。新增一条通知要动三处
  （事件表 `_NT_TPL_*`、tag 表 `tag_of`、`_msg_*` 文案），但都在这一个文件里：
  - `tag_of()` 事件名 → tag 后缀（完整 tag = `fafu-<后缀>-<当日 tag>`），默认后缀就是
    事件名本身。两个例外是**对外契约**：`seen` 与 `sign` 同用 `sign`（同为「已签到」，
    同日互相覆盖不堆积）、三个未签时点用 `t2200` / `t2230` / `miss`；
  - `notify_event()` 取文案模板并发送。文案模板集中在 `_msg_*()` 系列函数里，
    正文**不含引号与命令替换**，可安全直接展开；
- 所有发送统一走 `notify()` / `notify_event()` / `notify_once()` / `notify_warn()`；
  `notify()` 负责构造命令串，**执行那一步单独放在 `nt_send()`**（与 api 层的 `http_post`
  同理）：改执行方式、或在断言里截住「最终交给系统执行的命令」都只动这一处；
- `probe_su()` 在启动与手动子命令时探测一次降权写法：先用 `command -v` 解析出 `su` 的
  实际路径（`SU_BIN` 是回退与注入点，默认 `/system/bin/su`），再依次尝试
  `<su> - shell -c`、`<su> shell -c`、`<su> shell /system/bin/sh -c`，
  **以 `id -u` 输出等于 2000 为准**，结果写入 `$SU_MODE` 并记入启动日志 `notify=[...]`；
  由 `start` 派生的守护进程通过 `FAFU_SU_MODE` 继承该结果，不重复探测；
- 探测必须发生在任何子命令分支**之前**——各分支做完就 `exit`，探测晚一步就是永远执行不到的死代码。
  这条现在是**结构上的必然**（见 §2.2 的命令表）：`cmd_dispatch` 先按表把该探测的命令探完，
  再走第二趟去分发，两趟分开写，没有「先分发还是先探测」的余地；
- 「首次失败」类通知有两个事件名（`failsign` / `failtask`）：文案与 tag 各不同，
  但**共用同一个当日标记**（`_NT_MARK_failsign` / `_NT_MARK_failtask` 都指向 state 层的 `fail`）；
- `notify_once()` **先发送、成功后才经 state 层落标记**：反过来的话一次瞬时失败会让该类提醒整天不再出现；
- 三个未签时点各自独立标记（`nosign` / `late` / `miss`）——共用标记会让 22:00 那条
  把 23:00 那条「今晚未能自动签到」永久挡住；
- 预警冷却（`notify_warn`）的判定与落盘都在 notify 层；基准经 state 层的 `nt_cooldown` 保存，
  **不能放普通变量**：`refresh_token` 总在 `$( )` 子 shell 中调用预警，变量赋值会随子 shell 丢弃；
- `notify_warn()` 的返回值就是「这次到底发没发」：**0 = 真发了**，非 0 = 被冷却挡住 /
  通知关闭 / 降权不可用。`refresh_token` 据此决定要不要 `sleep NOTIFY_LEAD`
  （没发还等，等于每次亮屏刷新都白等 5 秒）；
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

**子命令分发与命令表**（`lib/commands.sh`）：

入口只做三件事：认子命令（`cmd_known`，不在表里也不是 `start` → 打印用法并以 1 退出）、
分发（`cmd_dispatch`）、以及「不带子命令 / `start`」时的守护进程启动（入口的 `cmd_start`）。
命令表 `cmd_specs()` 一行一个子命令，四列：**名字 / 处理函数 / 是否需要降权探测 / 一行说明**，
它同时驱动三件事 —— 分发、降权探测集合、用法文本；新增子命令 = 表里加一行 + 写一个
`cmd_<名字>`（`tests/commands.sh` 用一份临时模块副本验证这条，改动仓库文件之外没有第三处要同步）。
表里没有 `start`：它的处理函数就是入口的 `cmd_start`（后台化 + 单实例判定）。

`cmd_dispatch` 分两趟：第一趟按表把该探测的命令探完（只在主 shell 里跑，`SU_MODE` 才留得住），
第二趟才找处理函数并执行。「探测先于任何分发」因此是结构上的必然，不靠注释或断言维持。
处理函数一律以 `exit` 收尾（分派到哪个子命令，这个进程就只做那一件事）；它的输出走 fd 3
接回脚本自己的 stdout，只有退出码进 `$( )`——两者混在一起会两头都坏（输出被吞掉、`$?` 里夹文字）。

**守护循环**（60 秒一跳，按当前时间分流）：

- **21:30 ~ 22:59**：签到时段。查任务 → 未签则提交；成功后写当日完成标记
  （`run_once` 返回 2 时 4 分钟后重试；每分钟循环天然重试）
- **07:00 ~ 21:25**：保活时段，每 15 分钟一次（**上界不含** 21:25：21:25 起就不保活）。
  窗口与节流都由 keepalive 层判定（`ka_in_window` / `ka_due`，入口只按结论分流），
  入口不再内联时点与间隔
- 其余时间空转

**保活**（`keepalive_ping`）：

1. 调用 `sign_in/student/my/page`（rows=1）——成功即续期
2. 失败时：**熄屏** → 立即静默刷新（30 分钟冷却）；**亮屏** → 延后
   （等熄屏或 21:30 签到流程处理）
3. 每次结果都经 state 层的 `ka_note` 落统计，日志一行同时带上「今日成功 / 失败」两个数

**刷新**（`refresh_token`）：流程按三段组织，一段一个取舍，页面与屏幕动作各归其段。

1. **`refresh_silent`（静默开页等 token）**：屏幕已亮时先发预警并留出阅读时间，
   再打开打卡页（熄屏下屏幕不亮）；随后每 3 秒采样一次 leveldb，最多 10 次
2. **`refresh_wake`（唤醒后重试）**：静默段拿不到才走这里——屏幕原本没亮时
   `input keyevent 224` 唤醒、`wm dismiss-keyguard` 解锁，再采样最多 20 次；
   **保活场景由调用方传 0 禁止唤醒**（`refresh_token "$tok" 0`），避免白天吵醒用户
3. **`refresh_finish`（收尾）**：`am stack remove` 清理页面任务（清理不彻底就留在后台，
   **不**主动切换用户前台；见 §2.1.1），再把屏幕恢复成刷新前的样子（原为关闭就恢复熄屏）

两条时序不变量**跨段**成立：拿到新 token 后由 `refresh_token` 就地提前关页（前台尽早交还
用户），拿不到则不提前关页（走完第二段再一起关）。`tests/keepalive.sh` 用真实设备命令替身
数「关了几次页」来钉住这两条。窗口、节流、保活四态同样在该套件里用拨钟覆盖。

**动态描述**（`desc_text` / `update_desc`，均在 `lib/desc.sh`）：

- 内容：开关状态 + 签到日期时间（绝对日期，如 `🟢 已启用 · ✅ 09-14 已签到 21:30`）；
  数据只经 state 层读（开关 + 最近签到记录），本层不碰任何文件格式
- 写入：KernelSU 用 `ksud module config set override.description`（官方机制）；
  Magisk 回退为改写 `module.prop`——改写前必须校验临时文件非空，
  否则一次失败的读取会把模块元数据清空（管理器里连模块名都没了）
- 触发：检测到已签到 / 已请假、签到或补签成功（`signin` 层）／启用、停用、`status`（`commands` 层）／
  服务启动、已停用退出前、守护每约 10 分钟自检（入口）；调用点共 8 处，由 `tests/state.sh` 的
  「desc · 触发点」钉住

**服务开关**：状态文件 `fafu-checkin.state`（`enabled` / `disabled`）。
停用 = 停进程 + 开机不启动 + 无网络请求。

**通知**（`notify_event` / `notify_once` / `notify_warn`，模板见 `_msg_*`，tag 见 `tag_of`）：

- 触发：签到成功 / 补签成功 / 检测到已签到 / 检测到请假 / **当日首次**签到失败 /
  **当日首次**获取任务失败 / 22:00 与 22:30 与 23:00 未签提醒 / 打开打卡页前的预警
  （屏幕已亮时必发，与静默路径或兜底唤醒无关）
- 去重：失败类与未签提醒用标记文件做「一日一次」（失败类的两个事件名共用一个标记）；
  同 tag 的通知相互覆盖（同日同事件不会堆积）
- 预警条件：**屏幕已亮**（本次确实会打开打卡页）且距上次打扰型通知超过 `NOTIFY_COOLDOWN`（默认 300 秒）
  才发，且排在 `open_page` **之前**，并 `sleep NOTIFY_LEAD` 留出阅读时间；
  熄屏时**不发**任何预警——那条路径是静默开页（屏幕不亮），用户看不见，发了也无意义。
  排查历史：最初只把预警挂在「兜底唤醒」分支上，结果**屏幕亮着走静默路径开页时漏报**
  （设备实测发现），故改为按「屏幕已亮 + 即将开页」判定，与走哪条路径无关；
- 机制约束与坑见 §2.1.1

### 2.3 运行时文件（均在模块目录内）

除日志与 PID 文件外，下表所有文件的读写都收口在 `lib/state.sh`（见 §2.1 的层结构约定）：
其余层只经它的语义函数访问，不直接碰文件。

| 文件 | 内容 | 写入者 |
|---|---|---|
| `fafu_checkin.log` | 日志（超 256KB 自动保留最近 1000 行） | base 层 `log` / `rotate_log` |
| `.fafu_checkin.pid` | 守护进程 PID | 入口 |
| `fafu-checkin.state` | 开关状态（`enabled` / `disabled`） | state 层 `svc_set` |
| `fafu_checkin.status` | 最近签到记录（描述用） | state 层 `sign_set` |
| `fafu_keepalive.status` | 保活统计（今日成功/失败、最近 token） | state 层 `ka_note` |
| `.fafu_checkin_done` | 当日签到完成标记 | state 层 `done_mark` |
| `.fafu_notify_fail` | 当日「失败类通知」已发标记（`notify_once` 去重） | state 层 `notify_mark fail` |
| `.fafu_notify_nosign` / `.fafu_notify_late` / `.fafu_notify_miss` | 22:00 / 22:30 / 23:00 三个未签时点各自的已发标记 | state 层 `notify_mark nosign` / `late` / `miss` |
| `.fafu_notify_last` | 预警通知冷却基准（unix 秒；必须落盘，见 §2.1.1） | state 层 `nt_cooldown` |

---

## 三、调试手册（已知坑）

### 3.1 系统命令必须重定向（KernelSU 特有问题）

`am` / `input` / `wm` 通过 binder 传递自身 fd，KernelSU 的 SELinux 策略会拒绝
向 `/data/adb` 下文件传递 → 命令报 `Failed transaction (2147483646)`。

**规则**：所有系统命令固定 `</dev/null >/dev/null 2>&1`；命令输出只进管道或临时变量。

### 3.2 busybox wget 行为

- 401 等错误响应**不会输出正文**（拿不到服务端 message）
- 判定失败要用**退出码**，不要 grep 响应体：`api()` 原样返回 wget 的退出码，
  调用方只按它分流（超时与「token 失效」在 busybox wget 下根本区分不出来）
- `-T` 超时选项是编译开关，api 层加载时探测一次（`WGET_T`），不支持则整段省略；
  探测与调用同在 `lib/api.sh`，改网络行为不必跨层找
- 请求由 `http_post()` 统一发出（`wget -q -O - --header=Authorization: ... --post-data=''`），
  它的 stderr 被丢弃——错误正文本来就没有，留着只会污染调用方的 stderr

### 3.3 其他坑（都已在代码中修复，改动时注意保持）

| 坑 | 说明 |
|---|---|
| 变量冲突 | `close_page` 的循环变量不能用 `t`（会覆盖 `refresh_token` 的返回值） |
| 熄屏检测 | `dumpsys power` 直接调用（busybox 无 dumpsys）；检测失败按"亮屏"处理 |
| 页面清理 | 用 `am stack remove <任务ID>`（先 `dumpsys activity activities` 提取）；任务号取的是活动记录里两处 `t<数字>`（`u0 ` 之后与记录末尾 `}` 之前），两处取到的是同一个号；清理不彻底就留在后台，绝不主动切换用户前台 |
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
   轮转**（自校验循环），静态数组需还原后使用。参考实现与适配步骤见 [`tools/re-analysis/`](../tools/re-analysis/)。
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

- 基线：**627 项**（`api` 45 + `commands` 53 + `device` 50 + `headers` 20 + `keepalive` 66 +
  `layer` 33 + `notify` 110 + `signin` 93 + `skeleton` 43 + `state` 114），
  改动后应保持全绿；任一项失败时脚本以非 0 退出；迁移前草稿版的计数（文档写的 92、提交记录里的 95/100）
  都不可靠——那版测试里有一个 `for` 循环因缺换行整段没执行、断言函数复用变量把部分结果静默覆盖；
  拆层前实测为 115 项。
  本机（Windows）没有 `zip`/`unzip` 时，`skeleton` 里「打包产物校验」整段（13 条断言）会**跳过**
  （计数上记为 `跳过 1 项`，不计入通过，避免「本机没跑」被读成「已验证」），此时报 627 项；
  CI 上全跑，报 640 项；
- 断言只描述**外部行为**——返回码、状态文件产物、交给系统执行的命令字符串、
  「某个时刻会发生什么」；不绑行号，重构搬代码不应制造假红灯。
  需要容忍「空白量可变」时（例如 case 分支的对齐空格）用 `t_has_re`（正则），
  不要用 `t_has` 写死空格；
- 用例通过 `tests/harness.sh` **直接加载真实层文件**：清单由 `tools/lib.sh` 的 `read_layers`
  从入口的 `FAFU_LAYERS` 读出（唯一真源），不再有「从源码里截取库段」的过渡机制；
  静态断言面对的是「各层 + 入口」按加载顺序拼出的全程序文本（`t_write_program`，只读不执行）；
- 注入缝沿用运行时既有开关，不加测试专用后门：时间走 `BB_OVERRIDE` + `tests/mock/busybox`
  （设 `MOCK_DATE_CTL` 即可把 `"$BB" date` 拨到任意时刻，`tests/skeleton.sh` 与 `tests/state.sh`
  用它验时间源与跨日行为；秒位没有可控来源，完整时间戳固定输出 `:00`），
  `tests/signin.sh` 的拨钟更进一步：它把 `_now +%s` 也换成断言自己的 EPOCH
  （`MOCK_DATE_CTL` 只管展示格式），于是「窗口判定读的是哪个时钟」这件事本身也被钉住——
  signin 层若绕过 base 层的时间源直接调 `date +%s`，那一套边界断言会立刻报红；
  降权写法走 `SU_MODE`（探测本身走 `SU_BIN`），通知命令走 `NOTIFY_CMD`，
  **发送走 `nt_send`**（覆盖同名函数即可截住「最终交给系统执行的命令」，
  `tests/notify.sh` 用它断言 tag / 标题 / 正文与发送失败分支），
  **网络走 `http_post`**（覆盖同名函数即可注入响应体 / 退出码，`tests/api.sh` 用它复现
  「响应异常 / 超时」两条路径），token 目录走 `LD_DIR`（加载时生效；同一驱动内要换目录
  直接改 `LD`）；
  要看**真实发出的命令行**时，把 `MOCK_WGET_DIR` 指向一个控制目录，替身 busybox 会逐个记录
  每次 wget 的参数并按 `help` / `body` / `rc` / `stderr` 四个文件应答（`tests/api.sh` 用它
  钉住含超时选项与请求头的完整命令行）；
  要看**真实发出的设备命令**时，`tests/device.sh` 的 `dv_setup` 会把 `am` / `input` / `wm` /
  `dumpsys` 四个包装器放进工作目录的 `bin/` 并排到 PATH 最前（真机上它们同样在 `/system/bin`
  下、不是 busybox applet），包装器转给替身 busybox 的同名 applet：替身按 `MOCK_DEVICE_DIR`
  下的 `power.txt` / `activity.txt` / `rc` 应答，并把每次调用的**逐个参数与 fd 见证**追加进
  `calls`。fd 见证只在某个 fd 真的接到普通文件时报警（`file`），是「加固是否还在」的负向守卫
  ——`</dev/null` 这类写法本身由静态命令位判据钉住；
- mock 替身需要一个**真实 busybox** 承接其余 applet：本机把它放到 `tools/busybox/`
  （该目录不入库）或用 `TEST_BUSYBOX=<路径>` 指定，CI 先装 `busybox-static`
  （见 `.github/workflows/`）；三者统一由 `tools/lib.sh` 的 `find_busybox` 定位。
  替身只在对应控制变量被设置时接管那处环境事实（完全不设就等价于透传）：时间源
  `MOCK_DATE_CTL`、`/dev/urandom`（`MOCK_RANDOM_CTL`；Windows 上没有这个设备，
  签名随机数会退化成空串）、wget（`MOCK_WGET_DIR`）、设备命令（`MOCK_DEVICE_DIR`）、
  降权命令（`MOCK_SU_EMPTY` / `MOCK_SU_ID`，配合包装脚本，见下面的说明）；
  其余 applet 一律透传；
- 本机（Windows）没有系统 `sh` 时用 `busybox sh tools/run-tests.sh` 跑；
  断言脚本本身保持 POSIX 兼容，CI 直接用系统 `sh`；
- **Windows + busybox 的四个坑**（本机专属，CI 的 Linux 上不存在）：
  ① 写驱动脚本不能 `cat > "$name.sh"` 之后再追加前导——驱动主体是从 stdin 读进来的，
  那个 heredoc 会变成脚本进程的 stdin，写出来顺序正好颠倒；先落临时文件再拼接；
  ② PATH 上的包装脚本第一行必须是 `#!<busybox> sh`（本机扩展名缺失时只认这种 shebang），
  解释器会把一个多余的 `sh` 留在参数最前面，替身要认；
  ③ `su` 是 busybox 的**内建 applet**，PATH 上的同名文件拦不到它——探测改成显式走 `SU_BIN`；
  ④ 工作目录路径里带空格时，`$变量` 当命令名会因词分割执行失败——顶掉命令要用同名**函数**
  （`nt_send` / `http_post`），不要用「把变量指向函数名」的写法；
- **被 shell 与断言咬过的两处写法**（都在 `tests/signin.sh` 里踩过，改代码/改断言时尽量避开）：
  ① 驱动前导用**不带引号**的 heredoc 拼接时，`$( )` 与 `${ }` 会在**写入时**就被展开，
  生成出来的脚本里只剩空串——不是报错，是静默变成另一段程序。要留给运行时展开就写 `\$`；
  ② 分层时**删掉的那个东西往往正是活性所在**：签到提交的成败判据原先写作
  `[ $rc -eq 0 ] && ! echo "$resp" | grep -q '"timestamp"'`，按注释应当「没有 timestamp 才算成功」，
  但实测该式在 busybox 1.35 上把两档判反了（无 timestamp 的响应被判成失败、带 timestamp 的
  被判成成功）。这类判据一旦拆进新函数，就会被新写下的断言原样固化下来——所以断言必须与
  **注释声明的语义**对齐，而不是与旧实现的输出对齐；否则旧 bug 会跟着注释一起被"验证通过"。
- 驱动脚本里的路径**一律用相对路径**（`cd` 进临时目录再以 `./x.sh` 运行）：
  Windows 的 `D:/...` 在 sh 里既没有根目录也会被当成分隔符，喂进被测代码会得到 `/mod/...`
  这类残缺路径（踩过）；被测代码在设备上用的仍是绝对路径，这里只是替身环境；
  驱动本体需要的绝对路径（如 `SU_BIN`、`T_WORK`）由前导写好——**别在驱动里读 `$PWD`**；
- 每个驱动一份独立的工作目录（`tests/.work/notify-<驱动名>`）：同一条用例里的多个驱动
  共用目录时，后一个驱动会覆盖前一个留下的产物，断言会静默空转（踩过）；
- 按关键字筛选用例时，含非 ASCII 的关键字在 Windows 控制台上会因代码页被改写，
  优先用 `^api` / `^commands` / `^device` / `^headers` / `^keepalive` / `^layer` / `^notify` /
  `^skeleton` / `^state` / `^desc` 这类纯 ASCII 前缀。

**十个套件**：

- `tests/headers.sh`：注释口径守卫——检查入口 + `lib/` + `tools/` + `tests/` 下的 `.sh`
  （与 CI 的语法检查同一组 glob），要求每个脚本的首个注释块不超过 15 行（只留用法与配置），
  且代码里不出现指向文档的指针（`.md` / README / 开发文档 …）与历史叙事
  （踩过 / 曾经 / 重构前 / 实测 …）。两条判据都是启发式的：行数按「跳过 shebang 与块前空行、
  也认缩进注释」数，字样按**字节**做字面量匹配（中文在 `LC_ALL=C` 下才匹配得上，
  本机与 CI 才会给同一结果）。守卫自己不在被检查之列——它的判据里就必须写出那几类字样，
  `HD_FILES` 因此留了一个可覆盖清单的口子。三条扫描断言各自先确认「被扫描的脚本数不为零」
  （清单落空时的零命中是假绿），反向样本自证判据不是摆设：一份 16 行头部的临时样本必须被
  数出超限（块前加空行的等价写法也一样）、一份写着「踩过」与 README 的样本必须被全量扫描
  命中、干净样本必须零命中；
- `tests/layer-order.sh`：层序守卫自证——用临时的**反向引用样本**验证守卫确实会失败
  （证明它不是永远为真的摆设），并钉住白名单（含缺失时必须明确失败）、坏清单
  （缺文件 / 重复 / 空）与「注释不算引用」的行为；
- `tests/api.sh`：api 层的三条口径——token 提取（按文件修改时间取最新那份里的最后一个，
  leveldb 里的 NUL 与诱饵字段都覆盖）、签名串构造（解开 base64 逐段核对公式、随机数、
  单行、密钥与接口地址未变）、网络注入点（覆盖 `http_post` 注入响应体 / 失败 / 超时，
  断言 URL、查询串、退出码原样传递，以及真实 wget 命令行与超时选项探测的两条分支）；
- `tests/commands.sh`：命令表的四条口径——**分发**（表里的名字进哪个处理函数、退出码原样出来、
  命令自己的输出不被吞掉；不在表里的名字什么都不做）、**同源**（表同时决定「分发到哪」与
  「探测哪些命令」，按真实命令表生成记录桩，断言不另抄一份名单）、**顺序**（每条命令各跑一次、
  清一次记录，于是「记录的第一行」就是这次调用的第一个动作：需要探测的四条先探测再分发，
  其余五条直接分发）、**用法**（集合与顺序取自表、逐字比对、未知子命令非 0 退出）。
  另有一条「**加一个子命令 = 表里加一行**」：在临时模块副本里插一行 + 一个最小处理函数，
  验证新命令可执行且出现在用法里（不动仓库文件），以及入口与层的静态边界（入口不再内联
  子命令分支 / 降权探测 / 用法文本，仍保留分发、后台化、单实例判定与主循环）；
- `tests/device.sh`：device 层的三条口径——屏幕判定（三种唤醒字段各一条，取不到状态时按
  「亮屏」处理）、任务枚举（并排记录、重复行去重、无关包不算）、设备命令（开页 / 移除任务的
  真实命令行、清理不彻底的收尾日志、`am` 与 `dumpsys` 的加固判据），以及**两条时序不变量**：
  取不到新 token 时不提前关页（只关一次）、拿到新 token 后立即关页（提前关 + 收尾关）。
  时序用例只注入 token 来源与 `sleep`，`open_page` / `close_page` 跑真实实现，断言数的是
  它们**实际发出的 `am` / `dumpsys` 条数**（stub 掉被测对象时这些数字会塌掉，防止空转）；
- `tests/keepalive.sh`：keepalive 层的三条口径——**保活窗口的时点边界**（06:59 / 07:00 /
  21:24 / 21:25 / 21:26 / 21:30，拨钟逐点断言；上界**不含** 21:25）、
  **刷新三段**（熄屏静默成功、静默整段拿不到后
  唤醒重试成功、亮屏不唤醒；关页次数与熄屏键/唤醒键都由设备命令替身的真实记录数出来）、
  **保活四态**（token 有效 / 亮屏延后 / 熄屏静默刷新 / 冷却中不再刷新）与 15 分钟节流的
  拨钟边界。token 来源是 `ld/` 目录里一串**按 mtime 生长**的 leveldb 夹具（`ka_tokens`），
  于是 `get_token` / `refresh_token` / `open_page` / `close_page` 全部跑真实实现；
  另有**静态结构边界**断言（三段各归其位、窗口判定收口在本层且上界方向为 `-lt`、
  入口不再内联魔数）；
- `tests/notify.sh`：通知层的四条口径——降权探测（替身 su 复现「`-c` 落空、命令没跑、
  退出码却是 0」这条设备语义，验「以 `id -u` 输出等于 2000 为准」与三个候选依次尝试）、
  事件名 → tag 与文案（事件清单直接从层里的映射表读出，不在测试里另抄一份）、
  发送（`nt_send` 缝截住真实构造出的命令串）与每日一次去重（发送失败不落标记）、
  打扰冷却（基准落盘、子 shell 内仍生效、返回值被调用方用来决定要不要等）。
  两条**相对顺序**不变量各有一半：预警排在 `open_page` 之前由一次真实 `refresh_token`
  的时间线钉住（通知与设备命令落进同一条记录）；探测排在子命令分发之前由
  `tests/commands.sh` 的两条判据钉住（静态那半 + 按时间顺序的记录那半），
  这里只看通知层自己的调用点还在；
- `tests/signin.sh`：签到决策的四条口径——**三档返回码**（0 已解决 / 1 可重试 / 2 任务异常）、
  **四个判定分支**（不在时段 / 已签到 / 已请假 / 窗口内提交）、**窗口边界**（21:29 / 21:30 /
  22:30 / 22:59 / 23:00 逐点各比一侧，基准是毫秒时刻而不是「几点几分」）、
  **提交并记录**（主窗口与补签的区分、成功才落记录与通知、失败当日仅首次通知）；
  另有解析契约（字段写回调用方、截止回退 `endTime`、坐标回退内置值）与静态判据
  （「取任务 → 解析 → 判定 → 提交」的调用顺序、token 一路传到提交）；
- `tests/state.sh`：state 层的读写契约与 desc 层的呈现——五类状态的文件名/字段名/字段顺序/
  内容格式逐字节断言（含「旧版本写下的文件仍读得出」）、跨日归零与按日滚动（用拨钟验证）、
  通知「发送失败不落标记」、描述文案逐字比对、写入契约（改写元数据仍保留其余行、
  临时文件为空时拒绝写入）与 8 处描述触发点；
- `tests/skeleton.sh`：base 层原语（键值读写、JSON 单字段、原子写、可拨钟的时间源、日志轮转）、
  入口装配（缺一层时写日志并以非 0 退出；层齐时子命令分发可用；开关文件往返）、打包管道
  （产物含每个层文件；少一层即构建失败）。「临时模块副本」这一步由 harness 的
  `t_stage_module` 提供，`tests/commands.sh` 与它共用同一份实现。

**写含中文的日志断言时注意**：本机（Windows + zh_CN.UTF-8）的 busybox `grep` 匹配不上
多字节字符，`grep 中文` 恒为 0 处（实测）。`tests/keepalive.sh` 因此把这类断言拆成两步：
用 `LC_ALL=C grep -aF` 取**纯 ASCII 片段**数行数，再把日志窗口抓成小文件后用 `t_has`
逐字比对中文文案（`ka_log` / `ka_near`）。同理，`grep -E` 的字符类要用 `[[:space:]]`
并先 `set -f`——`[ \t]` 在这条链路上会退化成「空格或字母 t」，转义括号会直接报 bad regex。

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
   `通知链路: 降权写法 [...] 可用（id -u = 2000）`（写法带完整路径，如
   `[/system/bin/su - shell -c]`），启动行有 `notify=[...]`。
3. **测 Doze 延迟**：熄屏放置 30 分钟后触发一次，记录实际送达时间。
   若延迟超过 10 分钟，22:00 那条「还剩 30 分钟」的时点就需要重算。

**验证记录（2026-09-14，首次全流程）**：32 次保活全部成功（0 失败）→ 21:30:14 自动签到成功
（服务端 `signState=1`、`isSupplement=0`）→ 动态描述更新为 `🟢 已启用 · ✅ 09-14 已签到 21:30`；
同一 token 经 12 小时以上连续有效（保活续期效果的直接证据）。

**验证记录（2026-10-02，通知功能，`dev.135b1f8`）**：

已在设备上验证（小米 13 Ultra / Android 17 / SDK 37）：

- 降权链路可用：日志 `通知链路: 降权写法 [su - shell -c] 可用（id -u = 2000）`
  （该次记录早于本次改动；改动后同一条会记成 `[/system/bin/su - shell -c]`）
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
