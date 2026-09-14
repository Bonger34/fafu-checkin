# 数字FAFU 晚查寝自动签到

面向福建农林大学「数字FAFU」App 的晚查寝签到自动化模块，支持 **KernelSU** 与 **Magisk**。

安装后全自动运行：白天静默保活、晚上定时签到，全程无感知。

## ✨ 功能特性

- **自动签到**：每天 21:30 ~ 22:30 每分钟检查，未签到自动提交，签完即止
- **补签兜底**：若主窗口未成功，会自动在补签时段（22:30 ~ 23:00）内继续重试，最大限度避免漏签
- **静默保活**：07:00 ~ 21:25 每 15 分钟轻量调用一次接口，保持登录状态不过期；每次结果均写入日志与统计（`status` 可查看今日成功/失败数）
- **静默刷新**：登录状态失效时自动在后台刷新，熄屏状态下屏幕不会亮起
- **无感运行**：全程后台，不弹出页面、不残留任务、不打断使用
- **操作按钮**：点击模块「操作」按钮，一键启用 / 停用服务（即时生效，无需重启）
- **动态描述**：模块描述显示开关状态与签到日期时间（例如 `🟢 已启用 · ✅ 09-14 已签到 21:30`），采用绝对日期，即使服务异常退出也能从日期判断信息时效
- **双平台**：KernelSU / Magisk 通用

## 📦 安装

1. 获取模块包（二选一）：
   - 下载 Release 中的 `fafu-checkin-*.zip`
   - 自行打包：`sh build.sh`（生成到 `dist/`）
2. 打开 KernelSU / Magisk 管理器 → 模块 → 从本地安装 → 选择 zip
3. 重启手机

## 🔄 更新

模块内置更新检测（`updateJson`），管理器会定期检查新版本：

- **KernelSU**：模块页会显示更新提示，点击即可更新
- **Magisk**：模块页出现「更新」按钮，一键完成

更新源：仓库根目录的 [`update.json`](update.json)（指向最新 Release）。

> **发布新版本时**需更新 `update.json` 的 `version` / `versionCode` / `zipUrl` 三项
> （可用 `scripts/sync_update_json.py` 生成，见「开发与发布」）；
> `changelog` 固定指向本仓库 `CHANGELOG.md` 的 raw 地址（管理器按 Markdown 渲染），无需随版本改动。
>
> 注意：`changelog` 不能填 GitHub Release 网页地址（那是 HTML 页面，管理器会把它当纯文本渲染，
> 显示成一堆 HTML 源码）；请始终使用 raw 文件地址。

## 🎛️ 操作按钮（服务开关）

点击模块的「操作」按钮即可切换服务开关：

- **🟢 已启用** → 点击后停用：停止后台服务，不再进行任何网络请求
- **⏸ 已停用** → 点击后启用：恢复后台服务与自动签到

模块描述会动态显示当前状态与签到信息（日期均为绝对日期）：

| 描述示例 | 含义 |
|----------|------|
| `🟢 已启用 · ⏳ 09-14 未签到` | 服务运行中，09-14 尚未签到 |
| `🟢 已启用 · ✅ 09-14 已签到 21:30` | 09-14 已签到（含签到时间） |
| `🟢 已启用 · 🏖 09-14 已请假` | 09-14 状态为请假 |
| `⏸ 已停用 · 最近签到 09-13 21:31` | 服务已停用，显示最近一次签到 |
| `⏸ 已停用 · 暂无签到记录` | 服务已停用且无签到记录 |

> 描述在事件发生时自动更新（签到成功、开关切换、服务启动），平时每约 10 分钟自动检查一次；
> 若操作后未立即变化，重新打开模块页或下拉刷新即可。
>
> 描述使用绝对日期（MM-DD）而非“今日”等相对表述：即使守护进程意外退出导致描述停止更新，
> 也能通过日期直观判断信息的时效性，不会产生“今日已签到”之类的误导。
>
> 实现方式：KernelSU 使用官方模块配置 `override.description` 覆盖（不修改模块文件，卸载时自动清除）；
> Magisk 下则直接更新 `module.prop` 描述作为兼容方案。

## 🚀 使用

安装后自动运行，无需任何操作。

```sh
# 查看日志（位于模块目录内）
cat /data/adb/modules/fafu-checkin/fafu_checkin.log

# 手动命令（需要 root）
sh /data/adb/modules/fafu-checkin/fafu_checkin.sh status    # 查看开关 / 服务 / 保活 / token 状态
sh /data/adb/modules/fafu-checkin/fafu_checkin.sh keepalive # 手动执行一次保活检查
sh /data/adb/modules/fafu-checkin/fafu_checkin.sh toggle    # 切换服务开关（启用 ⇄ 停用）
sh /data/adb/modules/fafu-checkin/fafu_checkin.sh enable    # 启用服务
sh /data/adb/modules/fafu-checkin/fafu_checkin.sh disable   # 停用服务
sh /data/adb/modules/fafu-checkin/fafu_checkin.sh once      # 立即检查一次（幂等）
sh /data/adb/modules/fafu-checkin/fafu_checkin.sh start     # 启动服务（若已停用则忽略）
sh /data/adb/modules/fafu-checkin/fafu_checkin.sh stop      # 停止服务（不改变开关状态）
```

## ⚙️ 配置（可选）

在模块目录创建 `fafu-checkin.conf`（即 `/data/adb/modules/fafu-checkin/fafu-checkin.conf`），可覆盖默认行为：

```sh
# 关闭白天保活（仅保留 21:30 自动签到）
KEEPALIVE=0
```

修改后执行 `stop` 再 `start` 即可生效（或重启手机）。

## ❓ 常见问题

**Q：手机锁屏/息屏时能正常工作吗？**

A：可以。熄屏状态下的刷新是静默的（屏幕不亮、不唤醒），实测熄屏下数秒内即可完成刷新。

**Q：如何临时暂停自动签到？**

A：点击模块「操作」按钮即可停用服务（再点一次恢复）；停用期间不会进行任何网络请求。也可以用 `disable` / `enable` 命令。

**Q：停用服务和在管理器里禁用模块有什么区别？**

A：操作按钮是**服务级开关**（即时生效、可随时恢复）；管理器里的禁用是**模块级**操作（需重启生效，且禁用后操作按钮无法执行）。日常暂停建议使用操作按钮。

**Q：会重复签到吗？**

A：不会。每次先查询签到状态，已签到自动跳过。

**Q：白天会不会打扰我？**

A：不会。保活只是轻量接口请求；仅当登录状态失效时才会刷新，且屏幕亮着时会延后：
- 熄屏后自动静默刷新（屏幕不亮、不唤醒，无感知）；
- 若一直亮屏，则留到 21:30 签到时段一并处理（此时页面短暂出现，你能直观理解是签到引起的）。

**Q：亮屏时保活还工作吗？**

A：工作。保活调用不受屏幕状态影响（每 15 分钟一次）；只有“调用失败后的刷新”会延后到熄屏
或签到时段，避免白天出现无解释的页面弹出。

**Q：怎么确认保活一直在正常工作？**

A：两种方式：
- 运行 `status` 命令，会显示保活状态与具体 token，例如：
  `保活: 最近 12:15:30 ✅ · 今日 24 成功 / 0 失败`、`token: 有效 2_EAA268...`；
- 查看日志，每次保活都有一条记录且带具体 token：
  - 成功：`保活: ✅ token 有效 2_EAA268... (今日 24 成功 / 0 失败)`
  - 刷新：`保活: ✅ 静默刷新成功 2_OLD... → 2_NEW...`
  - 失败：`保活: ❌ 调用失败 2_... (今日 24 成功 / 1 失败) — 屏幕亮着，延后（熄屏或签到时段自动刷新）`
  若某个时段缺少记录，说明服务可能中断（可结合 `status` 的服务运行状态排查）。

日志超过 256KB 会自动轮转（保留最近 1000 行），无需手动清理。

**Q：需要手机在签到范围内吗？**

A：本模块适用于不校验位置的签到任务。如学校要求定位，请遵守相关规定。

**Q：日志出现「获取任务失败」怎么办？**

A：多为网络问题，会自动重试；若持续出现，可能是系统接口变更，请提 Issue。

## 📁 文件说明

| 文件 | 说明 |
|------|------|
| `module.prop` | 模块信息（名称 / 版本 / 作者 / 更新源） |
| `customize.sh` | 安装脚本：设置脚本权限 |
| `service.sh` | 开机启动：等待系统就绪后拉起守护进程（已停用则跳过） |
| `action.sh` | 操作按钮：切换服务开关（启用 / 停用） |
| `uninstall.sh` | 卸载脚本：停止服务、关闭页面、清理生成文件 |
| `fafu_checkin.sh` | 核心脚本：守护 / 签到 / 保活 / 刷新 / 开关 / 动态描述 |
| `update.json` | 更新源：管理器据此检测新版本 |
| `CHANGELOG.md` | 版本更新日志 |
| `build.sh` | 本地打包工具 |

运行时文件（全部位于模块目录内，随模块卸载一并清除）：

| 文件（模块目录内） | 说明 |
|------|------|
| `fafu_checkin.log` | 运行日志（每次保活/签到均记录；超 256KB 自动轮转） |
| `fafu-checkin.state` | 服务开关状态 |
| `fafu_checkin.status` | 最近签到记录（用于动态描述） |
| `fafu_keepalive.status` | 保活统计（今日成功/失败次数、最近一次时间） |
| `.fafu_checkin.pid` | 守护进程 PID |
| `.fafu_checkin_done` | 当日签到完成标记 |

> 说明：模块更新（重装新版本）会替换整个模块目录，因此上述运行时文件（日志、开关、签到记录）
> 会随更新重置；开关恢复为默认的“已启用”。如需保留日志，请在更新前自行备份。

## 🗑️ 卸载

在管理器中卸载模块并重启即可，卸载脚本会自动清理干净：

- 停止后台服务（含进程兜底清理）
- 关闭可能残留的签到页面
- 删除模块运行期间生成的全部文件（均位于模块目录内，随模块目录一并移除）
- 动态描述配置由 KernelSU 在卸载流程中自动清除

无需手动清理任何文件，`/data/adb/` 根目录也不会留下任何残留。

## 🛠️ 开发与发布

### 环境要求

推荐 **WSL2（Ubuntu）** / Linux / macOS；Windows 下也可使用 Git Bash（注意换行符与文件权限）。

```sh
# 一次性准备（WSL2 示例）
sudo apt update && sudo apt install -y git zip

# 克隆与构建
git clone https://github.com/Bonger34/fafu-checkin.git
cd fafu-checkin
sh build.sh          # 发布构建 → dist/fafu-checkin-<版本>.zip
sh build.sh dev      # 开发构建 → dist/fafu-checkin-<版本>-dev.<commit>.zip
```

> 提示：仓库已通过 [`.gitattributes`](.gitattributes) 强制 **LF 换行**，请勿改回 CRLF
> （会导致脚本在设备上无法执行）；在 Windows 下打包建议使用 WSL，以保留脚本的可执行权限
> （安装脚本也会自动修正权限，作为兜底）。

### 两种构建模式

| 命令 | 产物名 | 用途 |
|---|---|---|
| `sh build.sh` | `fafu-checkin-v1.1.6.zip` | **发布**（文件名与 `update.json` 的 `zipUrl` 对应） |
| `sh build.sh dev` | `fafu-checkin-v1.1.6-dev.5c1a6a4.zip` | **日常测试**（带 commit 标识，可追溯） |

CI 的自动构建使用 **dev 模式**：产物名带短 commit（如 `fafu-checkin-dev-5c1a6a4`），
便于在多次 push 之间区分；正式发布时使用干净的发布构建产物。

### 安装到设备

```sh
adb push dist/fafu-checkin-*.zip /sdcard/Download/
# 然后在 KernelSU / Magisk 管理器中「从本地安装」
```

或等待 CI 发布后在管理器内直接更新。

### 发布新版本（手动发布）

自动化仅负责**构建**，发布由维护者手动执行（便于检查产物与说明）：

**1. 准备版本**

- 更新 `module.prop`：`version`（如 `v1.1.7`）与 `versionCode`（+1）
- 在 `CHANGELOG.md` 顶部添加对应小节（格式：`## v1.1.7`）——该小节将作为**发布说明**

**2. 提交并推送**

```sh
git commit -am "v1.1.7: ..."
git push
```

推送后 [`.github/workflows/build.yml`](.github/workflows/build.yml) 会自动构建，
产物在 Actions 运行页的 **Artifacts** 中下载（保留 90 天）。

**3. 手动创建 Release**

在 GitHub 网页创建 Release（选择新建 tag），或使用 gh CLI：

```sh
# 下载 CI 产物后
gh release create v1.1.7 ./fafu-checkin-v1.1.7.zip \
  --title "v1.1.7：一句话摘要" \
  --notes-file CHANGELOG_SECTION.md    # 内容取自 CHANGELOG 对应小节
```

**4. 同步 update.json**（供管理器检测更新）

```sh
python3 scripts/sync_update_json.py v1.1.7 9 \
  "https://github.com/Bonger34/fafu-checkin/releases/download/v1.1.7/fafu-checkin-v1.1.7.zip"
git commit -am "chore(release): 同步 update.json 至 v1.1.7"
git push
```

> 也可直接用 GitHub 网页手动编辑 `update.json`（仅需改 `version` / `versionCode` / `zipUrl` 三项）。

**CI 职责划分**

| 工作流 | 触发 | 职责 |
|---|---|---|
| [build.yml](.github/workflows/build.yml) | push main / 手动 | 语法检查 + 元数据校验 + 构建 zip（产物供下载） |
| [check.yml](.github/workflows/check.yml) | PR / 手动 | 语法检查 + 元数据校验（快速反馈） |

## ⚠️ 免责声明

本项目仅供个人学习与自动化技术研究使用。请遵守学校相关管理规定，勿用于代签等违规用途。使用产生的一切后果由使用者自行承担。

## 👤 作者

**Bonger**

## 📄 License

[MIT](LICENSE) © 2026 Bonger
