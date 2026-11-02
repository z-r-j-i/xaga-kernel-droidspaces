### AnyKernel3 Ramdisk Mod Script — xaga GKI container kernel
### boot-only: 只替换 boot 内的 kernel，不碰 vendor_boot / vendor_dlkm

## osm0sis @ xda-developers

### AnyKernel setup
properties() { '
kernel.string=xaga GKI container kernel 5.10.226 (Droidspaces / kABI-patched)
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

ui_print "- [+] Flashing GKI container kernel (boot only)"
ui_print "- [*] Image.gz replaces the kernel inside boot"
ui_print "- [*] ramdisk / dtb / vendor_boot / vendor_dlkm untouched"

# split_boot 只拆分 boot，不解 ramdisk；flash_boot 内部会 write_boot 重打包。
# 不用 unpack_ramdisk + write_boot：那会重建 ramdisk，刷完可能丢掉原厂 ramdisk 里的东西。
split_boot
flash_boot

ui_print "- [+] Done. After reboot verify:"
ui_print "- [*] cat /proc/version  -> 5.10.226-android12-9-00047-..."
ui_print "- [*] open Droidspaces, run its environment check"
## end boot install
