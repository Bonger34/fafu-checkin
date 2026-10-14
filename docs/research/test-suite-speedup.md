# 断言套件提速：一手资料研究

> 研究范围：只查**一手来源**（Microsoft Learn / Microsoft 官方文档、Cygwin 与 Git for Windows 官方站点与源码仓库、BusyBox 官方 FAQ 与源码树、POSIX 规范原文、GNU 官方手册、Docker 官方文档）。
> 二手材料若被提及，会显式标注「二手」，并给出其一手出处。查不到一手来源的结论，明确写「未找到一手来源」。
> 文中所有「推断」都是本文作者基于一手材料的推理，不是任何来源的原话。

---

## 一、问题背景（本仓库事实）

先把被优化的对象固定下来。以下数字都是本次研究期间在本仓库里数出来的（`tests/*.sh`，12 个非 `_` 开头的用例文件 + `tests/harness.sh`）：

| 事实 | 数值 | 取证位置 |
| --- | --- | --- |
| `t_case` 注册的用例 | **156** 个（任务书说 154，实测多 2 个） | `tests/*.sh` 全文 grep `t_case ` |
| 用例文件 | 12 个（`api/config/commands/device/headers/keepalive/layer-order/notify/poll/signin/skeleton/state`） | `tests/` |
| `sh` 文本总行数 | 8825 行 | `tests/*.sh` |
| 命令替换 `$(` / 反引号出现行 | **1771** 行（`signin.sh` 316 最多） | `tests/*.sh` |
| 含 `\|` 的行 | 445 行 | `tests/*.sh` |
| here-doc 起始行 | 194 行 | `tests/*.sh` |
| `grep` 相关断言（`t_has` / `t_has_re` / `t_hasnt` / `t_lines` / `t_before` / `t_before_re`） | **369** 次调用 | `tests/*.sh` |
| `printf` / `grep` / `cat` / `sed` / `tr` 出现行 | 1129 / 265 / 203 / 93 / 93 | `tests/*.sh` |
| `. source` 用法 | 30 处 | `tests/*.sh` |
| mock busybox 包装（`t_bb_wrap` / `BB_OVERRIDE`） | 45 处 | `tests/*.sh` |

关键的执行结构（决定了提速手段的可行边界）：

- `tools/run-tests.sh` 在**同一个 shell 进程**里依次 `.` 加载 13 个文件，逐文件跑完 `T_RUN`，再把 `T_PASS/T_FAIL/T_SKIP` 累加到 `ALL_PASS/ALL_FAIL/ALL_SKIP`。见 [run-tests.sh](tools/run-tests.sh)。
- `T_RUN` 用 here-doc 喂 `while read` 循环（注释里明确写了「用管道会让 `while` 落进子 shell，计数丢失」）。见 [harness.sh](tests/harness.sh)。
- 每个用例的工作目录大多自带名字（`$T_WORK_ROOT/notify-<驱动>`、`$T_WORK_ROOT/poll-<name>`、`$T_WORK_ROOT/signin-<1>`），但存在**固定名**的共享目录：`$T_WORK_ROOT/api`、`/config`、`/device`、`/commands`、`/headers`、`/keepalive`、`/layer-order`、`/skeleton`、`/state`（9 个），以及 `harness.sh` 里 `_t_grep_count` 写死的两个共享临时文件 `$T_WORK_ROOT/.grep.tmp` 与 `$T_WORK_ROOT/.grep.n`。
- `tests/harness.sh` 的注释记录了一个本机硬约束：**本机 busybox（Windows 版）在「嵌套命令替换」下会直接栈溢出崩掉**，所以 `_t_grep_count` 才改成「写文件」而不是 `$( ) + 管道`。这条约束会限制第 4 节的改写空间。
- CI：`ubuntu-latest` + 系统 `sh`，applet 由 KernelSU 随附的 x86_64 busybox 承接（按 commit 钉住），见 [.github/workflows/check.yml](.github/workflows/check.yml)。

**本机实测**（本次研究期间，`tools/busybox/busybox.exe`，20 次平均）：

| 调用 | 实测平均 |
| --- | --- |
| `busybox.exe true` | **26.9 ms / 次** |
| `busybox.exe sh -c :` | **50.5 ms / 次** |

这与任务书给的 28 ms / 46 ms 同一量级。注意：`t_bb_wrap` 生成的替身是「`busybox.exe sh <包装脚本>` → `exec busybox.exe <applet>`」，即**一次 applet 调用 ≈ 2 次进程创建**；`harness.sh` 里 `t_bb_wrap` 的 `case` 分支就是按这个形状生成命令的（`.exe` 分支写成 `busybox.exe sh "$0" "$@"`）。见 [harness.sh](tests/harness.sh)。

---

## 二、问题 1：进程创建成本（Windows vs POSIX）与 Defender 排除项

### 2.1 一手来源说的

1. **Windows 上创建进程只有一个 API：`CreateProcess`。** 它「创建一个新进程及其主线程」，进程在调用者的安全上下文里运行；参数里包含 `lpProcessAttributes`、`lpThreadAttributes`、`bInheritHandles`、`lpEnvironment` 等——也就是说，**进程对象、线程对象、安全属性、环境块、句柄继承表都是这一次调用里要建起来的东西**，而 POSIX 的 `fork()`+`exec()` 分两步、`exec()` 只换进程映像。
   → [CreateProcessA function (processthreadsapi.h) — Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessa)
   → [Processes and Threads — Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/procthread/processes-and-threads)

2. **Windows 没有 POSIX 意义上的 `fork()`，Linux 的 `fork()`+`exec()` 有明确的快路径。** GNU C Library 手册（一手，最权威的 POSIX 进程语义实现文档之一）说明：新进程由 `posix_spawn`/`fork`/`_Fork`/`vfork`/`pidfd_spawn` 创建，`fork` 出的子进程「从 `fork` 返回处继续执行同一程序」，再用 `exec*` 换成新程序映像。
   → [Process Creation Concepts — GNU C Library manual](https://sourceware.org/glibc/manual/latest/html_node/Process-Creation-Concepts.html)
   → [Executing a File — GNU C Library manual](https://sourceware.org/glibc/manual/latest/html_node/Executing-a-File.html)

3. **「Windows 上模拟 fork 更慢」这句话本身有一手来源，而且是 Git for Windows 官方站点说的**（注意它是 MSYS2/Cygwin 阵营的第一方，不是微软的第一方）：
   > 「软件原本为 Linux 写的，在 Windows 上不得不使用**被模拟的（慢得多、且不完美）`fork()`**。如果这个软件在正常工作负载里创建大量进程，那么它在 Windows 上会明显比 Linux 慢。」
   → [Windows-vs-Linux fork()/exec() semantics — Git for Windows 官方](https://gitforwindows.org/windows-vs-linux-fork-and-exec-semantics.html)
   该页同时说明 Windows 版本 fork 的做法是「从同一可执行文件创建进程 → 新进程意识到自己应当是一次 fork → **拷贝父进程整块可访问内存** → 尽力恢复文件描述符/socket/当前工作目录 → 再 `exec()` 把这堆全部丢掉」。
   → 同上链接

4. **BusyBox 官方 FAQ 从「没有 MMU 的系统」角度给出了同一机理的另一种表述**：`fork()` 的实现依赖 MMU；有页表时靠 copy-on-write，「`fork()` 紧跟 `exec()` 只拷几页」；只有最原始的 MMU 时「必须把父进程整块内存拷进新进程（轻松就是几 MB），**而这块内存在 exec 一发生就立刻被释放**」。
   → [BusyBox FAQ — Fork and vfork](https://busybox.net/FAQ.html)
   这条是 BusyBox 讲 NOMMU 的，不是讲 Windows 的；但它解释了「为什么 `fork`+`exec` 的成本主要落在『复制地址空间』上」，与第 3 条的 Windows 机制描述吻合。

### 2.2 我的推断（非一手原话）

- **推断**：Windows 上「大量短命进程」贵的根因是三件事叠加：① `CreateProcess` 一次要建进程对象/线程对象/安全令牌与环境、初始化加载器，没有 Linux 那种「COW 后立刻 exec 丢掉」的省事路径；② 想沿用 POSIX 语义就得额外付「模拟 fork」的钱（第 3 条）；③ 每个新进程映像都要过一遍杀软实时保护。
- **推断**：本仓库本机路径上，②是**双份**的——`t_bb_wrap` 让一次 applet 调用变成 2 次进程创建（一次 busybox ash 跑包装脚本，一次 exec 真 applet），而这条链上没有任何 Cygwin/MSYS 层（busybox.exe 是原生 Windows 程序），所以本机的 40 分钟**不能归因于 MSYS fork 模拟**，主要应归因于「进程数 ×（原生进程创建 + 杀软拦截 + 文件 I/O）」。这条推断的验证方法见第 5 节「现状计数」。

### 2.3 Defender 排除项：官方怎么说、怎么配

一手来源（全部 Microsoft Learn）：

1. **排除项有四种**，且用途不同：
   - **文件与文件夹排除**（也叫路径排除）：排除某个文件，或某个文件夹下的全部内容；
   - **文件扩展名排除**：按扩展名，与位置无关；
   - **进程排除**：排除「某个进程打开的所有文件」；
   - **上下文排除**：把路径排除收窄到特定上下文（例如只在某个进程打开该文件时生效）。
   → [Exclusions in Microsoft Defender Antivirus — Microsoft Learn](https://learn.microsoft.com/en-us/defender-endpoint/microsoft-defender-antivirus-exclusions-overview)

2. **进程排除的范围有个关键限制**：它**只作用于实时保护与监控，不作用于计划扫描与按需扫描**；而路径/扩展名排除对计划扫描、按需扫描、实时保护都生效。原文：「Process exclusions are the exception: they apply only to real-time protection and monitoring, not to scheduled or on-demand scans.」
   → [Configure custom exclusions for Microsoft Defender Antivirus — Microsoft Learn](https://learn.microsoft.com/en-us/defender-endpoint/microsoft-defender-antivirus-exclusions-configure)

3. **官方态度是「先别急着排除」**：官方原文说「每个排除项都是一个防护缺口，所以要**克制使用**」；「只有当某个具体问题（例如性能或应用兼容性问题）需要解决时才定义排除项」，并建议先考虑自定义指示器等替代手段。
   → [Exclusions in Microsoft Defender Antivirus — Microsoft Learn](https://learn.microsoft.com/en-us/defender-endpoint/microsoft-defender-antivirus-exclusions-overview)
   → [Overview of exclusions and indicators in Microsoft Defender for Endpoint — Microsoft Learn](https://learn.microsoft.com/en-us/defender-endpoint/defender-endpoint-exclusions-overview)

4. **排除项也**不是零成本的**：即使配了排除项，Defender 仍会做一次「最小评估」判断排除是否适用（这次评估不含完整内容扫描）；命中排除条件后才跳过扫描。
   → [Exclusions in Microsoft Defender Antivirus — Microsoft Learn](https://learn.microsoft.com/en-us/defender-endpoint/microsoft-defender-antivirus-exclusions-overview)

5. **进程排除的副作用要知情**：官方明确说，进程排除会让**网络防护（network protection）与攻击面减少（ASR）规则**不再检查被排除进程的流量/不再对被排除进程强制规则。
   → [Exclusions in Microsoft Defender Antivirus — Microsoft Learn](https://learn.microsoft.com/en-us/defender-endpoint/microsoft-defender-antivirus-exclusions-overview)

6. **官方给了「先量再改」的工具**：Defender 性能分析器（PowerShell）可以给出「**最影响扫描时间的进程**」「最影响扫描时间的路径/文件/扩展名」「每文件扫描次数」等，用来判断该给谁加排除项：
   ```powershell
   New-MpPerformanceRecording -RecordTo <recording.etl>   # 管理员 PowerShell；复现负载后回车结束
   Get-MpPerformanceReport -Path <recording.etl> -TopFiles 3 -TopScansPerFile 10
   ```
   → [Performance analyzer for Microsoft Defender Antivirus — Microsoft Learn](https://learn.microsoft.com/en-us/defender-endpoint/tune-performance-defender-antivirus)
   若分析器未定位到根因，官方下一步指向 Process Monitor 与 WPRUI：
   → [Troubleshoot Microsoft Defender Antivirus performance issues with Process Monitor — Microsoft Learn](https://learn.microsoft.com/en-us/defender-endpoint/troubleshoot-av-performance-issues-with-procmon)

7. **微软确实有「为特定负载配置杀软排除项」的官方先例**：Hyper-V 主机排除项 KB（KB3105657）明确列出「应把哪些目录、文件、以及创建/打开/更新这些文件的**进程**加进实时扫描排除列表」，例如 `vmms.exe`/`vmwp.exe`/`vmcompute.exe` 与 `*.vhdx`/`*.vmrs` 等。
   → [Recommended antivirus exclusions for Hyper-V hosts — Microsoft Learn](https://learn.microsoft.com/en-us/troubleshoot/windows-server/virtualization/antivirus-exclusions-for-hyper-v-hosts)
   这是「按厂商官方清单为某类负载排除」的模板；**它是一份虚拟化负载清单，不是构建/测试负载清单**。

### 2.4 明确「未找到一手来源」的部分

- **未找到一手来源**：微软没有公布「Defender 实时扫描使单次进程创建增加多少毫秒」的实测数字，也没有「构建/测试负载应排除哪些进程」的官方清单。本次检索只找到 Defender 的通用排除项配置文档、性能分析器文档、以及 Hyper-V 这一个特定负载的排除清单。
- **未找到一手来源**：`Windows Internals`（Russinovich 等，Microsoft Press）第 5 章「Processes, Threads, and Jobs」有一手级的 `CreateProcess` 内部步骤（章节 PDF 挂在官方 Sysinternals 站点 `https://live.sysinternals.com/files/WindowsInternals-Ch05.pdf`），但该 URL 在本次研究中被服务器的 MIME 检查挡下（返回 `406 Client browser does not accept the MIME type`），**未能读到正文**，故本文不引用它的具体条目。该书的章节 PDF 本身是官方托管的一手材料，读者可自行取用。
- **本地可执行要点**（命令来自上面的一手文档；**本次研究未在本机执行**，因为 `Get-MpPreference` / `Get-MpComputerStatus` 在当前会话里被拒绝访问，见下文「本地取证限制」）：

  ```powershell
  # 加排除项（管理员 PowerShell）
  Add-MpPreference -ExclusionPath  'D:\Bonger\Desktop\fafu-checkin\tools\busybox'
  Add-MpPreference -ExclusionPath  'D:\Bonger\Desktop\fafu-checkin\tests\.work'
  Add-MpPreference -ExclusionProcess 'busybox.exe'
  # 看当前生效的排除项
  Get-MpPreference | Select-Object ExclusionPath, ExclusionProcess, ExclusionExtension
  ```
  → 配置方法出处：[Configure custom exclusions for Microsoft Defender Antivirus — Microsoft Learn](https://learn.microsoft.com/en-us/defender-endpoint/microsoft-defender-antivirus-exclusions-configure)
  → `Get-MpPreference` 出处：[Get-MpPreference — Microsoft Learn](https://learn.microsoft.com/en-us/powershell/module/defender/get-mppreference)
  → 组织级管理建议（Intune/Configuration Manager 会覆盖本地 GPO/PowerShell 设置）：同上配置文档。

- **本地取证限制**：本次会话尝试 `Get-MpPreference` / `Get-MpComputerStatus` 查询本机实时保护状态，命令无输出（被拒/不可用）；`Get-CimInstance Win32_OperatingSystem` 返回「拒绝访问」。因此**本机 Defender 是否开启实时保护、是否已有排除项，本文无法确认**，需要用户在有权限的终端自行核对上面三条命令。

---

## 三、问题 2：MSYS2 / Cygwin 的 fork 代价，以及 Git 自带 dash 能不能当高频 spawn 的测试 shell

### 3.1 一手来源说的

1. **Cygwin 官方 FAQ 第 5.6 条「How is fork() implemented?」的全文**（本文从 Cygwin 官方源码仓库的 FAQ 源文件读到，站点 HTML 版因页面过长无法完整抓取）：

   > 「Cygwin 的 `fork()` 本质上像一个**非 copy-on-write 版本的 fork**（就像老 Unix 那样）。**正因如此它会有点慢。** 多数情况下，能不用就改用 `spawn` 系列调用。」

   实现步骤（官方原文的要点转述）：父进程在 Cygwin 进程表里给子进程占位 → 用 Windows `CreateProcess` **挂起**创建子进程（用父进程自己被调用时的同一路径）→ 父进程 `setjmp` 保存上下文并把指针放进共享内存区 → **父进程把自己的 `.data`/`.bss` 拷贝进挂起子进程的地址空间** → 启动子进程 → 父子用互斥量对齐到安全点 → **父进程再把自己的栈与堆拷贝进子进程** → 子进程继续从 `fork` 返回。

   → 一手来源：[newlib-cygwin `winsup/doc/faq-api.xml`（Cygwin 官方源码仓库）](https://raw.githubusercontent.com/cygwin/cygwin/master/winsup/doc/faq-api.xml)
   → 同一内容的站点页面（页面超长，本次未能取到该节点）：[Cygwin FAQ §5.6](https://cygwin.com/faq.html#faq.api.fork)

   这条直接回答了「为什么 Cygwin/msys2 的 fork 比原生 Linux 慢」：**Linux 靠 COW 只拷改动过的页，Cygwin 是把 `.data`/`.bss`/栈/堆整块拷过去，而这份拷贝在 `exec` 之后立刻作废。**

2. **Git for Windows 官方对「MSYS 比 MINGW 慢」的归因**：官方文章写「Windows 上没有 `fork()`；`fork()` 在 Windows 上由 **MSYS 模拟**，而 **MINGW 里没有 `fork()`**。这正是 **MSYS 比 MINGW 慢得多**的部分原因」，并给出结论「创建大量进程的软件在 Windows 上会明显比 Linux 慢」。
   → [Windows-vs-Linux fork()/exec() semantics — Git for Windows 官方](https://gitforwindows.org/windows-vs-linux-fork-and-exec-semantics.html)

3. **Git for Windows 是构建在 MSYS2 之上的**（官方 FAQ 的许可证段落自述「本包包含 Bash、zlib、curl、tcl/tk、perl、**MSYS2** ……」），且其 FAQ 明确说「Windows 7/8/XP/2003 支持被移除，这个限制由 Git 对 **MSYS2** 的使用继承而来，而 MSYS2 又继承自 **Cygwin**」。
   → [Git for Windows FAQ](https://gitforwindows.org/faq.html)

### 3.2 明确「未找到一手来源」的部分

- **未找到一手来源**：Git for Windows 官方没有一篇文档专门解释「为什么安装包里自带 `usr/bin/dash.exe`、它是不是给脚本当 `sh` 用的」。可查到的一手材料只有上一条「Git for Windows = MSYS2 + Cygwin 血统」的间接说明。需要强调的是：**Git for Windows 的 `sh.exe` 是 `bash`（MSYS2 血统），而 `D:\git\usr\bin\dash.exe` 属于同一套 MSYS2 runtime**——所以第 1 条 Cygwin 官方 FAQ 对「fork 要整块拷地址空间」的描述，按同源代码逻辑同样适用于它。（**推断**：同源，故同样适用；未找到 Git for Windows 或 MSYS2 官方对 dash 单独的性能声明。）
- **未找到一手来源**：MSYS2 官网（msys2.org）没有「fork 模拟开销」的独立性能文档；相关一手材料集中在 Cygwin FAQ 与 newlib-cygwin 源码树。

### 3.3 与本机直接相关的一条事实

任务书提到本机 `D:\git\usr\bin\dash.exe` 启动即报 `couldn't create signal pipe, Win32 error 5`。这与第 1 条描述的实现机制**方向一致（**推断**）**：MSYS2/Cygwin 程序启动时就要建立信号机制所需的管道等 Windows 内核对象，一旦创建失败就立刻退出。**结论（推断）**：本机这条路径不是「慢」，而是**根本不可用**，所以它不能作为提速方案的备选。

---

## 四、问题 3：BusyBox 启动与 applet 分派；POSIX sh 里哪些构造真的 fork

### 4.1 一手来源说的：applet 分派

1. **改名（或符号链接/硬链接）即分派**。BusyBox 官方 FAQ：这个预编译二进制是一个「multiplexer（多路复用器）」，可以通过命令行 `./busybox ls -l` 调用，也可以把可执行文件**改名成它支持的某个命令名**，它就会自动扮演那个命令；官方还给了批量建符号链接的示例：
   ```sh
   mkdir bbdir
   for i in $(busybox --list); do ln -s busybox bbdir/$i; done
   PATH=$(pwd)/bbdir bbdir/sh      # 让 $PATH 只暴露 busybox 内建命令
   ```
   → [BusyBox FAQ — Installing Busybox](https://busybox.net/FAQ.html)
   与本仓库的关系：`.github/workflows/check.yml` 里那句注释「**文件名必须正好是 `busybox`**：它按 argv[0] 分派 applet」正是这条官方行为的直接后果。

2. **`FEATURE_SH_STANDALONE` + `FEATURE_SH_NOFORK` 才是「shell 里不 fork」的开关**。BusyBox 源码树一手文档 `docs/nofork_noexec.txt`；
   → [busybox/docs/nofork_noexec.txt（上游镜像源码树）](https://raw.githubusercontent.com/mirror/busybox/master/docs/nofork_noexec.txt)
   要点（原文转述）：
   - Unix shell 传统上会把部分命令在内部实现，因为「如果每个 `echo blah` 都要 fork 并 exec `/bin/echo`，那会慢死了」；BusyBox 的独特之处是它本身已经是这些命令的重新实现集合，于是可以把同样的省法用在 busybox 的 shell 上。
   - **NOEXEC**：子进程 fork 后直接在当前进程里调 `<applet>_main()`，省掉 exec 的一半开销；**NOMMU 构建下 NOEXEC 被禁用**。
   - **NOFORK**：连 fork 都不做，直接调 `<applet>_main(argc,argv)` 然后继续；限制最严（不许长时间运行、不许 `exit()`/`exec()`、不许依赖共享全局数据处于初值等）。
   - **`FEATURE_SH_STANDALONE`**：shell 发现命令名匹配某个 applet 时，会尝试 `exec /proc/self/exe`；**对 NOEXEC applet 做 NOEXEC 技巧**。
   - **`FEATURE_SH_NOFORK`**：shell 对 NOFORK applet 做 NOFORK 技巧。
   - **原文关键一句**：「**NB: shell builtins use these tricks regardless of `FEATURE_SH_STANDALONE`, `FEATURE_PREFER_APPLETS` or `FEATURE_SH_NOFORK`. In effect, builtins are "always NOFORK".**」
     → 即：**shell 内建命令（builtin）无论编译选项如何都不 fork**；而 `grep`/`cat`/`sed` 这类 applet 想省掉 fork，**必须**依赖上面这些编译选项与 applet 自身的 NOFORK/NOEXEC 标记。

### 4.2 一手来源说的：POSIX sh 里哪些构造会创建子 shell / 进程

1. **命令替换**：POSIX 规定 shell「**在一个子 shell 环境中**执行 commands」。
   → [POSIX.1-2024, Shell Command Language §2.6.3 Command Substitution](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html#tag_19_06_03)

2. **`( )` 分组**：POSIX 规定「**在子 shell 环境中**执行 compound-list；变量赋值与内建命令对环境的影响**不保留**」。
   → [POSIX.1-2024, Shell Command Language §2.9.4 Compound Commands — Grouping Commands](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html#tag_19_09_04)

3. **只有重定向、没有命令名**：POSIX 说「若没有命令名，**任何重定向都应在子 shell 环境中执行**」。
   → [POSIX.1-2024, Shell Command Language §2.9.1 Simple Commands](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html#tag_19_09_01)

4. **规范本身对「是否非要另开一个 OS 进程」留了余地**：POSIX 在「Reasonings」里说明过，规范只要求「子 shell 环境」在语义上隔离（`cd`、变量赋值、`trap` 等不外泄），**并没有**规定必须要 fork 一个新进程。本次抓取到的原文旁证是 2.9.1 里那句「it is unspecified whether this subshell environment is the same one as that used for a command substitution within the command」——规范反复用「子 shell **环境**」而不是「子 shell **进程**」。
   → [POSIX.1-2024, Shell Command Language §2.9.1](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html#tag_19_09_01)
   （**推断**：这就是为什么 dash 可以宣称某些写法「不另 fork 一个 shell」而依然符合 POSIX——见 4.3。）

5. **POSIX 对「并行执行」没有定义**，`xargs` 页面只有一句鼓励：实现若要提供并行执行，被鼓励**新增一个选项**来开启。
   → [POSIX.1-2017, xargs](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/xargs.html)
   含义：`xargs -P` 是 **GNU findutils 的扩展**，不是 POSIX；写进本仓库脚本时必须视为「GNU/CI 有、本机 busybox 未必有」。

### 4.3 一手来源说的：dash 的具体行为（可用来判断哪些写法贵）

dash 的官方手册页（Linux man-pages 收录、`dash.1` 原始来源即 Debian 的 dash 包）：

- **内建命令不 spawn 进程**：「Shell builtins are executed internally to the shell, without spawning a new process.」
  → [dash(1) — man7.org](https://man7.org/linux/man-pages/man1/dash.1.html)
- **`{ }` 不 fork、`( )` 才 fork**：「The first of these executes the commands in a subshell. …… The second form **does not fork another shell** so is slightly more efficient.」
  → 同上
- **`( )` 会丢内建效果**：「Builtin commands grouped into a `(list)` will not affect the current shell.」
  → 同上
- **管道里每段都是子进程**：「unlike some other shells, **each process in the pipeline is a child of the invoking shell**（除非它是个 shell builtin，那种情况它在当前 shell 里执行——但它对环境的影响被抹掉）」
  → 同上
- **无 shebang 的脚本会被当前 shell 在子 shell 里解释**：「if the program is not a normal executable file (i.e., if it does not begin with the "magic number" …) the shell will interpret the program **in a subshell**」——这正是本仓库 `tests/mock/busybox`、`t_curl_stub` 生成的 `#!/bin/sh` 替身的执行路径（**推断**：它们有 shebang，所以走的是「当作程序 exec」而不是这条；但脚本一被 exec，解释器本身又是一次进程创建）。
  → 同上
- **`local` / `return` / `break` / `continue` 都是内建**（故 `harness.sh` 里全面使用 `local` 是零进程成本的）。
  → 同上
- **一批命令「可能为了效率而内建」**：dash 手册页在 Builtins 一节开头写「In addition to these, there are several other commands that **may be builtin for efficiency** (e.g. `printf`, `echo`, `test`, etc).」
  → 同上
  **注意**：这是「可能」，不是保证。**推断**：本仓库断言里大量使用的 `printf` 在 dash/ash 下通常是内建，但**不能**据此假设 `grep`/`cat`/`sed`/`cut` 不 fork。

### 4.4 与本机（Windows busybox）对照的可执行要点

- **要判断本机那份 `tools/busybox/busybox.exe` 到底编了哪些省 fork 的开关**，用 BusyBox 自己的开关查最直接（本文**未**执行，留给提速方案去验证；`--help` 输出会显示该 applet 是否内建）：
  ```sh
  tools/busybox/busybox.exe --list            # 全部 applet 名
  tools/busybox/busybox.exe sh -c 'command -v grep; command -v cat; command -v printf'
  ```
  判据来自 4.1 第 2 条：`FEATURE_SH_STANDALONE` 开着时，shell 在 PATH 里「找到」的 applet 可能只是它自己（`command -v` 只回一个名字，PATH 里并无此文件）——**本仓库 `tools/lib.sh` 的注释已经踩过这个坑**并据此规定了「必须是真实存在的文件」（见 [tools/lib.sh](tools/lib.sh) 的 `find_busybox`）。
- **当前用例里的「贵」构造清单**（**推断**，基于 4.2/4.3 的规则 + 本仓库实测计数）：
  | 构造 | 每次成本 | 本仓库用量 |
  | --- | --- | --- |
  | `$(外部命令)` | 1 个子 shell 进程 + 1 个外部进程 | 1771 行含 `$(` |
  | `cmd \| cmd` | 每段 1 个进程 | 445 行含 `\|` |
  | `( )` 分组 | 1 个子 shell 进程 | 少量 |
  | 外部命令（`grep`/`cat`/`sed`/`cut`…） | 1 个进程（若被 applet 化且开了 NOEXEC/NOFORK 可省一半或全部） | `grep` 265 行、`cat` 203 行、`sed` 93 行、`tr` 93 行、`cut` 40 行 |
  | 内建命令（`printf`/`[`/`case`/`local`/`read`） | **0 个进程** | `printf` 1129 行 |
  | `_t_grep_count`（一次断言） | `grep`→文件、`grep -c`→文件、`cat`→stdout：**3 个进程** | 被 369 次断言调用 |

---

## 五、问题 4：减少 shell 测试 subprocess 数量的公认手法（含一手依据）

### 5.1 有明确一手依据的手法

1. **用参数展开代替 `sed`/`cut`/`basename`/`dirname` 去头去尾。**
   POSIX 定义 `${parameter#word}`/`##`/`%`/`%%` 四种子串处理，以及 `${#parameter}` 取长度，全部是**参数展开**，不涉及命令替换。
   → [POSIX.1-2024 §2.6.2 Parameter Expansion](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html#tag_19_06_02)
   本仓库已有用法：`harness.sh` 里 `pat="${w#^}"`、`"${f##*/}"`；`mock/busybox` 里 `_bb_applet` 的分派。
   **推断**：把 `x=$(echo "$y" | sed 's/^ *//')` 改成 `x="${y#"${y%%[! ]*}"}"` 之类的写法，可把「子 shell + sed」两个进程降到 0。缺点是可读性下降，建议只对热点断言做。

2. **用内建 `read` 循环 + here-doc 代替 `cat file | while read`。**
   here-doc 是 POSIX 的重定向（`io_here`），`read` 是内建；两者都不需要额外进程。
   → [POSIX.1-2024 §2.7.4 Here-Document](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html#tag_19_07_04)
   → [POSIX.1-2024 §2.14 Special Built-In Utilities / read](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html#tag_19_14)
   本仓库已有正确先例，且注释写明了理由：`T_RUN` 用 here-doc 而不是管道，正是为了「别让 `while` 落进子 shell，计数丢失」（**推断**：这同时省掉了一整个管道+子 shell 的进程开销，属于「正确性顺手带来性能」的例子）。

3. **用 `.`（dot）source 代替启动子 shell 跑脚本。**
   `.` 是 POSIX 特殊内建：「shell 应在一个**当前执行环境**中执行该文件中的命令」——不新建子 shell 进程。
   → [POSIX.1-2024 §2.14 Special Built-In Utilities — dot](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html#tag_19_14)
   **推断**：本仓库 `tools/run-tests.sh` 已经用 `.` 加载 `tests/harness.sh` 与 13 个用例文件，这条已经用尽；但用例内部 `sh "$script"` 形式的驱动脚本调用仍有压缩空间（需要逐用例分析，风险较高）。

4. **用 `case` 做字符串匹配/分类，代替 `grep`/`sed`/`expr`。**
   POSIX 的 `case` 是复合命令，模式匹配在 shell 内完成，不 spawn。
   → [POSIX.1-2024 §2.9.4 Compound Commands — Case Conditional Construct](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html#tag_19_09_04)
   本仓库已有用法：`T_RUN` 里用 `case "$c" in "$pat"*)`；`tools/lib.sh` 的 `find_busybox` 用 `for c in ...` 展开。

5. **用 `{ ...; }` 代替 `( ... )` 做分组重定向。**
   dash 手册页原话：「The second form **does not fork another shell** so is slightly more efficient.」
   → [dash(1) — man7.org](https://man7.org/linux/man-pages/man1/dash.1.html)
   **注意陷阱**：`( )` 的语义是「内建效果不外泄」，换成 `{ }` 会改变语义——只有在用例本来就**不依赖**子 shell 隔离时才可换。
   **推断**：本仓库 `harness.sh` 里 `_t_grep_count` 已经是「写文件」而非「管道」，属于同一思路（写文件避免子 shell 丢计数），但代价是 3 次进程。

6. **测试内建是否是内建，而不是猜。**
   dash 手册页说 `printf`/`echo`/`test` 等「**可能**为效率而内建」。
   → [dash(1) — man7.org](https://man7.org/linux/man-pages/man1/dash.1.html)
   BusyBox 文档说「builtins 永远等价于 NOFORK」。
   → [busybox/docs/nofork_noexec.txt](https://raw.githubusercontent.com/mirror/busybox/master/docs/nofork_noexec.txt)
   **推断**：这是「把 `grep`-based 断言改写为 `case`/参数展开-based 断言」能生效的**前提条件**，但收益成立与否必须在本机那份 busybox 上实测（见 4.4 的两条命令）。

### 5.2 明确「未找到一手来源」的部分

- **未找到一手来源**：ShellCheck 官方文档（shellcheck.net/wiki）是**逐条错误码**的说明，本次检索没有找到官方对「某些写法更省进程/更快」的性能条目。ShellCheck 定位是正确性与可移植性静态检查，**不承诺**性能建议。
- **未找到一手来源**：dash 或 busybox ash 官方**没有**「性能优化手册」性质的文档；dash 的性能相关陈述只有手册页里上面引用到的三处（builtin 不 spawn、`{ }` 不 fork、管道每段是子进程），busybox ash 的一手材料是 `docs/nofork_noexec.txt` 与源码 `shell/ash.c` 里的 `//applet:` 标记。
- **未找到一手来源**：POSIX 规范**没有**给出「哪种写法更快」的性能指南——它只规定语义。任何「POSIX 推荐的提速写法」说法都属于二手误读。
- **本仓库特有的负面一手证据**（不是外部来源，是仓库自己的记录）：`tests/harness.sh` 注释写明「**不走 `$( )` + 管道：本机 busybox（Windows 版）在这种嵌套命令替换下会直接栈溢出崩掉**」。**推断**：这意味着第 5.1 节第 1、2 条改写**在本机要避开深嵌套**，改写后必须在本机逐条验证，不能只看 CI 绿。

---

## 六、问题 5：测试并行化，以及 Windows 上的原生 Linux 环境

### 6.1 一手来源说的：并行执行的官方注意事项

1. **`make -j`：并行时输出会交错，官方提供 `--output-sync` 解决。** GNU make 手册明确写「并行跑多个 recipe 时，各 recipe 的输出可能在**同一行上交错**，这会让输出非常难读」，并用 `-O`/`--output-sync`（`none`/`line`/`target`/`recurse` 四档）把输出按行/按目标/按递归调用分组。官方还特别声明：「**Regardless of the mode chosen, the total build time will be the same.** The only difference is in how the output appears.」
   → [Parallel Output (GNU make)](https://www.gnu.org/software/make/manual/html_node/Parallel-Output.html)
   另：`-j` 不给数字表示「不限 job 数」；`-l`/`--max-load` 可按负载均值限制并发数。
   → [Parallel Execution (GNU make)](https://www.gnu.org/software/make/manual/html_node/Parallel.html)
   **对本仓库的含义（推断）**：断言输出是「`[PASS] 说明`」逐行累积的，并行后必然交错；若采用并行，需要像 `-O target` 那样**把每个用例文件的输出收集后再整块打印**，否则日志不可读、失败定位困难。

2. **GNU parallel 官方给出的「xargs 并行」清单**（含 `-P` 的具体缺陷）：
   - `xargs` 能并行跑指定数量的 job，但**不支持「按 CPU 核数」自动并行**；
   - **不支持输出分组**，「因此输出可能连在一起，例如半行来自一个进程、后半行来自另一个进程」；
   - **不支持保持输出顺序**；
   - `-I` 替换串会强制「一次只用一个参数」；
   - 引号处理与 composed command/重定向需要 `bash -c`。
   → [DIFFERENCES BETWEEN xargs AND GNU Parallel（GNU parallel 官方文档）](https://www.gnu.org/software/parallel/parallel_alternatives.html)
   → [GNU parallel 手册](https://www.gnu.org/software/parallel/man.html)

3. **POSIX 没有定义并行**（见 5.2 第 1 条的引用）：`xargs -P` 是 GNU 扩展。
   → [POSIX.1-2017, xargs](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/xargs.html)
   **对本仓库的含义（推断）**：本机 busybox 的 `xargs` 是 BusyBox applet，**必须实测它是否支持 `-P`**；CI 的 Ubuntu 上是 GNU findutils，支持。任何并行方案都要写成「两条路径都成立」或者只在有 GNU xargs 时启用。

### 6.2 并行化在「每个用例写自己的 work 目录 + 有共享计数器/共享临时文件」场景下的注意事项

GNU make 的 `Parallel Output` 与 GNU parallel 的 xargs 差异清单覆盖了**输出交错**，但没有覆盖「共享文件」这一类。关于共享状态，本次研究**未找到**任何一手来源提供 shell 测试框架的通用建议。以下是**推断**，但每条都标了本仓库里对应的具体代码位置，便于直接核对：

- **推断（共享临时文件必须唯一化）**：`harness.sh` 的 `_t_grep_count` 把中间结果写死成 `$T_WORK_ROOT/.grep.tmp` 与 `$T_WORK_ROOT/.grep.n`。这是**全仓库唯一的跨用例共享临时文件**，并行后必然互相覆盖。它被 369 处断言间接调用（`t_has`/`t_has_re`/`t_hasnt`）。要并行，**必须**先把它改成按 PID 或按调用者唯一的文件名（例如 `$T_WORK_ROOT/.grep.$$.tmp`）。取证位置：[harness.sh](tests/harness.sh)。
  > **已解决（本次改动）**：`_t_grep_count` 改为内建读文件、不再落任何中间文件，这两个共享临时文件已从代码与文档中消失（改法是内建 `read` + `case`，字面量路径 0 进程；正则路径一次 `grep -cE`）。并行化现在只需要处理计数汇总与固定名工作目录两项。
- **推断（共享计数器必须改成「子进程各报各的、父进程汇总」）**：`T_PASS/T_FAIL/T_SKIP` 是 shell 变量，只存在于当前 shell 进程；并行跑必须让每个用例文件在自己的 shell 里输出自己的计数，由父进程收集合并——这正好和 `run-tests.sh` 现在「同一进程内累加 `ALL_PASS`」的结构相反。取证位置：[run-tests.sh](tools/run-tests.sh)。
- **推断（固定名工作目录要改名或加 PID 后缀）**：`api/config/device/commands/headers/keepalive/layer-order/skeleton/state` 这 9 个用例文件用的是固定目录名（如 `$T_WORK_ROOT/api`）。同一个文件内的用例天然串行，所以只要**并行粒度 = 用例文件**就没有冲突；一旦并行粒度细到「用例」，这 9 个就必须改成带 PID/序号的目录名。
- **推断（`t_bb_wrap` 的生成目录同理）**：`t_bb_wrap` 默认落点是 `$T_WORK_ROOT/bin/bb`，被 45 处使用。按文件并行时，每个文件会各自覆盖这个路径——需要确认同一时刻只有一个文件在用它，或改成按文件/按 PID 的唯一落点。取证位置：[harness.sh](tests/harness.sh) 的 `t_bb_wrap`。
- **推断（并行度不是越大越好）**：GNU make 手册本身就提醒「系统负载高时应当跑更少 job」，并给了 `-l/--max-load`。
  → [Parallel Execution (GNU make)](https://www.gnu.org/software/make/manual/html_node/Parallel.html)
  本机每个用例都要反复创建 `busybox.exe` 进程，CPU 未必是瓶颈，**进程创建与文件 I/O（含杀软拦截）才是**。故并行度的合理起点应通过实测确定，而不是直接取 CPU 核数。

### 6.3 官方支持的「Windows 上的原生 Linux 环境」

1. **WSL2 官方安装（推荐路径）**：需要 **Windows 10 版本 2004 及以上（Build 19041+）或 Windows 11**；操作是「以**管理员**身份打开 PowerShell，运行 `wsl --install`，然后**重启机器**」；该命令会启用所需功能并安装 Ubuntu 发行版；「首次启动新发行版时要等文件解压，之后每次启动一般不到一秒」。若该命令只打印帮助文本，说明 WSL 已装过，改用 `wsl --list --online`。
   → [Install WSL — Microsoft Learn](https://learn.microsoft.com/en-us/windows/wsl/install)
2. **WSL2 手动安装（老版本/Server Core）**：需管理员 PowerShell 执行 `dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart`；WSL2 对 x64 要求「Version 1903 或更高，Build 18362.1049 或更高」，并需要**重启**；低于 18362 不支持 WSL2。文档同时说明还需启用 Virtual Machine Platform 功能。
   → [Manual installation steps for older versions of WSL — Microsoft Learn](https://learn.microsoft.com/en-us/windows/wsl/install-manual)
3. **WSL2 的官方定位**：WSL2 使用「**托管 VM 里的真实 Linux 内核**」，提供完整系统调用兼容性；官方给出的性能对比是「文件密集型操作（`git clone`、`npm install`、`apt update/upgrade` 等）在 WSL2 上明显更快」，并给出「解压 tar 包最多快 20 倍、`git clone` 约 2–5 倍」的官方数字。
   → [Comparing WSL Versions — Microsoft Learn](https://learn.microsoft.com/en-us/windows/wsl/compare-versions)
   **推断**：对本仓库的断言套件而言，WSL2 的意义不是「文件更快」，而是**进程创建语义回到原生 Linux**（`fork`+`exec` 有 COW 快路径），从而把第 2、3 节里那些 Windows 特有的开销整体去掉；代价是装上 WSL2 需要管理员权限 + 重启。
4. **Docker Desktop for Windows**：官方文档是 [Install Docker Desktop on Windows — Docker Docs](https://docs.docker.com/desktop/setup/install/windows-install/)。
   **本次研究的限制**：docs.docker.com 的 HTML 页面主体是 JS 渲染，`web_fetch` 拿到的是脚本而非正文；本机 PowerShell/curl 因安全上下文问题无法建立 TLS 连接（`SEC_E_NO_CREDENTIALS`），因此**未能读到该页的「System requirements」正文**。可确认的只有：该页存在、它是 Docker 官方安装文档；其 Windows 版要求 WSL2 后端或 Hyper-V 后端、安装需管理员权限。
   → **需要读者自行在该页核对**「WSL 2 backend / Hyper-V backend 的具体前置条件（虚拟化、内存、磁盘）」后再落地。
   **推断**：Docker Desktop 对本仓库的价值低于 WSL2（多一层容器，测试还要挂载仓库；且 CI 是 `ubuntu-latest`，与容器行为一致性并不比 WSL2 更高）。建议把 Docker 作为「需要隔离环境跑 CI 复现」的备选，而不是本机提速首选。

---

## 七、可执行结论清单

每条一行：结论 → 来源 → 本机适用性。**「本机」= Windows 宿主机；「CI」= ubuntu-latest**。

| # | 结论 | 来源 | 适用性 |
| --- | --- | --- | --- |
| 1 | 本机的可用 POSIX shell 只有 `tools/busybox/busybox.exe`；实测 `busybox.exe true` = 26.9 ms、`busybox.exe sh -c :` = 50.5 ms（20 次平均）。这是**一切提速方案的基线**，任何改动都应以它为单位核算收益。 | 本次实测（数值）；机制见 [BusyBox FAQ](https://busybox.net/FAQ.html) | 本机 |
| 2 | 一次 applet 调用在 mock 链路上 ≈ **2 次进程创建**（`busybox.exe sh <包装脚本>` → `exec busybox.exe <applet>`），因为 `t_bb_wrap` 对 `*.exe` 生成的是 `busybox.exe sh "$0" "$@"`。**优先改这条**比改断言写法收益更大。 | [harness.sh](tests/harness.sh)（仓库代码）；[Git for Windows：MSYS 的 fork 更慢](https://gitforwindows.org/windows-vs-linux-fork-and-exec-semantics.html)（旁证「额外一层进程很贵」） | 本机（CI 上是 `busybox "$0"`，只有 1 次，见同一段 case 分支） |
| 3 | Windows 创建进程只有一个 `CreateProcess` 调用，一次要建立进程对象、主线程、安全属性、环境与句柄继承；Linux 的 `fork`+`exec` 有 COW 快路径。**故「大量短命进程」在 Windows 上更贵**——这句话本身有 Git for Windows 官方原话背书。 | [CreateProcessA](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessa)；[glibc Process Creation Concepts](https://sourceware.org/glibc/manual/latest/html_node/Process-Creation-Concepts.html)；[Git for Windows](https://gitforwindows.org/windows-vs-linux-fork-and-exec-semantics.html) | 两者（本机受影响，CI 不受） |
| 4 | 把 `tools/busybox/busybox.exe` 所在目录与 `tests/.work` 加入 Defender **路径排除**、把 `busybox.exe` 加入**进程排除**：`Add-MpPreference -ExclusionPath ...` / `-ExclusionProcess busybox.exe`；核对用 `Get-MpPreference`。**进程排除只对实时保护生效，不影响计划/按需扫描**。 | [Configure custom exclusions](https://learn.microsoft.com/en-us/defender-endpoint/microsoft-defender-antivirus-exclusions-configure)；[Get-MpPreference](https://learn.microsoft.com/en-us/powershell/module/defender/get-mppreference) | 本机 |
| 5 | 加排除项前先**量**：用官方性能分析器看「最影响扫描时间的进程/路径/扩展名」再决定排除谁；`New-MpPerformanceRecording` + `Get-MpPerformanceReport`，需管理员 PowerShell。 | [Performance analyzer for Microsoft Defender Antivirus](https://learn.microsoft.com/en-us/defender-endpoint/tune-performance-defender-antivirus) | 本机 |
| 6 | 排除项是**防护缺口**，官方要求克制使用；进程排除还会让网络防护与 ASR 规则不再作用于该进程。团队内要显式记录这条取舍。 | [Exclusions in Microsoft Defender Antivirus](https://learn.microsoft.com/en-us/defender-endpoint/microsoft-defender-antivirus-exclusions-overview)；[Overview of exclusions and indicators](https://learn.microsoft.com/en-us/defender-endpoint/defender-endpoint-exclusions-overview) | 本机 |
| 7 | 即使配了排除，Defender 仍会做一次「最小评估」；不要把「加了排除」当成绝对零开销。 | [Exclusions in Microsoft Defender Antivirus](https://learn.microsoft.com/en-us/defender-endpoint/microsoft-defender-antivirus-exclusions-overview) | 本机 |
| 8 | Cygwin 的 `fork()` 是**非 COW** 实现：父进程把 `.data`/`.bss` 拷进挂起子进程、再拷栈与堆，官方原话是「**正因如此它会有点慢**，多数情况应改用 `spawn` 系列」。**故 Git 自带的 MSYS2 `dash.exe` 不适合当高频 spawn 的测试 shell**，本机它更是直接启动失败。 | [newlib-cygwin faq-api.xml §5.6（官方源码仓库）](https://raw.githubusercontent.com/cygwin/cygwin/master/winsup/doc/faq-api.xml)；[Cygwin FAQ §5.6](https://cygwin.com/faq.html#faq.api.fork) | 本机（本机不可用）；CI 无关 |
| 9 | BusyBox 按 **argv[0]** 或 `busybox <applet>` 分派 applet；所以复制/改名 busybox 会破坏分派（CI 注释里已经写明这条）。批量建链接的官方示例在 FAQ 里。 | [BusyBox FAQ — Installing Busybox](https://busybox.net/FAQ.html) | 两者（CI 里 `TEST_BUSYBOX=/usr/local/bin/busybox` 必须保持原名） |
| 10 | **shell 内建命令永远不 fork**（BusyBox 官方原文：「builtins are "always NOFORK"」）；但 `grep`/`cat`/`sed` 这类 **applet 想省 fork，必须**编译时开了 `FEATURE_SH_STANDALONE`（NOEXEC）或 `FEATURE_SH_NOFORK`（NOFORK）。→ **提速前必须先确认本机那份 busybox 的编译开关**，不能假定。 | [busybox/docs/nofork_noexec.txt](https://raw.githubusercontent.com/mirror/busybox/master/docs/nofork_noexec.txt) | 本机（CI 那份是 KernelSU 构建，开关同样未知，需各自实测） |
| 11 | POSIX 规定「命令替换」在**子 shell 环境**里执行 → 每个 `$( )` 至少 1 个子 shell 进程。本仓库有 1771 行含 `$(`。 | [POSIX §2.6.3 Command Substitution](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html#tag_19_06_03) | 两者 |
| 12 | POSIX 规定 `( )` 分组在子 shell 环境中执行且内建效果不外泄；而 dash 手册页明确说 `{ }`「**不 fork 另一个 shell**，所以略高效」→ 不依赖隔离语义时可换。 | [POSIX §2.9.4](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html#tag_19_09_04)；[dash(1)](https://man7.org/linux/man-pages/man1/dash.1.html) | 两者 |
| 13 | dash 手册页：「管道里**每段都是调用 shell 的子进程**」（内建除外）。本仓库有 445 行含 `\|`。 | [dash(1)](https://man7.org/linux/man-pages/man1/dash.1.html) | 两者 |
| 14 | 只有重定向、没有命令名的简单命令，POSIX 规定重定向「应在**子 shell 环境**中执行」——这条是「`[ -s "$f" ]` 这类判断本身廉价、但纯重定向语句不廉价」的规范依据。 | [POSIX §2.9.1 Simple Commands](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html#tag_19_09_01) | 两者 |
| 15 | 用 `${var#pat}/##/%/%%` 做去头去尾、用 `case` 做匹配、用内建 `read` + here-doc 做逐行处理、用 `.` source 代替起子 shell —— 这四类改写**都不产生额外进程**，各有 POSIX 条文依据。 | [POSIX §2.6.2 参数展开](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html#tag_19_06_02)、[§2.9.4 case](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html#tag_19_09_04)、[§2.7.4 here-doc](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html#tag_19_07_04)、[§2.14 dot](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html#tag_19_14) | 两者 |
| 16 | **改写有本机专属风险**：仓库已记录「本机 busybox（Windows 版）在嵌套 `$( )` + 管道下会栈溢出崩掉」。所以第 15 条的改写要**避开深嵌套**，并逐条在本机复验（不能只看 CI）。 | [harness.sh](tests/harness.sh) 的 `_t_grep_count` 注释 | 本机 |
| 17 | `harness.sh` 的 `_t_grep_count` 一次断言 = **3 个进程**（`grep`→文件、`grep -c`→文件、`cat`→stdout），被 369 处断言调用 → 这是**最大的单一可压缩点**。若改成「一次 `grep -c` 直接取数」，按第 10、13 条可省 2 个进程/断言。 | [harness.sh](tests/harness.sh)（计数来自本次 grep 统计）；机制依据 [dash(1)](https://man7.org/linux/man-pages/man1/dash.1.html) | 两者 |
| 18 | 并行 `make -j` 的官方代价是**输出交错**（GNU make 官方原话：可能「在同一行上」交错），解决手段是 `-O/--output-sync`（`line`/`target`/`recurse`）；官方另给 `-l/--max-load` 限制并发。 | [Parallel Output (GNU make)](https://www.gnu.org/software/make/manual/html_node/Parallel-Output.html)；[Parallel Execution](https://www.gnu.org/software/make/manual/html_node/Parallel.html) | 两者（若用 make 驱动） |
| 19 | `xargs -P` 并行的官方缺陷：**输出不分组**（可能半行来自一个进程、后半行来自另一个）、**不保证顺序**、**不支持按核数自动并行**；且 POSIX 只「鼓励」实现新增并行选项——**`-P` 不是 POSIX**。→ 本机 busybox 的 `xargs -P` 必须实测。 | [GNU parallel: xargs 差异](https://www.gnu.org/software/parallel/parallel_alternatives.html)；[POSIX xargs](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/xargs.html) | 本机需实测；CI 可用 |
| 20 | 并行化本仓库必须先修两处共享状态：① `_t_grep_count` 写死的 `$T_WORK_ROOT/.grep.tmp` / `.grep.n`（**已解决**：该函数改为内建读文件，不再落中间文件）；② `T_PASS/T_FAIL/T_SKIP` 只存在于单进程，必须改成「子进程各报各的、父进程汇总」——这一条仍待做。 | [harness.sh](tests/harness.sh)、[run-tests.sh](tools/run-tests.sh)（仓库代码；**无外部一手来源**，本节结论均为对代码结构的推断） | 两者 |
| 21 | 并行的安全粒度是「**一个用例文件一个进程**」：9 个文件用的固定工作目录（`api/config/device/commands/headers/keepalive/layer-order/skeleton/state`）在文件内天然串行，故文件级并行不冲突；细到「用例级」就必须给这 9 个目录加唯一后缀。 | [harness.sh](tests/harness.sh)、`tests/*.sh`（仓库代码；**推断**） | 两者 |
| 22 | **装上 WSL2 是官方支持的「回到原生 Linux 进程语义」的路**：`wsl --install`（管理员 PowerShell + **重启**），要求 Windows 10 2004+/Build 19041+ 或 Windows 11；WSL2 用真实 Linux 内核，官方称文件密集型操作明显更快。 | [Install WSL](https://learn.microsoft.com/en-us/windows/wsl/install)；[Manual installation steps](https://learn.microsoft.com/en-us/windows/wsl/install-manual)；[Comparing WSL Versions](https://learn.microsoft.com/en-us/windows/wsl/compare-versions) | 本机 |
| 23 | **WSL2 是「一次性成本换持续收益」**：一次管理员权限 + 一次重启之后，第 2、11–14 条里所有 Windows 特有的额外开销（原生进程创建贵、模拟 fork 贵、杀软拦截）整体消失；且与 CI 的 `ubuntu-latest` 环境更接近。 | 组合同上三条 + [Git for Windows](https://gitforwindows.org/windows-vs-linux-fork-and-exec-semantics.html)（**推断**：这是本文最强的提速建议） | 本机 |
| 24 | Docker Desktop 官方安装文档在 [docs.docker.com](https://docs.docker.com/desktop/setup/install/windows-install/)；但**其正文（System requirements / WSL 2 backend vs Hyper-V backend 的具体前置条件）本次未读到**，需自行核对。**推断**：对本仓库收益低于 WSL2。 | [Install Docker Desktop on Windows — Docker Docs](https://docs.docker.com/desktop/setup/install/windows-install/)（仅能确认页面存在） | 本机 |

### 明确「未找到一手来源」的清单（汇总）

1. 微软**没有**公布「Defender 实时扫描使单次进程创建增加多少毫秒」的实测数字，也**没有**「构建/测试负载应排除哪些进程」的官方清单（可用的最接近材料是 [Hyper-V 主机排除项 KB](https://learn.microsoft.com/en-us/troubleshoot/windows-server/virtualization/antivirus-exclusions-for-hyper-v-hosts)）。
2. `Windows Internals` 第 5 章 PDF（官方 Sysinternals 托管）被 MIME 检查挡下（HTTP 406），**`CreateProcess` 内部步骤的一手条目本次未读到**。
3. **Git for Windows 官方没有专门文档解释「为什么自带 `usr/bin/dash.exe`」**，也没有对 dash 的性能声明；可依据的只有「Git for Windows = MSYS2/Cygwin 血统」这一手自述。
4. **MSYS2 官网没有 fork 模拟开销的独立一手文档**；相关一手材料在 Cygwin FAQ 与 newlib-cygwin 源码树。
5. **ShellCheck 官方文档没有性能/省进程类的条目**（它只有逐错误码的正确性说明）。
6. **POSIX 规范不提供性能指南**，只规定语义；`xargs -P` 不是 POSIX（只有一句「鼓励实现新增并行选项」）。
7. **没有一手来源**为「shell 测试框架的共享临时文件/共享计数器应当如何并行化」给出通用建议；第 20、21 条全部是基于本仓库代码结构的推断。
8. **docs.docker.com 的 Docker Desktop Windows 系统要求正文本次未读到**（页面 JS 渲染 + 本机 TLS 客户端凭证失败）。

### 本地取证限制（影响结论强度）

- `Get-MpPreference` / `Get-MpComputerStatus` 本次调用无输出，`Get-CimInstance Win32_OperatingSystem` 返回「拒绝访问」→ **本机 Defender 状态与排除项现状未确认**。
- 本机 PowerShell / `curl.exe` **无法建立出网 TLS 连接**（`SEC_E_NO_CREDENTIALS`），因此所有外部资料都是通过本会话的 `web_fetch` / `web_search` 工具取得的。
- 本机 `wsl.exe` 存在但**未安装任何发行版**：运行 `wsl.exe --status` 返回「适用于 Linux 的 Windows 子系统未安装……请运行 `wsl.exe --install`」。
