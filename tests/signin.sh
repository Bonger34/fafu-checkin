# ============================================================
# signin 层验收断言的注册入口：只登记用例名与处理函数，不放实现
#
# 用例分布（前导都在 tests/_signin-common.sh）：
#   signin-submit.sh   判定与提交：返回码、四个分支、解析与坐标、提交与补签、失败
#   signin-refresh.sh  token 失效后刷新重试、窗口边界五个时点
#   signin-query.sh    查询失败的诊断行、任务变化只记一行（含跨日）
#   signin-remind.sh   判定链静态断言、三条截止提醒、提交失败的原因
# 顺序即执行顺序；t_case 的名字决定筛选关键字（`^signin` 命中本层全部）。
# ============================================================

# 本层拆成 5 个文件，故由注册入口把实现文件 source 进来（前导由它们各自 source）。
# 显式列出来而不是指望总入口：并行跑时每个用例文件各自一个子进程，只加载自己。
. "$T_ROOT/tests/signin-submit.sh"
. "$T_ROOT/tests/signin-refresh.sh"
. "$T_ROOT/tests/signin-query.sh"
. "$T_ROOT/tests/signin-remind.sh"

# ---- 注册（顺序即执行顺序） ----

t_case "signin · 时钟与夹具自证" sg_case_clock
t_case "signin · 三档返回码（成功 / 可重试 / 任务异常）" sg_case_codes
t_case "signin · 等 App 数据就绪（等到就用，等不到有界退回）" sg_case_wait_appdata
t_case "signin · 分支：已签到（记录 + 通知）" sg_case_branch_seen
t_case "signin · 分支：已请假（记录 + 通知）" sg_case_branch_leave
t_case "signin · 分支：窗口内提交（normal）" sg_case_branch_window
t_case "signin · 分支：不在时段（可重试）" sg_case_branch_outside
t_case "signin · 任务信息不完整（可重试）" sg_case_parse_incomplete
t_case "signin · 解析写回调用方字段（端到端）" sg_case_parse_outputs
t_case "signin · 截止字段回退 endTime" sg_case_parse_fallback
t_case "signin · 坐标缺失回退内置坐标" sg_case_coords_fallback
t_case "signin · 坐标取值优先级（signInStudent ＞ 顶层 ＞ 内置）" sg_case_coords_priority
t_case "signin · token 一路传到提交（端到端）" sg_case_token_chain
t_case "signin · 提交：补签（supplement）" sg_case_submit_supplement
t_case "signin · 提交失败：尝试行与汇总行" sg_case_submit_failed
t_case "signin · 提交失败当日仅首次通知（跨轮）" sg_case_submit_failed_once
t_case "signin · 提交失败后的短重试" sg_case_submit_retry
t_case "signin · 窗口边界（21:29 / 21:30 / 22:30 / 22:59 / 23:00）" sg_case_boundaries
t_case "signin · token 失效后刷新重试" sg_case_token_refresh
t_case "signin · 查询失败：参数与完整正文" sg_case_fetch_fail
t_case "signin · 任务变化：四元组变了才记一行（含跨日）" sg_case_task_change
t_case "signin · 判定链与主循环分支（静态）" sg_case_boundary
t_case "signin · 截止提醒的判定（纯函数）" sg_case_remind_due
t_case "signin · 三条截止提醒按任务数据各发一次" sg_case_remind_events
t_case "signin · 提交失败的原因留在日志里（HTTP 状态码 / 超时）" sg_case_fail_reason
t_case "signin · 提交尝试行的字段集（拒绝 / 成功 / 连接层失败）" sg_case_attempt_lines
