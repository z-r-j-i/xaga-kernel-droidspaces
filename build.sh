#!/usr/bin/env bash
# ============================================================================
#  xaga GKI 容器内核编译脚本
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
#  用法：
#    ./build.sh            完整编译 + 打包
#    ./build.sh --probe    只探测版本，不编译
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

JOBS="${JOBS:-$(nproc)}"
PROBE_ONLY=0
[ "${1:-}" = "--probe" ] && PROBE_ONLY=1

export ARCH=arm64

log()  { printf '\n\033[1;36m==> [%s] %s\033[0m\n' "$(date -u +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[WARN] %s\033[0m\n' "$*"; }
die()  {
  printf '\n\033[1;31m[FAIL] %s\033[0m\n' "$*" >&2
  # 把最后几行再打一遍，方便直接在 Actions 日志末尾看到根因
  if [ -s "$LOG" ]; then
    printf '\033[1;31m---- build.log 末尾 25 行 ----\033[0m\n' >&2
    tail -n 25 "$LOG" >&2 || true
    printf '\033[1;31m-----------------------------\033[0m\n' >&2
  fi
  exit 1
}
# set -e 触发的隐式退出也要留下行号（否则只看到 "exit code 2"，不知道哪一步）
trap 'rc=$?; if [ "$rc" != "0" ]; then printf "\n\033[1;31m[TRAP] 第 %s 行异常退出，退出码 %s\033[0m\n" "$LINENO" "$rc" >&2; fi' ERR

# 全程 tee 到 build.log，失败时 workflow 能作为 artifact 上传
exec > >(tee "$LOG") 2>&1

log "环境：$(uname -m) / 磁盘 $(df -h . | awk 'NR==2{print $4}') 可用 / CPU $(nproc) 核"

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
P002="$PATCH_BASE/002.5.10_or_lower_use_android_abi_padding_for_posix_mqueue.patch"

log "打 kABI 补丁 001（SYSVIPC → ABI padding）"
APPLIED_SLOT=""
for slot in "$KABI_SLOT" 1_2_3 3_4_5 6_7_8; do
  [ -n "$APPLIED_SLOT" ] && break
  code=$(curl -fsSL -w '%{http_code}' "$PATCH_BASE/001.GKI-below-6.12-fix_sysvipc_kabi_${slot}.patch" \
          -o /tmp/001.patch 2>/dev/null || true)
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

log "打 kABI 补丁 002（POSIX_MQUEUE → ABI padding）"
curl -fsSL "$P002" -o /tmp/002.patch || die "002 补丁下载失败: $P002"
patch -p1 --forward < /tmp/002.patch || die "002 补丁应用失败（user.h 上下文不匹配）"

log "应用 002（POSIX_MQUEUE → ABI padding）"
patch -p1 --forward < /tmp/002.patch || die "002 补丁应用失败"

# 确认补丁真的落到了代码里
grep -q "ANDROID_KABI_USE" include/linux/sched.h \
  || die "001 补丁似乎没生效（include/linux/sched.h 里没有 ANDROID_KABI_USE）"
grep -q "ANDROID_KABI_USE" include/linux/sched/user.h \
  || die "002 补丁似乎没生效（include/linux/sched/user.h 里没有 ANDROID_KABI_USE）"
log "kABI 补丁已生效"

# --------------------------- 3. 工具链 --------------------------------------
# AOSP GKI 5.10 官方用 clang-r416183b（12.0.5），原厂内核也是它编的。
# clang-14 会在一堆 -Werror 上直接崩，所以优先 clang-12。
log "检查工具链"

if [ "$(id -u)" = "0" ]; then SUDO=""; else SUDO="sudo"; fi
ensure_pkgs() {
  local miss=()
  for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || miss+=("$p"); done
  [ ${#miss[@]} -eq 0 ] && return 0
  log "补装依赖：${miss[*]}"
  command -v apt-get >/dev/null 2>&1 || { warn "缺 ${miss[*]}，且没有 apt-get"; return 1; }
  $SUDO apt-get install -y -q "${miss[@]}" >/dev/null 2>&1 || { warn "安装 ${miss[*]} 失败"; return 1; }
}
# pahole（dwarves）是 CONFIG_DEBUG_INFO_BTF 必需，libelf-dev 是 objtool 必需
ensure_pkgs clang-12 lld-12 llvm-12 dwarves libelf-dev || true

if command -v clang-12 >/dev/null 2>&1 && command -v ld.lld-12 >/dev/null 2>&1; then
  CLI_CC=clang-12
  LLVM_ARG=-12
elif command -v clang >/dev/null 2>&1 && command -v ld.lld >/dev/null 2>&1; then
  CLI_CC=clang
  LLVM_ARG=1
  warn "没有 clang-12，退用系统 clang（版本偏新，可能触发 -Werror）"
else
  die "找不到 clang（workflow 应装 clang-12 lld-12）"
fi
command -v pahole >/dev/null 2>&1 || warn "没有 pahole，若 gki_defconfig 开了 DEBUG_INFO_BTF 会失败"
CLANG_VER="$($CLI_CC --version | head -1)"
log "工具链：$CLANG_VER （LLVM=$LLVM_ARG）"

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
    die "$s 被开启了 —— 这会破坏 kABI，原厂 608 个模块会拒绝加载，设备开机循环！必须从配置里去掉。代价只是 --cpus/--pids-limit 两个开关变灰。"
  else
    printf '  \033[32mOK\033[0m   %s 未开启（符合 kABI 安全要求）\n' "$s"
  fi
done

# 验证 LOCALVERSION（决定 vermagic 是否匹配原厂模块）
LV="$(grep '^CONFIG_LOCALVERSION=' "$OUT/.config" | cut -d'"' -f2)"
log "LOCALVERSION = $LV"
[ "$LV" = "$STOCK_LOCALVERSION" ] \
  || die "LOCALVERSION 不匹配原厂！期望: $STOCK_LOCALVERSION, 实际: $LV"

# --------------------------- 6. 编译 ----------------------------------------
log "编译 Image.gz（-j$JOBS）"
# 不传 LOCALVERSION=（会覆盖 CONFIG_LOCALVERSION）
# || true 让 make 失败不立即退出，下面检查 Image.gz 并输出错误
make ARCH=arm64 O="$OUT" \
  CC="$CLI_CC" LLVM="$LLVM_ARG" LLVM_IAS=1 \
  KCFLAGS="-D__ANDROID_COMMON_KERNEL__" \
  -j"$JOBS" Image.gz 2>&1 | tail -60 || true

if [ ! -f "$OUT/arch/arm64/boot/Image.gz" ]; then
  echo
  echo "======== build.log 最后 80 行 ========"
  tail -80 "$LOG" 2>/dev/null || true
  echo "======================================"
  die "Image.gz 没生成 —— 见上面的编译错误"
fi
log "Image.gz 生成成功"

# --------------------------- 7. 收集产物 ------------------------------------
rm -rf "$ART" && mkdir -p "$ART"
cp -f "$OUT/arch/arm64/boot/Image.gz" "$ART/Image.gz"

# 验证版本串（kernel.release 就是 vermagic 里的版本部分，必须与原厂一致）
KR="$(cat "$OUT/include/config/kernel.release" 2>/dev/null || true)"
[ -n "$KR" ] || KR="$(make -s ARCH=arm64 O="$OUT" kernelrelease 2>/dev/null || echo unknown)"
echo "  kernel.release: $KR"
STOCK_RELEASE="5.10.226-android12-9-00047-g4968e29b7f92-ab12786767"
if [ "$KR" = "$STOCK_RELEASE" ]; then
  log "版本串与原厂完全一致 ✓ 原厂 .ko 可直接加载"
else
  warn "版本串与原厂不一致（期望 $STOCK_RELEASE），原厂 .ko 会拒绝加载"
fi

{
  echo "kernel_version=$KVER"
  echo "kernel_release=$KR"
  echo "source=$KERNEL_REPO@$KERNEL_BRANCH"
  echo "pin=$PIN"
  echo "kabi_slot=$KABI_SLOT"
  echo "localversion=$LV"
  echo "clang=$CLANG_VER"
  echo "image_sha256=$(sha256sum "$ART/Image.gz" | cut -d' ' -f1)"
  echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$ART/BUILD-INFO.txt"

log "产物"
ls -lh "$ART"

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
  [ -e "$WORK/$f" ] && die "包根目录出现 $f，必须移除"
done

ZIP="$ART/xaga-gki-5.10.226-containers-$(date -u +%Y%m%d).zip"
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
ls -lh "$ZIP" "$ZIP.sha256"
echo
echo "============================================================"
echo " 内核：$KVER   LOCALVERSION：$LV"
echo " kABI 补丁：001($KABI_SLOT) + 002"
echo " 卡刷包：$ZIP"
echo " 只写 boot 分区，不碰 vendor_dlkm / vendor_boot"
echo " --cpus / --pids-limit 不可用（kABI 安全代价），其余功能正常"
echo "============================================================"
