### AnyKernel3 Ramdisk Mod Script — xaga GKI container kernel
### boot-only: 只替换 boot 内的 kernel，不碰 vendor_boot / vendor_dlkm

## osm0sis @ xda-developers

### AnyKernel setup
properties() { '
kernel.string=xaga GKI container kernel (5.10.226 + CGROUP_DEVICE/PIDS/USER_NS)
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=xaga
device.name2=xagain
device.name3=xagapro
device.name4=xagaproin
supported.versions=
supported.vendorpatchlevels=
'; } # end properties

### boot install
BLOCK=boot
IS_SLOT_DEVICE=1
RAMDISK_COMPRESSION=auto
PATCH_VBMETA_FLAG=auto
NO_MAGISK_CHECK=true

. tools/ak3-core.sh

ui_print "- [+] Flashing GKI container kernel (boot only)..."
ui_print "- [*] Image.gz replaces kernel in boot partition"
ui_print "- [*] vendor_dlkm / vendor_boot NOT touched — stock modules stay"

# split_boot 只拆分 boot 镜像，不解 ramdisk
# flash_boot 只重打包 kernel 并写入，不动 ramdisk / dtb / dtbo
split_boot

if [ -f "$SPLITIMG/ramdisk.cpio" ]; then
  unpack_ramdisk
  write_boot
else
  flash_boot
fi

ui_print "- [+] Done. Reboot and check:"
ui_print "- [*] cat /proc/cgroups  (should show devices + pids)"
ui_print "- [*] cat /proc/version   (should match 5.10.226-android12-9-...)"
## end boot install
