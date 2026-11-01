#!/usr/bin/env bash
# ============================================================================
#  xaga GKI 容器内核编译脚本
#
#  目标：在 android12-5.10 GKI 内核 5.10.226 上补齐容器配置（CGROUP_DEVICE
#  等），编出 Image.gz，打 AnyKernel3 boot-only 卡刷包。
#
#  设计要点：
#  - 只编 GKI Image（boot 分区的内核），不碰 vendor_dlkm 的 608 个模块
#  - vermagic 与原厂完全一致（同 5.10.226 + 同 LOCALVERSION），原厂模块照常加载
#  - 用 clang r416183b（与原厂 /proc/version 记载的工具链一致）
#  - AnyKernel3 脚本只做 split_boot + flash_boot，不写 vendor_boot / vendor_dlkm
#
#  用法（GitHub Actions 自动调用，也可本地 Linux 跑）：
#    ./build.sh            完整编译 + 打包
#    ./build.sh --probe    只探测版本，不编译
# ============================================================================
set -euo pipefail

KERNEL_REPO="${KERNEL_REPO:-https://android.googlesource.com/kernel/common}"
KERNEL_BRANCH="${KERNEL_BRANCH:-android12-5.10}"
TARGET_SUBLEVEL="${TARGET_SUBLEVEL:-226}"
STOCK_LOCALVERSION="${STOCK_LOCALVERSION:--android12-9-00047-g4968e29b7f92-ab12786767}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAGMENT="$SCRIPT_DIR/patches/containers.fragment"
KERNEL_DIR="$SCRIPT_DIR/kernel"
OUT="$SCRIPT_DIR/out"
ART="$SCRIPT_DIR/artifacts"

JOBS="${JOBS:-$(nproc)}"
PROBE_ONLY=0
[ "${1:-}" = "--probe" ] && PROBE_ONLY=1

export ARCH=arm64

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m[FAIL] %s\033[0m\n' "$*" >&2; exit 1; }

# --------------------------- 1. 拉源码 --------------------------------------
if [ ! -d "$KERNEL_DIR/.git" ]; then
  log "克隆 $KERNEL_REPO (分支 $KERNEL_BRANCH, partial clone)"
  git clone --filter=blob:none --no-checkout -b "$KERNEL_BRANCH" \
    "$KERNEL_REPO" "$KERNEL_DIR" || die "克隆失败"
fi
cd "$KERNEL_DIR"
git fetch origin "$KERNEL_BRANCH" --filter=blob:none 2>/dev/null || true

# ----------------------- 2. 定位 5.10.226 -----------------------------------
log "在历史中搜索 5.10.${TARGET_SUBLEVEL}"

PINNED=""
for pattern in "^Linux 5\.10\.${TARGET_SUBLEVEL}$" \
               "5\.10\.${TARGET_SUBLEVEL}" \
               "v5.10.${TARGET_SUBLEVEL}"; do
  PINNED="$(git log --all --oneline --grep="$pattern" --format=%H -n1 2>/dev/null || true)"
  [ -n "$PINNED" ] && break
done

if [ -n "$PINNED" ]; then
  log "命中 5.10.${TARGET_SUBLEVEL} → $PINNED"
  git checkout -q "$PINNED"
else
  # 列出最近的 stable 合并点供诊断
  echo "  未找到 5.10.${TARGET_SUBLEVEL}，最近的 stable 合并点："
  git log --all --oneline --grep="^Linux 5\.10\." -n10 2>/dev/null | head -10 | sed 's/^/    /'
  die "找不到 5.10.${TARGET_SUBLEVEL} 的提交点。检查 KERNEL_REPO / KERNEL_BRANCH。"
fi

KVER="$(make -s kernelversion 2>/dev/null || true)"
[ -n "$KVER" ] || KVER="$(awk '/^VERSION =|^PATCHLEVEL =|^SUBLEVEL =/{printf "%s.",$3}' Makefile | sed 's/\.$//')"
log "源码版本：$KVER"

if [ "$PROBE_ONLY" = "1" ]; then
  echo "PROBE_RESULT version=$KVER pin=$PINNED"
  exit 0
fi

# --------------------------- 3. 准备 clang ----------------------------------
CLANG_DIR="$SCRIPT_DIR/.clang"
if [ ! -f "$CLANG_DIR/bin/clang" ]; then
  log "下载 clang r416183b（与原厂工具链一致）"
  mkdir -p "$CLANG_DIR"
  URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/master/clang-r416183b.tar.gz"
  curl -fsSL "$URL" -o /tmp/clang.tar.gz || die "clang 下载失败"
  tar -xzf /tmp/clang.tar.gz -C "$CLANG_DIR"
  rm -f /tmp/clang.tar.gz
fi
export PATH="$CLANG_DIR/bin:$PATH"
CLANG_VER="$(clang --version | head -1)"
log "工具链：$CLANG_VER"

# 验证是 clang 12（r416183b）
echo "$CLANG_VER" | grep -q "clang version 12" \
  || warn "警告：clang 版本不是 12，vermagic 可能不匹配"

# --------------------------- 4. 生成配置 ------------------------------------
log "合并 GKI defconfig + 容器配置片段"
rm -rf "$OUT" && mkdir -p "$OUT"

./scripts/kconfig/merge_config.sh -m \
  arch/arm64/configs/gki_defconfig \
  "$FRAGMENT" 2>&1 | tail -5

# 抑制 setlocalversion（不让 git 信息追加到版本串）
touch .scmversion

make ARCH=arm64 O="$OUT" olddefconfig >/dev/null 2>&1

# 校验关键配置
log "校验关键配置"
MISSING=""
for s in CONFIG_CGROUP_DEVICE CONFIG_CGROUP_PIDS CONFIG_USER_NS \
         CONFIG_VETH CONFIG_BRIDGE CONFIG_OVERLAY_FS CONFIG_MEMCG_SWAP \
         CONFIG_CGROUPS CONFIG_NAMESPACES CONFIG_MEMCG; do
  if grep -qx "$s=y" "$OUT/.config"; then
    printf '  \033[32mOK\033[0m   %s\n' "$s"
  else
    printf '  \033[31mMISS\033[0m %s\n' "$s"; MISSING="$MISSING $s"
  fi
done
[ -z "$MISSING" ] || die "关键配置缺失:$MISSING"

# 验证 LOCALVERSION
LV="$(grep '^CONFIG_LOCALVERSION=' "$OUT/.config" | cut -d'"' -f2)"
log "LOCALVERSION = $LV"
[ "$LV" = "$STOCK_LOCALVERSION" ] \
  || die "LOCALVERSION 不匹配原厂！期望: $STOCK_LOCALVERSION, 实际: $LV"

# --------------------------- 5. 编译 ----------------------------------------
log "编译 Image.gz（-j$JOBS）"
make ARCH=arm64 O="$OUT" \
  CC=clang HOSTCC=clang LD=ld.lld LLVM=1 LLVM_IAS=1 \
  KCFLAGS="-D__ANDROID_COMMON_KERNEL__" \
  LOCALVERSION= \
  -j"$JOBS" Image.gz 2>&1 | tail -30

[ -f "$OUT/arch/arm64/boot/Image.gz" ] || die "Image.gz 没生成"

# --------------------------- 6. 收集产物 ------------------------------------
rm -rf "$ART" && mkdir -p "$ART"
cp -f "$OUT/arch/arm64/boot/Image.gz" "$ART/Image.gz"

# 验证版本串
VMLINUX_VER="$(strings "$OUT/arch/arm64/boot/Image.gz" 2>/dev/null \
  | grep -m1 'Linux version 5\.10\.')" || true
if [ -n "$VMLINUX_VER" ]; then
  echo "$VMLINUX_VER" | grep -q "5.10.226-android12-9-00047-g4968e29b7f92-ab12786767" \
    && log "版本串匹配原厂 ✓" \
    || warn "版本串不匹配原厂: $VMLINUX_VER"
fi

{
  echo "kernel_version=$KVER"
  echo "source=$KERNEL_REPO@$KERNEL_BRANCH"
  echo "pin=$PINNED"
  echo "localversion=$LV"
  echo "image_sha256=$(sha256sum "$ART/Image.gz" | cut -d' ' -f1)"
  echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$ART/BUILD-INFO.txt"

log "产物"
ls -lh "$ART"

# --------------------------- 7. 打 AnyKernel3 卡刷包 ------------------------
log "打 AnyKernel3 boot-only 包"
AK3_REPO="${AK3_REPO:-https://github.com/osm0sis/AnyKernel3}"
AK3_REF="${AK3_REF:-master}"
WORK="$SCRIPT_DIR/.ak3"
rm -rf "$WORK" 2>/dev/null || true
git clone --depth=1 -b "$AK3_REF" "$AK3_REPO" "$WORK" >/dev/null 2>&1 \
  || die "AnyKernel3 克隆失败"

# 清理模板占位
rm -rf "$WORK/.git" "$WORK/.github" "$WORK/README.md" \
       "$WORK/modules" "$WORK/patch" "$WORK/ramdisk" 2>/dev/null || true

# 放入定制脚本和内核
cp -f "$SCRIPT_DIR/patches/anykernel/anykernel.sh" "$WORK/anykernel.sh"
cp -f "$ART/Image.gz" "$WORK/Image.gz"

# 防呆
[ -f "$WORK/tools/ak3-core.sh" ] || die "缺少 tools/ak3-core.sh"
[ -f "$WORK/tools/magiskboot" ]  || die "缺少 tools/magiskboot"
grep -qx 'device.name1=xaga' "$WORK/anykernel.sh" || die "devicecheck 未指向 xaga"
for f in dtb dtbo.img Image Image-dtb; do
  [ -e "$WORK/$f" ] && die "包根目录出现 $f，必须移除"
done

ZIP="$ART/xaga-gki-5.10.226-containers-$(date -u +%Y%m%d).zip"
rm -f "$ZIP"
cd "$WORK"
zip -r9 -q "$ZIP" anykernel.sh Image.gz tools META-INF \
  && [ -f "$WORK/LICENSE" ] && zip -q9 "$ZIP" LICENSE || true
cd "$SCRIPT_DIR"

# 校验包结构
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
echo " 卡刷包：$ZIP"
echo " 只写 boot 分区，不碰 vendor_dlkm / vendor_boot"
echo " 原厂模块照常加载（vermagic 匹配）"
echo "============================================================"
