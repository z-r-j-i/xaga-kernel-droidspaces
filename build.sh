#!/usr/bin/env bash
# ============================================================================
#  xaga GKI 容器内核编译脚本  (v7)
#
#  路线：AOSP android12-5.10 GKI 5.10.226 + Droidspaces 官方 kABI 补丁
#
#  为什么是这条路（由 Droidspaces 官方 Kernel-Configuration.md 决定）：
#   - 原厂是 GKI 内核，厂商代码全在 vendor_dlkm/vendor_boot 的 608 个 .ko 里
#   - 所以只编 boot 分区的 Image.gz，模块一个不动
#   - SYSVIPC / IPC_NS / POSIX_MQUEUE 会给 task_struct / user_struct 加字段，
#     直接开启会改 ABI → 厂商模块拒绝加载 → 开机循环
#   - 官方 kABI 补丁把这些字段挪进 ANDROID_KABI_RESERVE 的 padding 槽，
#     所以能开这些选项而 ABI 不变
#   - CGROUP_PIDS / CFS_BANDWIDTH 会改调度器结构体大小，没有 padding 能救，
#     绝对不能开（代价是 --cpus / --pids-limit 两个开关变灰）
#
#  v3 变更：
#   - 工具链改为「找 LLVM 目录 + 加进 PATH」，不再依赖 ld.lld / ld.lld-12 的
#     具体文件名（旧版在这里直接 FAIL）
#   - 修掉 002 补丁被重复打一次的 bug
#   - 编译失败时自动关掉 DEBUG_INFO / BTF 重试一次（BTF 只影响 BPF CO-RE，
#     不影响开机、不影响 vermagic）
#   - 编译摘要直接写进 $GITHUB_STEP_SUMMARY，workflow 里不再需要易出错的多行 shell
#
#  v4 变更（这一版才真正能编）：
#   - 补上交叉编译目标三元组 --target=aarch64-linux-gnu。5.10 的 Makefile 只在
#     CROSS_COMPILE 非空时才加 --target=，否则 clang 按 x86_64 编，arm64 内联汇编
#     全报 "unknown register name 'x0'"，编译在 kernel/bounds.s 就挂
#   - 编译前先做一次 4 行的交叉编译自检，目标不对立刻失败，不浪费 40 分钟
#
#  用法：
#    ./build.sh            完整编译 + 打包
#    ./build.sh --probe    只探测版本，不编译
#
#  v7 变更（专治「失败但看不到原因」）：
#   - 编译输出不再经过 tail：全量 tee 进 build.log，屏幕只透传 error/LD/AR 等关键行，
#     避免 Actions 日志长度上限把末尾的失败报告冲掉
#   - build.log 改为 append 模式写（tee -a），否则脚本日志和 make 输出两个写者
#     的文件偏移会互相覆盖，日志变乱码
#   - 失败报告不再只 tail 一段：抓「全部 error 行 + 首个错误上下文 + make 失败目标
#     + 内核 OOM 记录 + 磁盘/内存快照 + 末尾 150 行」，整份打印并写 artifacts/errors.txt
#   - 并发按内存自适应（GKI 全量 LTO 一个 clang 进程峰值 2GB 级，-j4 可能 OOM；
#     OOM 的特征正是「日志里没有任何 error: 行，make 直接 Error 2」）
# ============================================================================
set -euo pipefail

KERNEL_REPO="${KERNEL_REPO:-https://github.com/aosp-mirror/kernel_common}"
KERNEL_BRANCH="${KERNEL_BRANCH:-android12-5.10}"
# "Merge 5.10.226 into android12-5.10-lts" — Makefile SUBLEVEL = 226
PIN="${PIN:-7d3ca1ed3f709bc42b60aaf10e52e82ea9d32fd5}"
TARGET_SUBLEVEL="${TARGET_SUBLEVEL:-226}"
STOCK_LOCALVERSION="${STOCK_LOCALVERSION:--android12-9-00047-g4968e29b7f92-ab12786767}"

# Droidspaces 官方 kABI 补丁目录
PATCH_BASE="${PATCH_BASE:-https://raw.githubusercontent.com/ravindu644/Droidspaces-OSS/main/Documentation/resources/kernel-patches/GKI/below-kernel-6.12}"
# 001 有三个变体，占用不同的 ANDROID_KABI_RESERVE 槽位。
# 官方建议先试 6_7_8；若开机循环，改用 1_2_3 或 3_4_5。
KABI_SLOT="${KABI_SLOT:-6_7_8}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAGMENT="$SCRIPT_DIR/patches/containers.fragment"
KERNEL_DIR="$SCRIPT_DIR/kernel"
OUT="$SCRIPT_DIR/out"
ART="$SCRIPT_DIR/artifacts"
LOG="$SCRIPT_DIR/build.log"

# 并发数：GKI 开了全量 LTO，单个 clang 进程峰值 1.5~2.5GB，
# 链接阶段 lld 单独要 4~8GB。4 核 16G 的 runner 上无脑 -j4 有 OOM 风险，
# OOM 会表现为「没有任何 error: 行、make 直接 Error 2」，极难排查，所以这里按内存压一压。
_nproc="$(nproc 2>/dev/null || echo 4)"
_mem_mb="$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"
JOBS="${JOBS:-$_nproc}"
if [ "${_mem_mb:-0}" -gt 0 ] 2>/dev/null; then
  _by_mem=$(( _mem_mb / 2600 ))
  [ "$_by_mem" -ge 1 ] || _by_mem=1
  if [ "$JOBS" -gt "$_by_mem" ]; then
    JOBS="$_by_mem"
  fi
fi
PROBE_ONLY=0
[ "${1:-}" = "--probe" ] && PROBE_ONLY=1

export ARCH=arm64
export LC_ALL=C

log()  { printf '\n\033[1;36m==> [%s] %s\033[0m\n' "$(date -u +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[WARN] %s\033[0m\n' "$*"; }
summary() {
  # 只在 GitHub Actions 里有意义；本地跑就是空操作
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
}
die()  {
  printf '\n\033[1;31m[FAIL] %s\033[0m\n' "$*" >&2
  summary ""
  summary "### 编译失败"
  summary ""
  summary '```'
  summary "$*"
  summary '```'
  # 只补最后 8 行，真正的 error 由调用方 show_build_errors 打
  if [ -s "$LOG" ]; then
    printf '\033[1;31m---- build.log 末尾 8 行 ----\033[0m\n' >&2
    tail -n 8 "$LOG" >&2 || true
    printf '\033[1;31m----------------------------\033[0m\n' >&2
    summary ""
    summary "<details><summary>build.log 末尾 40 行</summary>"
    summary ""
    summary '```'
    tail -n 40 "$LOG" >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
    summary '```'
    summary ""
    summary "</details>"
  fi
  exit 1
}
# set -e 触发的隐式退出也要留下行号（否则只看到 "exit code 2"，不知道哪一步）
# 注意：ERR trap 在 set +e 下也会触发，所以「预期内的失败」要主动 trap '' ERR 屏蔽
on_err() {
  local rc=$?
  if [ "$rc" != "0" ]; then
    printf "\n\033[1;31m[TRAP] 第 %s 行异常退出，退出码 %s\033[0m\n" "$LINENO" "$rc" >&2
  fi
}
trap on_err ERR

# 全程 tee 到 build.log，失败时 workflow 能作为 artifact 上传
# 必须用 append 模式：编译阶段 make 的输出是直接 >>$LOG 的，
# 如果 tee 用截断模式，两个写者的文件偏移各自独立，会互相覆盖，日志变乱码
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

log "环境：$(uname -m) / 磁盘 $(df -h . | awk 'NR==2{print $4}') 可用 / CPU $(nproc) 核 / 内存 $(free -h 2>/dev/null | awk '/^Mem:/{print $2}')"
log "目标：5.10.${TARGET_SUBLEVEL} + GKI + Droidspaces（只换 boot 内 Image）"

# --------------------------- 1. 拉源码 --------------------------------------
# 按 commit 浅取（只下这一个快照），比拉全历史快好几倍；
# GitHub 若拒绝任意 sha，再退回分支克隆。
if [ ! -d "$KERNEL_DIR/.git" ]; then
  log "取源码 $KERNEL_REPO @ ${PIN:0:12}（depth=1）"
  mkdir -p "$KERNEL_DIR"
  git -C "$KERNEL_DIR" init -q
  git -C "$KERNEL_DIR" remote add origin "$KERNEL_REPO" 2>/dev/null || \
    git -C "$KERNEL_DIR" remote set-url origin "$KERNEL_REPO"
  if git -C "$KERNEL_DIR" fetch -q --depth=1 origin "$PIN"; then
    git -C "$KERNEL_DIR" checkout -q FETCH_HEAD || die "checkout FETCH_HEAD 失败"
  else
    warn "按 commit 浅取失败，退回分支克隆（慢，但一定能拿到）"
    rm -rf "$KERNEL_DIR"
    git clone --filter=blob:none -b "$KERNEL_BRANCH" "$KERNEL_REPO" "$KERNEL_DIR" \
      || die "克隆 $KERNEL_REPO 失败"
    git -C "$KERNEL_DIR" checkout -q "$PIN" \
      || die "checkout $PIN 失败（这个 commit 不在 $KERNEL_BRANCH 历史里？）"
  fi
fi
cd "$KERNEL_DIR"

log "确认源码版本"
KVER="$(make -s kernelversion 2>/dev/null || true)"
[ -n "$KVER" ] || KVER="$(awk '/^VERSION =|^PATCHLEVEL =|^SUBLEVEL =/{printf "%s.",$3}' Makefile | sed 's/\.$//')"
log "源码版本：$KVER"
[ "$KVER" = "5.10.${TARGET_SUBLEVEL}" ] \
  || die "版本不符！期望 5.10.${TARGET_SUBLEVEL}，实际 $KVER —— PIN 指错了"

if [ "$PROBE_ONLY" = "1" ]; then
  echo "PROBE_RESULT version=$KVER pin=$PIN"
  exit 0
fi

# --------------------- 2. 打 Droidspaces kABI 补丁 --------------------------
# 这一步不是可选的。不打补丁就开 SYSVIPC，设备会开机循环。
P001_FMT="$PATCH_BASE/001.GKI-below-6.12-fix_sysvipc_kabi_%s.patch"
P002="$PATCH_BASE/002.5.10_or_lower_use_android_abi_padding_for_posix_mqueue.patch"

log "打 Droidspaces kABI 补丁 001（SYSVIPC → ABI padding）"
APPLIED_SLOT=""
for slot in "$KABI_SLOT" 1_2_3 3_4_5 6_7_8; do
  [ -n "$APPLIED_SLOT" ] && break
  url="$(printf "$P001_FMT" "$slot")"
  rm -f /tmp/001.patch
  code=$(curl -fsSL -w '%{http_code}' "$url" -o /tmp/001.patch 2>/dev/null || true)
  if [ ! -s /tmp/001.patch ]; then
    warn "001 变体 ${slot} 下载失败（http=$code），换下一个"
    continue
  fi
  git checkout -q -- include/linux/sched.h 2>/dev/null || true
  if patch -p1 --forward --dry-run < /tmp/001.patch >/tmp/p.log 2>&1; then
    patch -p1 --forward < /tmp/001.patch >/dev/null 2>&1 || { warn "001(${slot}) 写入异常，换下一个"; continue; }
    APPLIED_SLOT="$slot"
    log "001 使用槽位 ${slot}"
  else
    warn "001(${slot}) 与本树上下文不匹配，换下一个变体"
    tail -n 4 /tmp/p.log | sed 's/^/    /' || true
  fi
done
[ -n "$APPLIED_SLOT" ] || die "001 的三个槽位变体都打不上 —— sched.h 与补丁基线不一致"
KABI_SLOT="$APPLIED_SLOT"

log "打 Droidspaces kABI 补丁 002（POSIX_MQUEUE → ABI padding）"
curl -fsSL "$P002" -o /tmp/002.patch || die "002 补丁下载失败: $P002"
[ -s /tmp/002.patch ] || die "002 补丁是空文件: $P002"
# 只打一次。旧版在这里写了两遍，第二次会命中 "previously applied" 直接失败。
patch -p1 --forward < /tmp/002.patch || die "002 补丁应用失败（user.h 上下文不匹配）"

# 确认补丁真的落到了代码里
grep -q "ANDROID_KABI_USE" include/linux/sched.h \
  || die "001 补丁似乎没生效（include/linux/sched.h 里没有 ANDROID_KABI_USE）"
grep -q "ANDROID_KABI_USE" include/linux/sched/user.h \
  || die "002 补丁似乎没生效（include/linux/sched/user.h 里没有 ANDROID_KABI_USE）"
log "kABI 补丁已生效（001 slot=${KABI_SLOT} + 002）"

# --------------------------- 3. 工具链 --------------------------------------
# AOSP GKI 5.10 官方用 clang-r416183b（12.0.5），原厂内核也是它编的。
# 但不同环境给的工具名不一样（clang / clang-12 / ld.lld / ld.lld-12），
# 所以这里不猜文件名，而是找一个同时含 clang+ld.lld+llvm-ar 的 LLVM bin 目录，
# 把它塞到 PATH 最前面，然后用 CC=clang LLVM=1 统一交给 kbuild。
log "准备工具链"

if [ "$(id -u)" = "0" ]; then SUDO=""; else SUDO="sudo"; fi
ensure_pkgs() {
  local miss=()
  for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || miss+=("$p"); done
  if [ "${#miss[@]}" -eq 0 ]; then return 0; fi
  log "补装依赖：${miss[*]}"
  command -v apt-get >/dev/null 2>&1 || { warn "没有 apt-get，无法安装 ${miss[*]}"; return 1; }
  $SUDO apt-get update -qq >/dev/null 2>&1 || true
  if $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${miss[@]}" >/dev/null 2>&1; then
    log "已安装：${miss[*]}"
  else
    warn "安装 ${miss[*]} 失败（可能没有对应包），继续尝试已有工具"
    return 1
  fi
}
# pahole（dwarves）是 CONFIG_DEBUG_INFO_BTF 必需，libelf-dev 是 objtool 必需
ensure_pkgs clang-12 lld-12 llvm-12 dwarves libelf-dev patch bc bison flex \
             libncurses-dev libssl-dev cpio zstd zip unzip || true

pick_llvm() {
  local d
  LLVM_BIN=""
  # 1) PATH 里本来就是一对（clang + ld.lld + llvm-ar 同目录）
  if command -v clang >/dev/null 2>&1; then
    d="$(cd "$(dirname "$(command -v clang)")" && pwd)"
    if [ -x "$d/ld.lld" ] && [ -x "$d/llvm-ar" ]; then LLVM_BIN="$d"; fi
  fi
  # 2) 版本化目录，12 优先（= AOSP GKI 5.10 原厂版本），再到新的
  if [ -z "$LLVM_BIN" ]; then
    for d in /usr/lib/llvm-12/bin /usr/lib/llvm-13/bin /usr/lib/llvm-14/bin \
             /usr/lib/llvm-15/bin /usr/lib/llvm-16/bin /usr/lib/llvm-17/bin; do
      if [ -x "$d/clang" ] && [ -x "$d/ld.lld" ] && [ -x "$d/llvm-ar" ]; then
        LLVM_BIN="$d"; break
      fi
    done
  fi
}
pick_llvm

if [ -z "$LLVM_BIN" ]; then
  warn "没找到完整 LLVM 目录，当前可见工具："
  ls -1 /usr/lib/llvm-*/bin/ld.lld 2>/dev/null | sed 's/^/    /' || true
  command -v clang 2>/dev/null | sed 's/^/    clang: /' || true
  command -v ld.lld 2>/dev/null | sed 's/^/    ld.lld: /' || true
  die "没有可用的 clang+ld.lld 组合。请确保已安装 clang-12 / lld-12（或 clang / lld）"
fi
export PATH="$LLVM_BIN:$PATH"

CLANG_VER="$(clang --version | head -1)"
LLD_VER="$(ld.lld --version | head -1)"
log "LLVM 目录：$LLVM_BIN"
log "clang：$CLANG_VER"
log "ld.lld：$LLD_VER"

command -v pahole >/dev/null 2>&1 || warn "没有 pahole，若开了 DEBUG_INFO_BTF 会失败（下面有自动重试）"

# ---- 目标三元组：这一步曾经把整轮编译搞挂 ----
# 5.10 的 Makefile 只有「CROSS_COMPILE 非空」时才会加 --target=，
# 不传的话 clang 按宿主机 x86_64 编，arm64 内联汇编（asm("x0")）全部报
# "unknown register name"，像这次的 kernel/bounds.s。
# 这里直接把 --target 塞进 CC，比设 CROSS_COMPILE 更干净：
# 设 CROSS_COMPILE 会让 Makefile 再去 which aarch64-linux-gnu-elfedit 拼
# --prefix=/--gcc-toolchain=，没装交叉 binutils 时会拼出 "./aarch64-linux-gnu" 这种垃圾值。
TARGET_TRIPLE="aarch64-linux-gnu"
MAKE_TOOL_ARGS=(CC="clang --target=$TARGET_TRIPLE" LLVM=1 LLVM_IAS=1)

log "验证交叉编译目标：$TARGET_TRIPLE"
printf 'int __xaga_probe;\n' > /tmp/probe.c
if ! clang --target="$TARGET_TRIPLE" -c /tmp/probe.c -o /tmp/probe.o 2>/tmp/probe.log; then
  tail -5 /tmp/probe.log | sed 's/^/    /' || true
  die "clang 无法以 $TARGET_TRIPLE 为目标编译"
fi
if command -v llvm-readelf >/dev/null 2>&1; then
  llvm-readelf -h /tmp/probe.o | grep -qi 'aarch64' \
    || die "测试编译出的 .o 不是 AArch64 —— 交叉编译没生效，编下去只会得到一堆 x0 寄存器错误"
fi
log "目标确认：生成的 .o 为 AArch64 ✓"

# --------------------------- 4. 生成配置 ------------------------------------
log "合并 gki_defconfig + Droidspaces fragment"
rm -rf "$OUT" && mkdir -p "$OUT"

./scripts/kconfig/merge_config.sh -m \
  arch/arm64/configs/gki_defconfig \
  "$FRAGMENT" 2>&1 | tail -8

# merge_config.sh 把结果写到源码根的 .config，而 make O=$OUT 读的是 $OUT/.config。
# 不搬过去的话 olddefconfig 会从零生成默认配置，前面合并的 fragment 全部丢失。
if [ -f .config ]; then
  cp -f .config "$OUT/.config"
  rm -f .config
fi
[ -s "$OUT/.config" ] || die "合并后 $OUT/.config 不存在 —— merge_config 失败了"

# 抑制 setlocalversion（版本串只保留 CONFIG_LOCALVERSION 的原值）
touch .scmversion

log "olddefconfig"
make ARCH=arm64 O="$OUT" olddefconfig 2>&1 | tail -5

# --------------------------- 5. 配置校验 ------------------------------------
log "校验 Droidspaces 必需项（官方 GKI 清单）"
MISSING=""
for s in CONFIG_SYSVIPC CONFIG_POSIX_MQUEUE CONFIG_IPC_NS CONFIG_PID_NS \
         CONFIG_DEVTMPFS CONFIG_USER_NS CONFIG_MACVLAN CONFIG_IP6_NF_NAT \
         CONFIG_OVERLAY_FS CONFIG_CGROUPS CONFIG_NAMESPACES; do
  if grep -qx "$s=y" "$OUT/.config"; then
    printf '  \033[32mOK\033[0m   %s\n' "$s"
  else
    printf '  \033[31mMISS\033[0m %s\n' "$s"; MISSING="$MISSING $s"
  fi
done
[ -z "$MISSING" ] || die "关键配置缺失:$MISSING"

# 硬性红线：这两项一旦开启，厂商模块必拒绝加载，设备开机循环
log "检查 kABI 红线项"
for s in CONFIG_CGROUP_PIDS CONFIG_CFS_BANDWIDTH; do
  if grep -qx "$s=y" "$OUT/.config"; then
    die "$s 被开启了 —— 这会破坏 kABI，原厂 608 个模块会拒绝加载，设备开机循环！代价只是 --cpus/--pids-limit 两个开关变灰。"
  else
    printf '  \033[32mOK\033[0m   %s 未开启（符合 kABI 安全要求）\n' "$s"
  fi
done

# 验证 LOCALVERSION（决定 vermagic 是否匹配原厂模块）
LV="$(grep '^CONFIG_LOCALVERSION=' "$OUT/.config" | cut -d'"' -f2 || true)"
log "LOCALVERSION = $LV"
[ "$LV" = "$STOCK_LOCALVERSION" ] \
  || die "LOCALVERSION 不匹配原厂！期望: $STOCK_LOCALVERSION, 实际: $LV"

# --------------------------- 6. 编译 ----------------------------------------
build_kernel() {
  # 不传 LOCALVERSION=（会覆盖 CONFIG_LOCALVERSION）
  # -O：并行编译时把每个目标的输出整块打印，避免 error 被几十行 CC 冲散
  make ARCH=arm64 O="$OUT" -O \
    "${MAKE_TOOL_ARGS[@]}" \
    KCFLAGS="-D__ANDROID_COMMON_KERNEL__" \
    -j"$JOBS" Image.gz
}

# 失败时把关键信息挖出来。
# 硬性要求：这里任何一步失败都不许让脚本提前退出 —— v5 就是栽在
# n="$(grep ... )" 上（没匹配到 → grep 返回 1 → pipefail → 赋值失败 → set -e 直接退出，
# 结果既没打摘要也没打 [FAIL]）。所以每处都加 || true，产物先落盘再打印。
#
# v7 加强：不再只 tail 一段，而是把「全部 error 行 + 首个错误上下文 + OOM 记录 +
# 结尾 150 行」一起写进 artifacts/errors.txt，并整份打到屏幕上。
# 原因：上一轮日志末尾只有 "AR kernel/built-in.a → make Error 2"，真正的
# error: 在几百行之前，靠 tail 永远看不到。
show_build_errors() {
  local log="$1"
  [ -s "$log" ] || return 0

  local total makes errs n from ctx oom line
  total="$(wc -l < "$log" 2>/dev/null | tr -d ' ' || true)"

  # [1] make 的失败目标收尾行：能直接看出是哪个 .o / 哪个目录挂了
  makes="$(grep -aE '\*\*\* \[|Error [0-9]+$|Killed' "$log" 2>/dev/null | tail -12 || true)"
  # [2] 所有错误行（全量，不截断到几行）
  errs="$(grep -aE '(^|[[:space:]/])(fatal )?error:|undefined reference to|No space left on device|Killed|internal compiler error|clang: error' "$log" 2>/dev/null | head -80 || true)"
  # [3] 首个错误的行号
  n="$(grep -anE '(^|[[:space:]/])(fatal )?error:|undefined reference to|No space left on device|Killed' "$log" 2>/dev/null | head -1 | cut -d: -f1 || true)"

  ctx=""
  if [ -n "${n:-}" ] && [ "${n:-0}" -gt 0 ] 2>/dev/null; then
    from=$(( n > 30 ? n - 30 : 1 ))
    ctx="$(sed -n "${from},$((n + 10))p" "$log" 2>/dev/null || true)"
  fi
  [ -n "$ctx" ] || ctx="$(tail -n 200 "$log" 2>/dev/null || true)"

  # [4] 内核 OOM 记录（OOM 时日志里没有 error:，只有进程被 Killed）
  oom="$( { dmesg 2>/dev/null || sudo dmesg 2>/dev/null; } | grep -aiE 'killed process|out of memory' | tail -5 || true)"

  print_report() {
    echo "==== [1] make 失败目标 ===="
    printf '%s\n' "${makes:-（无）}"
    echo
    echo "==== [2] 全部 error / 致命行（最多 80 条）===="
    printf '%s\n' "${errs:-（无 error 行）}"
    echo
    echo "==== [3] 首个错误上下文（第 ${n:-?} 行）===="
    printf '%s\n' "$ctx"
    echo
    if [ -n "${oom:-}" ]; then
      echo "==== [4] 内核 OOM 记录 ===="
      printf '%s\n' "$oom"
      echo
    fi
    echo "==== [5] 日志末尾 150 行 ===="
    tail -n 150 "$log" 2>/dev/null || true
  }

  mkdir -p "$ART" 2>/dev/null || true
  {
    echo "xaga GKI 编译失败报告"
    echo "时间: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "内核: $KVER   并发: -j$JOBS   日志行数: ${total:-?}"
    echo "clang: ${CLANG_VER:-?}   lld: ${LLD_VER:-?}"
    echo "磁盘: $(df -h "$PWD" 2>/dev/null | awk 'NR==2{print $4" 可用 / 已用 "$5}')"
    echo "内存: $(free -h 2>/dev/null | awk '/^Mem:/{print $2" 总 / 可用 "$7}')"
    echo
    print_report
  } > "$ART/errors.txt" 2>/dev/null || true

  echo
  echo "================ 编译失败报告 ================"
  print_report
  echo "============================================="

  summary ""
  summary "### 编译失败"
  if [ -n "${errs:-}" ]; then
    summary ""
    summary '```'
    while IFS= read -r line; do summary "$line"; done \
      <<< "$(printf '%s\n' "$errs" | sed -n '1,15p' || true)"
    summary '```'
  fi
  summary ""
  summary "完整报告见 artifact 里的 \`errors.txt\`"
  return 0
}

IMG="$OUT/arch/arm64/boot/Image.gz"

# 屏幕上只透传「错误 + 链接/打包」类关键行。完整输出在 build.log。
# 全量打到 stdout 会被 Actions 的日志长度上限截断，反而把末尾的失败报告冲掉 ——
# 上一轮就是这样，最后 40 行只剩一串 CC/AR。
ALERT_RE='(^|[[:space:]])(error|fatal error):|Error [0-9]+$|\*\*\* |Killed|No space left on device|undefined reference to|internal compiler error|^  (LD|AR|MODPOST|BTF|OBJCOPY|LTO|VDSOSYM|Kernel: )'

run_build() {
  # 完整输出 tee 进 build.log，过滤后的关键行显示在屏幕上。
  # 返回值必须是 make 的退出码（PIPESTATUS[0]）——函数返回后 PIPESTATUS 会被重置，
  # 所以必须在这里立刻 return。
  build_kernel 2>&1 | tee -a "$LOG" | grep --line-buffered -aE "$ALERT_RE"
  return "${PIPESTATUS[0]}"
}

log "编译 Image.gz（-j$JOBS）"
log "编译输出全部写入 build.log；屏幕上只会出现错误行和链接/打包行，长时间无新行属正常"
trap '' ERR
set +e
run_build
RC=$?
set -e
trap on_err ERR

if [ "$RC" -ne 0 ] || [ ! -f "$IMG" ]; then
  warn "首次编译失败（rc=$RC / Image.gz 存在=$([ -f "$IMG" ] && echo yes || echo no)）"
  # 只有确实跟 BTF/pahole 有关才值得重编一次；否则改配置要全量重编，白等几十分钟。
  # 注意别用裸 "BTF" 匹配 —— 日志里 kernel/bpf/btf.o 这种路径到处都是。
  if grep -aqE 'pahole|DEBUG_INFO_BTF|vmlinux\.btf' "$LOG"; then
    warn "日志里出现 BTF/pahole 字样，关闭 DEBUG_INFO / BTF 后重试"
    for opt in DEBUG_INFO_BTF MODULES_DEBUG_INFO_BTF DEBUG_INFO_BTF_MODULES DEBUG_INFO; do
      "$KERNEL_DIR/scripts/config" --file "$OUT/.config" -d "$opt" 2>/dev/null || true
    done
    make ARCH=arm64 O="$OUT" olddefconfig >/dev/null 2>&1 || true
    trap '' ERR
    set +e
    run_build
    RC=$?
    set -e
    trap on_err ERR
  else
    warn "与 BTF 无关，跳过重试直接报错"
  fi
fi

if [ ! -f "$IMG" ]; then
  show_build_errors "$LOG"
  die "Image.gz 没生成（rc=$RC） —— 见上面的编译失败摘要"
fi
gzip -t "$IMG" || die "Image.gz 不是合法的 gzip 文件"
log "Image.gz 生成成功（$(du -h "$IMG" | cut -f1)）"

# --------------------------- 7. 收集产物 ------------------------------------
rm -rf "$ART" && mkdir -p "$ART"
cp -f "$IMG" "$ART/Image.gz"

# 验证版本串（kernel.release 就是 vermagic 里的版本部分，必须与原厂一致）
KR="$(cat "$OUT/include/config/kernel.release" 2>/dev/null || true)"
[ -n "$KR" ] || KR="$(make -s ARCH=arm64 O="$OUT" kernelrelease 2>/dev/null || echo unknown)"
echo "  kernel.release: $KR"
STOCK_RELEASE="5.10.${TARGET_SUBLEVEL}${STOCK_LOCALVERSION}"
if [ "$KR" = "$STOCK_RELEASE" ]; then
  log "版本串与原厂完全一致 ✓ 原厂 .ko 可直接加载"
else
  # 不一致的包刷进去必然开机循环（608 个厂商模块的 vermagic 对不上），宁可不给
  die "版本串与原厂不一致！期望 $STOCK_RELEASE，实际 $KR —— 这个包不能刷，会开机循环"
fi

IMAGE_SHA="$(sha256sum "$ART/Image.gz" | cut -d' ' -f1)"
{
  echo "kernel_version=$KVER"
  echo "kernel_release=$KR"
  echo "source=$KERNEL_REPO@$KERNEL_BRANCH"
  echo "pin=$PIN"
  echo "kabi_slot=$KABI_SLOT"
  echo "localversion=$LV"
  echo "clang=$CLANG_VER"
  echo "clang_target=$TARGET_TRIPLE"
  echo "lld=$LLD_VER"
  echo "image_sha256=$IMAGE_SHA"
  echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$ART/BUILD-INFO.txt"

# --------------------------- 8. 打 AnyKernel3 boot-only 包 ------------------
log "打 AnyKernel3 boot-only 包"
AK3_REPO="${AK3_REPO:-https://github.com/osm0sis/AnyKernel3}"
AK3_REF="${AK3_REF:-master}"
WORK="$SCRIPT_DIR/.ak3"
rm -rf "$WORK" 2>/dev/null || true
git clone --depth=1 -b "$AK3_REF" "$AK3_REPO" "$WORK" >/dev/null 2>&1 \
  || die "AnyKernel3 克隆失败"

rm -rf "$WORK/.git" "$WORK/.github" "$WORK/README.md" \
       "$WORK/modules" "$WORK/patch" "$WORK/ramdisk" 2>/dev/null || true

cp -f "$SCRIPT_DIR/patches/anykernel/anykernel.sh" "$WORK/anykernel.sh"
cp -f "$ART/Image.gz" "$WORK/Image.gz"

[ -f "$WORK/tools/ak3-core.sh" ] || die "缺少 tools/ak3-core.sh"
[ -f "$WORK/tools/magiskboot" ]  || die "缺少 tools/magiskboot"
grep -qx 'device.name1=xaga' "$WORK/anykernel.sh" || die "devicecheck 未指向 xaga"
for f in dtb dtbo.img Image Image-dtb; do
  # 末尾的 || true 不能省：最后一轮 [ -e ] 为假时，for 会返回 1，set -e 会
  # 在打包最后一步把脚本静默干掉
  [ -e "$WORK/$f" ] && die "包根目录出现 $f，必须移除" || true
done

ZIP="$ART/xaga-gki-5.10.${TARGET_SUBLEVEL}-containers-$(date -u +%Y%m%d).zip"
rm -f "$ZIP"
cd "$WORK"
zip -r9 -q "$ZIP" anykernel.sh Image.gz tools META-INF || die "zip 打包失败"
[ -f "$WORK/LICENSE" ] && zip -q9 "$ZIP" LICENSE 2>/dev/null || true
cd "$SCRIPT_DIR"

LIST="$(unzip -Z1 "$ZIP")"
for need in anykernel.sh Image.gz tools/ak3-core.sh tools/magiskboot \
            META-INF/com/google/android/update-binary; do
  echo "$LIST" | grep -qx "$need" || die "包内缺少 $need"
done

( cd "$ART" && sha256sum "$(basename "$ZIP")" > "$(basename "$ZIP").sha256" )

log "完成"
ls -lh "$ART"

# --------------------------- 9. 摘要 ----------------------------------------
summary ""
summary "### 编译成功"
summary ""
summary "| 项 | 值 |"
summary "| --- | --- |"
summary "| 内核 | \`$KVER\` |"
summary "| kernel.release | \`$KR\` |"
summary "| kABI 补丁 | 001(slot=$KABI_SLOT) + 002 |"
summary "| clang | \`$CLANG_VER\` |"
summary "| 刷机包 | \`$(basename "$ZIP")\` |"
summary ""
summary "只写 boot 分区，不碰 vendor_dlkm / vendor_boot。\`--cpus\` / \`--pids-limit\` 不可用（kABI 安全代价）。"

echo
echo "============================================================"
echo " 内核：$KVER   LOCALVERSION：$LV"
echo " kABI 补丁：001($KABI_SLOT) + 002"
echo " 工具链：$CLANG_VER"
echo " 卡刷包：$ZIP"
echo " 只写 boot 分区，不碰 vendor_dlkm / vendor_boot"
echo " --cpus / --pids-limit 不可用（kABI 安全代价），其余功能正常"
echo "============================================================"
