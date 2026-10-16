#!/bin/sh
# ============================================================
# 设备冒烟工具（tools/device-smoke.sh）的契约断言
#
# 它只能在真机上跑完（本机没有 Android、也没有 root），故这里钉的是**脚本自己在真机上
# 一定会做的那两件事**——这两件事在本机就能观察到，不必整份跑完：
#   1) 冒烟开始前经 `setconfig` 打开调试档：这份脚本依赖降权探测「可用」那一行与保活心跳，
#      而它们在默认档不再写；不开档，冒烟会把自己判成失败；
#   2) 退出时把档位恢复成进脚本时的样子；原本就是调试档则一次都不写。
#
# 观察面：模块桩（`$M/fafu_checkin.sh`）把每次子命令调用按顺序记进一个文件。冒烟脚本只经
# `sh $E <子命令>` 与模块打交道，所以那份记录就是它的对外行为；正文第一件事是查 uid，
# 本机与 CI 都不是 root，故正文会立刻收尾——记录里剩下的正是这段前导。
# 第 6 节「setconfig 往返」的键清单要跑到那一步才看得见，那一项只能用静态锚点守着。
# ============================================================

DS_WORK=""
DS_CALLS=""

# 模块桩：应答冒烟脚本前导用到的两个子命令（webstate 报档位、setconfig 回显生效值）
ds_stub_write() { # $1=模块目录 $2=原始档位
  mkdir -p "$1"
  cat > "$1/fafu_checkin.sh" <<STUB
#!$(t_find_busybox) sh
# 由 tests/device-smoke.sh 生成：模块桩（记录子命令，应答 webstate / setconfig）
printf '%s\n' "\$*" >> "\$DS_CALLS"
case "\$1" in
  webstate)  echo "debug=$2" ;;
  setconfig)
    shift
    for _p in "\$@"; do printf '%s=%s\n' "\${_p%%=*}" "\${_p#*=}"; done
    ;;
esac
exit 0
STUB
  chmod +x "$1/fafu_checkin.sh" 2>/dev/null || true
}

ds_setup() { # $1=用例名 $2=原始档位
  DS_WORK="$T_WORK_ROOT/device-smoke-$1"
  rm -rf "$DS_WORK"
  mkdir -p "$DS_WORK/mod"
  DS_CALLS="$DS_WORK/calls"
  : > "$DS_CALLS"
  ds_stub_write "$DS_WORK/mod" "$2"
}

# 跑冒烟脚本。M / OUT 都指向本用例的工作目录（否则脚本会去 /sdcard 下落证据文件），
# WAIT_KA=0 免掉正文里那段 15 分钟节拍等待（正文本来就跑不到那里）。
# stderr 与 stdout 并进同一个文件：本机没有 getprop 这类设备命令，前导里那几行「命令找不到」
# 是跑测机器的环境噪声，不是被测行为；出问题时整份输出就在 smoke.out 里。
ds_run() {
  (
    cd "$DS_WORK" || exit 1
    M="$DS_WORK/mod" OUT="$DS_WORK/smoke.txt" WAIT_KA=0 DS_CALLS="$DS_CALLS" \
      $(t_sh) "$T_ROOT/tools/device-smoke.sh"
  ) > "$DS_WORK/smoke.out" 2>&1
  return 0
}

# 桩记录里出现了几次某个字面量
ds_calls() { # $1=字面量
  grep -c "^$1" "$DS_CALLS" 2>/dev/null
}

# 记录里的第 $1 行
ds_call_line() { sed -n "$1p" "$DS_CALLS" 2>/dev/null; }

# ============================================================
# 一、档位：冒烟前打开、退出时恢复
# ============================================================

ds_case_tier_guard() {
  ds_setup guard 0
  ds_run
  # 防空转：桩没被调到过时下面几条都会「恰好」为空，先钉一下它真的跑到了
  t_eq "冒烟脚本真的走到了模块桩（记录非空）" "$(grep -c . "$DS_CALLS")" "3"
  t_eq "第一件事是读当前档位（读的是页面读得到的那一个字段）" "$(ds_call_line 1)" "webstate"
  t_eq "紧接着经写入闸门把调试档打开（默认档下它自己开的那些观察点才写得出来）" \
    "$(ds_call_line 2)" "setconfig DEBUG=1"
  t_eq "退出时把档位恢复成进脚本时的样子" "$(ds_call_line 3)" "setconfig DEBUG=0"
}

# 原档位就是 1：不必打开，也不必恢复——一次写入都不该发生。
# 这条同时守住「恢复」不会把档位写坏：写成 0 就是把使用者的调试档关掉了。
ds_case_tier_kept() {
  ds_setup kept 1
  ds_run
  t_eq "原档位就是 1：读一次就够" "$(grep -c . "$DS_CALLS")" "1"
  t_eq "原来就是调试档时一次都不写（不打开也不恢复）" "$(ds_calls 'setconfig')" "0"
  t_eq "读到的确实是档位字段" "$(ds_call_line 1)" "webstate"
}

# ============================================================
# 二、第 6 节的 setconfig 往返清单带上档位键（静态：那一段要 root 才跑得到）
# ============================================================

ds_case_roundtrip_key() {
  local smoke
  smoke="$T_ROOT/tools/device-smoke.sh"
  # 只认「往返清单里出现了 DEBUG」这条意图，不把那一行的写法抄进来：换变量名或换成循环
  # 都不该让这条报红（真正的不变量是「档位键走得到真机上那道闸门」）。
  t_has_re "setconfig 往返的键清单带上调试档（它现在是在册键）" "$smoke" 'WS_KEYS=.*DEBUG='
  t_hasnt "档位的打开与恢复都走写入闸门，不直接改配置文件" "$smoke" "fafu-checkin.conf"
}

# ---- 注册（顺序即执行顺序） ----

t_case "device-smoke · 冒烟前开调试档、退出时恢复" ds_case_tier_guard
t_case "device-smoke · 原本就是调试档时一次都不写" ds_case_tier_kept
t_case "device-smoke · 往返键清单带上档位（静态）" ds_case_roundtrip_key
