#!/bin/sh
# ============================================================
# 设备命令替身的生成器 —— 被 device / keepalive / notify 三处共用
#
# 用法：由用例文件 source；调用前先设好 DV_WORK（落点=工作目录）。
#   . "$T_ROOT/tests/_device-tools.sh"
#   DV_WORK="$X_WORK" dv_tools
#
# 为什么单独一份：它一度只放在 tests/device.sh 里，另外两个用例文件要用它就得靠
# 总入口「把所有用例文件 source 进同一个 shell」这条隐含顺序。并行跑时每个用例文件
# 各自一个子进程，那种依赖不成立，设备命令会静默变成 no-op、断言空转。
# 文件名以 _ 开头：总入口按这个前缀跳过，不当它是用例文件。
# ============================================================

# 生成 am / input / wm / dumpsys 四个替身到 $DV_WORK/bin，输出路径。
# 两层兜底（两种环境各自需要其中一层）：
#   1) `#!$bb sh` 起头：Windows 上「可执行」要求存在解释器，只有 busybox 认这个 shebang；
#      没有它时 PATH 上的 dumpsys 会**静默变成 no-op**（断言全部空转，最难发现的一种失败）。
#   2) 末尾再按「显式解释器」跑一遍：CI 的 /bin/sh 与本地多套一个 busybox .exe 时都能落地。
dv_tools() {
  local t bb real
  bb=$(t_find_busybox)
  [ -n "$bb" ] || bb="busybox"
  case "$bb" in
    *.exe|*.EXE) real="$bb sh \"\$0\" \"\$@\"" ;;
    *)           real="$bb \"\$0\" \"\$@\"" ;;
  esac
  mkdir -p "$DV_WORK/bin"
  for t in am input wm dumpsys; do
    {
      echo "#!$bb sh"
      echo '# 由 tests/_device-tools.sh 生成：设备命令替身（记录命令行与 fd 见证，并注入输出）'
      echo "BB_REAL='$bb'"
      echo "MOCK_DIR='$T_ROOT/tests/mock'"
      echo 'export BB_REAL'
      echo "if [ -x \"\$MOCK_DIR/busybox\" ]; then exec \"\$MOCK_DIR/busybox\" $t \"\$@\"; fi"
      echo "$real"
    } > "$DV_WORK/bin/$t"
    chmod +x "$DV_WORK/bin/$t" 2>/dev/null || true
  done
}
