# ============================================================
# signin 层的兼容入口：把四个实现文件 source 进来
#
# 26 条用例按归属注册在各自实现文件的末尾（这样并行时四个文件各成一个 worker，
# 那个 649 秒的串行块才能被摊开）：
#   signin-submit.sh   判定与提交：返回码、四个分支、解析与坐标、提交与补签、失败
#   signin-refresh.sh  token 失效后刷新重试、窗口边界五个时点
#   signin-query.sh    查询失败的诊断行、任务变化只记一行（含跨日）
#   signin-remind.sh   判定链静态断言、三条截止提醒、提交失败的原因
# 本文件保留是因为仓库里多处按 `tests/signin.sh` 指这一层；它自己不含用例与实现。
# 用例名前缀是 `signin-<片> · `，故 `^signin` 仍命中本层全部 26 条。
# ============================================================

. "$T_ROOT/tests/signin-submit.sh"
. "$T_ROOT/tests/signin-refresh.sh"
. "$T_ROOT/tests/signin-query.sh"
. "$T_ROOT/tests/signin-remind.sh"
