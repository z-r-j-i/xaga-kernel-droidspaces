# xaga GKI 容器内核编译套件

## 目标

给 Redmi Note 11T Pro (xaga) 的**澎湃OS 2** (5.10.226 GKI) 补齐容器配置
(`CGROUP_DEVICE` / `CGROUP_PIDS` / `USER_NS` 等)，编出可刷入的 boot-only 卡刷包。

## 为什么是 GKI boot-only

你的 `/proc/version` 确认原厂内核是 `5.10.226-android12-9` GKI 内核，
用 AOSP clang r416183b 编译。`/proc/cgroups` 显示缺 `devices` 和 `pids` 两个
容器必需的 cgroup 控制器——这就是 Droidspaces 跑不了的原因。

GKI 架构意味着：
- 内核 Image 在 boot 分区
- 608 个厂商模块在 vendor_dlkm 分区（独立于内核）
- 只要 vermagic 匹配（同版本 + 同 LOCALVERSION），原厂模块照常加载

所以本方案**只编 boot 里的 Image.gz，不碰 vendor_dlkm**——比连模块一起换安全得多。

## 文件

```
xaga-gki-containers/
├── build.sh                         # 主编译脚本（GitHub Actions 自动调用）
├── patches/
│   ├── containers.fragment          # 容器配置片段（补 GKI defconfig 缺的项）
│   └── anykernel/anykernel.sh       # boot-only AK3 脚本（不写 vendor_dlkm）
├── .github/workflows/build.yml      # 云编译 workflow
└── README.md
```

## 怎么跑

### 云编译（推荐，不需要 Linux）

1. 把这个目录里的**所有文件**（含 `.github/`）上传到你的 GitHub 仓库
   `z-r-j-i/xaga-kernel-droidspaces`：
   - 打开 https://github.com/z-r-j-i/xaga-kernel-droidspaces/upload/main
   - 解压 `xaga-gki-upload.zip`，把所有文件拖进去
   - **必须包含 `.github/workflows/build.yml`**
   - 点 Commit changes
2. 推送自动触发 Actions，约 30-50 分钟
3. 编完后在 Actions → 对应 run → Artifacts 下载 `xaga-gki-kernel`
4. 里面有 `xaga-gki-5.10.226-containers-日期.zip` —— 这就是卡刷包

### 本地编译（Linux）

```bash
git clone <你的仓库>
cd xaga-kernel-droidspaces
./build.sh
```

## 产物

- `xaga-gki-5.10.226-containers-日期.zip` —— AnyKernel3 boot-only 卡刷包
- 只写 `/dev/block/by-name/boot_{a,b}`，不碰 `vendor_dlkm` / `vendor_boot`
- 刷完原厂 608 个 `.ko` 照常加载（vermagic 完全匹配原厂）

## 刷入

KernelFlasher → 选 zip → 刷写到 boot_a（或 boot_b，看当前槽位）

刷完验证：
```sh
cat /proc/cgroups    # 应该出现 devices 和 pids
cat /proc/version    # 应该仍是 5.10.226-android12-9-00047-g4968e29b7f92-ab12786767
```

## 回滚

重新刷原厂 boot.img（从澎湃OS 2.0.12 官方包提取），或重刷完整 ROM。
因为只改了 boot 分区，回滚就是刷回原厂 boot。

## 关键设计决策

| 决策 | 原因 |
|---|---|
| 用 AOSP android12-5.10 源码 | 你的内核是 GKI 原厂，不需要 MTK 厂商代码（在模块里） |
| 锁定 5.10.226 | vermagic 必须与原厂完全一致，差一个 sublevel 模块就不加载 |
| clang r416183b | 原厂 `/proc/version` 写的就是这个版本，工具链不同可能有 ABI 差异 |
| `CONFIG_LOCALVERSION` 写死原厂串 | 这是 vermagic 的后半段，必须一字不差 |
| boot-only AK3 | GKI 内核不需要换模块，boot-only 是最安全的刷法 |
| 不加 CONFIG_KSU | 你的 SukiSU 是 LKM/APatch 运行时注入的，不依赖内核 CONFIG_KSU |
