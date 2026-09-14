# 开发文档

面向继续开发 / 维护本模块的开发者（或 agent）。分四部分：

- **系统知识** — 目标应用与接口的逆向结论（维护的地基）
- **模块架构** — 代码结构与运行时行为
- **调试手册** — 已知坑与排查方法
- **重新逆向** — 当学校系统改版时的完整恢复流程

> 使用与发布流程见 [README](../README.md)；版本历史见 [CHANGELOG](../CHANGELOG.md)。

---

## 一、系统知识（逆向结论）

### 1.1 目标应用

- **数字FAFU**（`cn.edu.fafu.iportal`）——基于华为 WeLink 的校园 App
- 打卡入口链路：桌面快捷方式「打卡」→ `W3SplashScreenActivity` → 路由分发 → H5 页面
- H5 应用：`http://stuhealth.fafu.edu.cn/declarew/#/fafu/login`
- 接口服务：`http://stuhtapi.fafu.edu.cn/health-api`

### 1.2 认证机制

- 登录态为 **token**，格式 `2_<32位十六进制>`，存于 App 的 WebView localStorage
- 有效期：**滑动过期**——每次调用续期，持续调用下长期有效（保活场景实测：同一 token 连续有效近 6 小时）；
  闲置则会失效（实测 46 分钟仍有效、5.4 小时后已失效；精确阈值未测定。保活间隔 15 分钟，远低于实测下限）
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

| 文件 | 职责 |
|---|---|
| `fafu_checkin.sh` | 核心脚本：守护循环 / 签到 / 保活 / 刷新 / 开关 / 动态描述 |
| `service.sh` | 开机启动（等 `sys.boot_completed` 后拉起守护；已停用则跳过） |
| `action.sh` | 操作按钮 → 切换服务开关 |
| `customize.sh` | 安装脚本（设权限） |
| `uninstall.sh` | 卸载：停进程 / 关页面 / 清理运行时文件 |
| `update.json` | 更新检测源（`module.prop` 的 `updateJson` 指向它） |

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
3. 收尾：`am stack remove` 清理页面任务（失败回桌面兜底）

**动态描述**（`update_desc` / `desc_text`）：

- 内容：开关状态 + 签到日期时间（绝对日期，如 `🟢 已启用 · ✅ 09-14 已签到 21:30`）
- 写入：KernelSU 用 `ksud module config set override.description`（官方机制）；
  Magisk 回退为改写 `module.prop`
- 触发：签到成功 / 检测到已签 / 开关切换 / 服务启动 / 守护每 10 分钟自检

**服务开关**：状态文件 `fafu-checkin.state`（`enabled` / `disabled`）。
停用 = 停进程 + 开机不启动 + 无网络请求。

### 2.3 运行时文件（均在模块目录内）

| 文件 | 内容 |
|---|---|
| `fafu_checkin.log` | 日志（超 256KB 自动保留最近 1000 行） |
| `fafu-checkin.state` | 开关状态 |
| `fafu_checkin.status` | 最近签到记录（描述用） |
| `fafu_keepalive.status` | 保活统计（今日成功/失败、最近 token） |
| `.fafu_checkin.pid` | 守护进程 PID |
| `.fafu_checkin_done` | 当日签到完成标记 |

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
| 页面清理 | 用 `am stack remove <任务ID>`（先 `dumpsys activity activities` 提取），失败回桌面 |
| 描述对比 | `ksud module config get` 无值时回退读 `module.prop`，避免重复写入 |
| 冷却机制 | 保活刷新 30 分钟冷却，防止网络异常时频繁触发 |

### 3.4 排查入口

```sh
M=/data/adb/modules/fafu-checkin
cat $M/fafu_checkin.log            # 全量日志
sh $M/fafu_checkin.sh status       # 开关/服务/保活/token 一览
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

### 5.1 本地（Linux / WSL）

```sh
sh -n *.sh                    # 语法
python3 scripts/check_metadata.py   # 元数据
sh build.sh                   # 构建
```

功能逻辑测试建议用 **mock 环境**（临时目录 + mock busybox/ksud），
避免触碰真实 `/data/adb`。

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
