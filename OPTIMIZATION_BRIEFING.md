# RG34XX SP Andr36oid (v43 / v44) — Performance-First Optimization & Debloat Briefing

## 1. Executive Summary & Architectural Audit

By unpacking and inspecting the partition images of the **v43 complete release (`RG34XXSP-Andr36oid-Android11-v43-complete.img.gz`)**, the **v44 adaptive RAM patch (`RG34XXSP-v44-vendor.img`)**, and the upstream **Andr36oid common device tree (`andr36oid/android_device_gameconsole_common`)**, we mapped the exact architecture of this port.

The current build is a **three-way hybrid**:

| Partition(s) | Offset / Size | Origin / Base | Key Findings |
| :--- | :--- | :--- | :--- |
| **`p1` (`BOOTLOG`)** | `36 MiB` / `128 MiB` | FAT32 boot/log partition | Used by first-stage `init` boot logger and storage resize reports. |
| **`p2` (`resources`)** | `164 MiB` / `32 MiB` | FAT16 (`Volumn`) | Holds `/portassets/EARLY.CPI` (13.7 MB first-stage Android ramdisk archive). |
| **`p3` (`env`)** | `196 MiB` / `16 MiB` | U-Boot environment | Sets `loglevel=7`, `earlyprintk=sunxi-uart`, `cma=64M`, `enforcing=0`. |
| **`p4` (`boot`)** | `212 MiB` / `64 MiB` | Anbernic stock Linux `4.9.170` (`gcc 5.3.1`) + custom native handoff `/init` | Has `sdcardfs`, `f2fs`, `zsmalloc` built-in, but **lacks `CONFIG_ZRAM`** built-in. Custom `/init` runs a persistent boot logger (`v7`). |
| **`p5` (`system`)** | `276 MiB` / `2048 MiB` | Andr36oid R36S (`rk3326`) LineageOS 18.1 (`userdebug`, Oct 24 build) | Ships ~35 R36S/Rockchip-specific apps, `userdebug` tracing/profiling daemons, and misses post-Oct-24 upstream Andr36oid RAM trims. |
| **`p6` (`vendor`)** | `2324 MiB` / `512 MiB` | well83 T95 H616 (`apollo-t95axp806`) Android 12 TV Box donor + `rg34xx-*` scripts | Replaces `init.rk30board.rc` with a 58-line `init.sun50iw9p1.rc` that **dropped `sdcardfs`, VM, THP, CPU governor, and SD I/O tunings**, while running continuous diagnostic polling loops. |
| **`p7` (`product`)** | `2836 MiB` / `512 MiB` | Andr36oid R36S LineageOS 18.1 `/product` | Ships `ThoriumWebView`, `SettingsIntelligence`, and **78 unused theme/cutout/navbar RRO overlay APKs**. |
| **`p8` (`userdata`)** | `3348 MiB` / `8 GiB+` | `ext4` `/data` partition | Expanded on first boot via `/vendor/bin/rg34xx-grow-storage.sh`. |

---

## 2. Priority 1: Critical Kernel, Storage & Runtime Fixes (Highest Performance Impact)

These issues are actively costing CPU cycles, RAM, and microSD I/O bandwidth during both boot and gameplay in v43/v44:

### 2.1. Re-Enable Kernel `sdcardfs` Instead of Userspace FUSE (`MediaProvider`)
* **The Bug:** In `/system/etc/init/hw/init.rc`, Android 11 sets `persist.sys.fuse=true` during `post-fs-data`. On the R36S, `/vendor/etc/init/hw/init.rk30board.rc` overrode this with `setprop persist.sys.fuse false` and `setprop persist.sys.fflag.override.settings_fuse false` so ROM reads and save-state writes use kernel `sdcardfs`. When `/vendor/etc/init/hw/init.sun50iw9p1.rc` was written from scratch for the RG34XX SP, **those two properties were omitted**.
* **Verification:** Binary inspection of the `4.9.170` kernel in `p4_boot.img` confirms **`sdcardfs` is compiled into the kernel** (`49` symbol occurrences). Right now, every ROM read and emulator save goes through userspace FUSE and the Java `MediaProvider` process.
* **The Fix:** Add to `on post-fs-data` in `/vendor/etc/init/hw/init.sun50iw9p1.rc`:
  ```ini
  on post-fs-data
      setprop persist.sys.fuse false
      setprop persist.sys.fflag.override.settings_fuse false
  ```

### 2.2. Kill `rg34xx-power-usb-report.sh` Input-Sniffing & Diagnostic Polling Loops
* **The Bug:** `/vendor/etc/init/rg34xx-owner-setup.rc` launches three bring-up diagnostic scripts on every boot:
  1. **`/vendor/bin/rg34xx-power-usb-report.sh`**: Spawns `timeout 300 getevent -lt 2>/dev/null | while IFS= read -r line` in the background for the **first 5 minutes (300 seconds) of every boot**. Every single D-pad press, button press, and analog stick movement wakes up `getevent` and a shell `while read` loop just to filter for `*KEY_POWER*`! Simultaneously, it runs a 24-iteration loop (`sleep 10` × 24) invoking `settings get` and `dumpsys window policy`.
  2. **`/vendor/bin/rg34xx-cpu-report.sh`**: Reads sysfs cpufreq tables and sleeps 3×10s spamming error-level logcat (`RG26_CPU`).
  3. **`/vendor/bin/rg34xx-hardware-v27.sh`**: After loading `8821cs.ko`, it polls `sys.boot_completed` in a loop and runs `dmesg | grep ...` and `dumpsys wifi | head -100` into `/data/local/tmp/rg34xx-hardware-v27.log`.
* **The Fix:**
  * Remove `rg34xx-power-usb-report` and `rg34xx-cpu-report` from `/vendor/etc/init/rg34xx-owner-setup.rc`.
  * Trim `rg34xx-hardware-v27.sh` down to only the `insmod /vendor/lib/modules/8821cs.ko ifname=wlan0 if2name=p2p0` and `setprop wifi.interface wlan0` steps (or move `insmod` directly into `init.sun50iw9p1.rc` on `boot`).
  * Make `rg34xx-owner-setup.sh` fast-exit on line 1 when `$(getprop persist.andr36oid.setup_done) = 1` instead of polling `cmd package path android` and spawning `settings` subshells on every subsequent boot.

### 2.3. Disable `userdebug` Kernel Scheduler Profiling (`sched_schedstats`)
* **The Bug:** Because `/system` is a `userdebug` build, `/system/etc/init/atrace.rc` executes `write /proc/sys/kernel/sched_schedstats 1` on `late-init` and `chmod 0666`s over 100 `/sys/kernel/debug/tracing` nodes. `sched_schedstats=1` adds latency accounting to every kernel scheduler context switch.
* **The Fix:** Override in `on boot` inside `/vendor/etc/init/hw/init.sun50iw9p1.rc`:
  ```ini
  on boot
      write /proc/sys/kernel/sched_schedstats 0
      write /proc/sys/kernel/printk_devkmsg off
      write /proc/sys/kernel/randomize_va_space 0
      write /sys/kernel/debug/tracing/tracing_on 0
  ```

### 2.4. Restore Missing VM, THP, CPU Governor & MicroSD I/O Queue Tunings in `init.sun50iw9p1.rc`
* **The Bug:** `init.sun50iw9p1.rc` replaced `init.rk30board.rc` and does not import `init.common.rc` or `init.ram.rc`. As a result, the RG34XX SP has **no microSD block queue tuning, no Transparent HugePage (THP) disablement, no boot governor boost, and no cpuset partitioning**.
* **The Fix:** Add the following block to `/vendor/etc/init/hw/init.sun50iw9p1.rc`:
  ```ini
  on early-init
      # Boost CPU to max clock during boot
      write /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor performance

  on init
      # Disable Transparent Huge Pages (prevents khugepaged compaction stalls & high min_free_kbytes)
      write /sys/kernel/mm/transparent_hugepage/enabled never
      write /proc/sys/vm/min_free_kbytes 8192
      write /proc/sys/vm/page-cluster 0
      write /proc/sys/vm/compact_unevictable_allowed 0
      write /proc/sys/vm/oom_dump_tasks 0
      write /proc/sys/vm/dirty_background_ratio 5
      write /proc/sys/vm/dirty_ratio 15
      write /proc/sys/vm/vfs_cache_pressure 100

  on boot
      # MicroSD (TF1 & TF2) I/O queue optimization — disable iostats & entropy overhead
      write /sys/block/mmcblk0/queue/iostats 0
      write /sys/block/mmcblk0/queue/add_random 0
      write /sys/block/mmcblk0/queue/rotational 0
      write /sys/block/mmcblk0/queue/read_ahead_kb 512
      write /sys/block/mmcblk0/queue/nr_requests 256
      write /sys/block/mmcblk1/queue/iostats 0
      write /sys/block/mmcblk1/queue/add_random 0
      write /sys/block/mmcblk1/queue/rotational 0
      write /sys/block/mmcblk1/queue/read_ahead_kb 512

      # Partition cpusets for quad-core Cortex-A53
      write /dev/cpuset/top-app/cpus 0-3
      write /dev/cpuset/foreground/cpus 0-3
      write /dev/cpuset/background/cpus 0
      write /dev/cpuset/system-background/cpus 0-1
      write /dev/cpuset/restricted/cpus 0-1

  on property:sys.boot_completed=1
      # Return from boot performance governor to schedutil/interactive with fast ramp-up
      write /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor schedutil
      write /sys/devices/system/cpu/cpufreq/policy0/schedutil/up_rate_limit_us 1000
      write /sys/devices/system/cpu/cpufreq/policy0/schedutil/down_rate_limit_us 10000
  ```

### 2.5. Fix Bionic & ART CPU Variant in `/vendor/build.prop` (`generic` $\rightarrow$ `cortex-a53`)
* **The Bug:** `/vendor/build.prop` (inherited from the T95 donor) sets `generic` for both Bionic and Dalvik/ART instruction set variants:
  ```ini
  ro.bionic.cpu_variant=generic
  ro.bionic.2nd_cpu_variant=generic
  dalvik.vm.isa.arm64.variant=generic
  dalvik.vm.isa.arm.variant=generic
  ```
* **The Fix:** Change all four to `cortex-a53` in `/vendor/build.prop` so ART's `dex2oat` and JIT emit instructions scheduled for the Allwinner H700's in-order Cortex-A53 pipeline:
  ```ini
  ro.bionic.cpu_variant=cortex-a53
  ro.bionic.2nd_cpu_variant=cortex-a53
  dalvik.vm.isa.arm64.variant=cortex-a53
  dalvik.vm.isa.arm64.features=default
  dalvik.vm.isa.arm.variant=cortex-a53
  dalvik.vm.isa.arm.features=default
  ```

### 2.6. Disable SurfaceFlinger Background Blur & Power Menu Graph Polling
* **The Bug:**
  1. `ro.surface_flinger.supports_background_blur=1` is enabled in `device.mk`, allowing blur passes on a Mali-G31 MP2 GPU.
  2. `ro.andr36oid.power_menu_stats=true` in `/product/build.prop` makes `system_server` continuously sample CPU load, temperature, battery, and RAM to draw 10-minute rolling history graphs in the power menu.
* **The Fix:** Add to `/vendor/build.prop` or `/product/build.prop`:
  ```ini
  ro.surface_flinger.supports_background_blur=0
  disable_blurs=true
  ro.andr36oid.power_menu_stats=false
  persist.sys.power_menu_stats=0
  ```

### 2.7. Backport `andr36oid-boot-trim.sh` (+60 MB Free RAM After Boot)
* **The Bug:** The `p5_system.img` in v43 was built on Oct 24, 2026, just before upstream `andr36oid` added `andr36oid-boot-trim.sh` (which kills ~20 idle `BOOT_COMPLETED` receiver apps 60 seconds after boot, reclaiming ~60 MB RAM on 1 GB consoles).
* **The Fix:** Copy `upstream/android_device_gameconsole_common/PortMaster/broker/andr36oid-boot-trim.sh` to `/vendor/bin/rg34xx-boot-trim.sh` and trigger it on `sys.boot_completed=1` in `init.sun50iw9p1.rc`:
  ```sh
  #!/system/bin/sh
  sleep 45
  [ "$(getprop init.svc.zygote)" = running ] || exit 0
  timeout -k 1 3 /system/bin/cmd activity kill-all
  ```

### 2.8. Unlock ZRAM via Loadable `zram.ko` Module
* **Finding:** While `p4_boot.img` (`Linux 4.9.170`) does not have `CONFIG_ZRAM=y` built in, binary inspection shows **`zsmalloc` (`CONFIG_ZSMALLOC=y`) IS compiled into the kernel** (`10` symbol occurrences).
* **Opportunity:** Because `zsmalloc` is already in the kernel, you do not even need to reflash the kernel image to get ZRAM—compiling `zram.ko` (and `lz4_compress.ko` if not built-in) against the Allwinner `linux-4.9.170` tree with matching vermagic (`4.9.170 SMP preempt mod_unload aarch64`) allows loading `insmod /vendor/lib/modules/zram.ko` in `init.sun50iw9p1.rc` and enabling a 512 MB ZRAM swap device.

---

## 3. Priority 2: Pairing Android with a Lightweight Frontend

### Why Daijishō Hurts Performance on 1 GB RAM
1. **Heavy RAM Footprint (110–160 MB RSS):** Daijishō (`com.magneticchen.daijishou`, 17.9 MB APK) uses a heavy Room SQLite database, Coil/Glide image caches, background metadata scrapers, and complex view trees. On a 1 GB H700 without ZRAM, launching a demanding emulator (PPSSPP, Flycast, DuckStation, Mupen64Plus) immediately forces `lmkd` to kill Daijishō, causing a multi-second cold reload every time you exit a game.
2. **Duplicated Storage & First-Boot Install Overhead:** In v43/v44, `Daijisho.apk` (17.9 MB), `Andr36oidLauncher.apk` (4.9 MB), and `GamepadKeyboard.apk` (98 KB) exist **both** in `/system/app/` **and** inside `/vendor/etc/rg34xx/` (23 MB wasted in `/vendor`), and `/vendor/bin/rg34xx-default-home.sh` waits 20+ seconds on first boot to run `pm install` on them.

### Recommended Lightweight Frontend Options

| Frontend | Typical RAM (RSS) | APK Size | Pros / Trade-Offs |
| :--- | :--- | :--- | :--- |
| **1. Built-in `Andr36oidLauncher` (`SproutLauncher` fork)** *(Immediate Drop-In)* | **~28–40 MB** | **4.9 MB** | **Already preinstalled & AOT-compiled (`speed-profile`) in `/system/app/Andr36oidLauncher`!** Controller-native grid, supports ROM folders (`ro.andr36oid.rom_folders=true`), zero background scraper services. |
| **2. Pegasus Frontend (Android ARM64)** | **~35–50 MB** | **~12 MB** | Native C++/Qt frontend; reads flat `metadata.pegasus.txt` or EmulationStation `gamelist.xml` files directly from SD card with zero Java GC pressure and instant theme rendering. |
| **3. Beacon Game Launcher / PlainLauncher / Custom MinUI-Style Home** | **~15–30 MB** | **< 5 MB** | Ultra-minimal list/grid launchers with near-zero idle memory footprint; stays resident in RAM during gameplay so exiting a game is instantaneous. |
| **4. ES-DE (EmulationStation Desktop Edition)** | **~85–120 MB** | **~35 MB** | Best visual EmulationStation experience on Android, but uses SDL2 + OpenGL texture caches (heavier than `Andr36oidLauncher` or Pegasus on 1 GB RAM). |

### How to Switch the Default Frontend Cleanly in Your Fork
1. **Delete `/vendor/etc/rg34xx/Daijisho.apk`, `Andr36oidLauncher.apk`, and `GamepadKeyboard.apk`** (saves 23 MB on `/vendor`; the apps are already in `/system/app/`).
2. **Delete `/system/app/Daijishou`** from `p5_system.img`.
3. **Update `/vendor/bin/rg34xx-default-home.sh`** to set `org.andr36oid.launcher/games.indiegesindel.sproutlauncher.MainActivity` (or your chosen lightweight launcher's component) without the 20-second `sleep` and redundant `pm install` loops:
   ```sh
   #!/system/bin/sh
   marker=/data/local/tmp/rg34xx-home.configured
   [ -f "$marker" ] && exit 0
   component="org.andr36oid.launcher/games.indiegesindel.sproutlauncher.MainActivity"
   cmd package set-home-activity --user 0 "$component" && printf '%s\n' "$component" > "$marker"
   ```
4. **Trigger `rg34xx-default-home` on `property:sys.boot_completed=1`** (in `/vendor/etc/init/rg34xx-default-home.rc`) instead of `on boot` so it never polls `cmd package` while `SystemServer` is still starting up.

---

## 4. Priority 3: Unnecessary Services, HALs, Permissions & APK Debloat Matrix

### 4.1. Vendor Init Services & HALs to Disable (`/vendor/etc/init/`)

| File in `/vendor/etc/init/` | Service Name | Why It Should Be Removed / Disabled |
| :--- | :--- | :--- |
| `rg34xx-owner-setup.rc` | `rg34xx-power-usb-report` | Runs `getevent -lt` for 300s on every boot + 24×10s `dumpsys` polling loop. |
| `rg34xx-owner-setup.rc` | `rg34xx-cpu-report` | Boot-time diagnostic script that sleeps 30s and spams error logs. |
| `android.hardware.security.keymint-service.rc` | `vendor.keymint-default` | Leftover Android 12 KeyMint HAL from T95 donor; Android 11 uses `vendor.keymaster-3-0` (`android.hardware.keymaster@3.0-service.rc`). Currently **both** start in `class early_hal`! |
| `rebootescrow-default.rc` | `vendor.rebootescrow-default` | Points to non-existent `/dev/block/pmem0`; completely unused on RG34XX SP. |
| `boringssl_self_test.rc` | `boringssl_self_test32/64_vendor` | Runs crypto self-tests on `early-init` on every boot. |

### 4.2. Clean Up `/vendor/etc/vintf/manifest.xml` & `/vendor/etc/permissions/`
* **In `/vendor/etc/vintf/manifest.xml`:**
  * Remove `<hal><name>android.hardware.camera.provider</name>...</hal>` and `<hal><name>android.hardware.tv.cec</name>...</hal>`. Their `.rc` files were renamed to `.disabled`, but because they are still listed in `vintf/manifest.xml`, Android's `CameraService` and `HdmiControlService` still query `hwservicemanager` for them!
* **In `/vendor/etc/permissions/`:**
  * **Delete donor XMLs that start unused `system_server` managers:**
    * `android.hardware.camera.external.xml`, `android.hardware.camera.flash-autofocus.xml`, `android.hardware.camera.front.xml`, `id.hardware.camera.xml`
    * `android.software.backup.xml`
    * `android.software.ipsec_tunnels.xml`
    * `android.software.pppoe.xml`
    * `android.software.verified_boot.xml`
    * `android.hardware.reboot_escrow.xml`
    * `android.hardware.wifi.passpoint.xml`, `android.hardware.wifi.direct.xml`
    * `android.hardware.ethernet.xml`
    * `android.hardware.usb.accessory.xml`
  * **Copy `upstream/android_device_gameconsole_common/configs/permissions/gameconsole_unavailable_features.xml` into `/vendor/etc/permissions/`** (and add `<unavailable-feature name="android.software.autofill" />` and `<unavailable-feature name="android.software.live_wallpaper" />`) so `SystemServer` skips starting `BackupManagerService`, `PrintManagerService`, `CameraService`, `PictureInPicture`, and `AutofillManagerService`.

### 4.3. System Init Daemons to Disable (`/system/etc/init/`)
On a dedicated gaming handheld, these `userdebug` and enterprise daemons in `/system/etc/init/` should be disabled (`override` with `disabled` or remove `.rc`):
* **`incidentd.rc`** (`incidentd` runs in `class main` resident in RAM)
* **`perfetto.rc`**, **`traced_perf.rc`**, **`heapprofd.rc`**, **`iorapd.rc`** (tracing/profiling daemons)
* **`atrace.rc`**, **`atrace_userdebug.rc`**, **`bootstat.rc`**, **`bootstat-debug.rc`**, **`dumpstate.rc`**
* **`racoon.rc`** (IPsec VPN daemon), **`mdnsd.rc`** (mDNS multicast daemon)
* **`gsid.rc`**, **`lpdumpd.rc`**, **`uncrypt.rc`**, **`recovery-persist.rc`**, **`lineage-updates.rc`**, **`lineage-ssh.rc`**
* **`lineage-iosched.rc`** (mounts `/dev/bfqio` cgroup and runs `restorecon` on nonexistent `/sys/block/sda`, `sde`, `dm-0`, whereas the 4.9.170 kernel does not even have BFQ compiled in—verified `bfq: 0 occurrences`).

### 4.4. Preinstalled System & Product APKs to Remove (`/system`, `/system_ext`, `/product`)

#### A. Rockchip / R36S Hardware-Specific Apps in `/system/app/` (Non-Functional on Allwinner H700)
These apps were built for the R36S (`rk3326` + `odroidgo3-joypad`) and try to read/write Rockchip sysfs nodes (`/sys/devices/platform/odroidgo3-joypad/*`, `/sys/module/rockchipdrm/*`, `/sys/module/rockchip_pm_config/*`, `/sys/class/leds/keros::ambient/*`) that do not exist on the RG34XX SP:
* `RgbLights`, `StatusLight`
* `BlackFrameInsertion` (requires `rockchipdrm` BFI parameter)
* `DeepSleep` (requires `rockchip_pm_config`)
* `EmmcTool` (RG34XX SP has no internal eMMC)
* `CpuOverclock`, `KernelTweaks` (targeted at `rk3326` DMC/GPU/CPU nodes)
* `StickCalibration` (writes to `odroidgo3-joypad`)
* `TouchMapper` (RG34XX SP has no touchscreen; maps touch-only games via virtual touch)
* `SmoothnessTest`, `CardCheck`, `ProblemReport`, `BiosCheck`, `SaveBackup`, `Andr36oidPlayTime`, `Andr36oidGuide`, `Andr36oidCredits`, `ConsoleLook`

#### B. Unused AOSP / Lineage Apps in `/system/app`, `/system/priv-app`, `/system_ext/priv-app`, `/product`
* ** launch/UI bloat:** `Daijishou` (if using `Andr36oidLauncher` or Pegasus), `ThemePicker`, `WallpaperCropper`, `WallpaperBackup`, `Andr36oidWallpapers`, `Gallery2`, `LineageSetupWizard`, `LineageParts`
* **Telephony / Enterprise / Network bloat:** `ContactsProvider`, `TelephonyProvider`, `BluetoothMidiService`, `VpnDialogs`, `PacProcessor`, `ProxyHandler`, `CertInstaller`, `KeyChain`, `StatementService`, `CompanionDeviceManager`, `FusedLocation`, `CtsShimPrebuilt`, `CtsShimPrivPrebuilt`
* **Heavy Product Apps:**
  * `/product/priv-app/SettingsIntelligence` (indexes settings in background SQLite DB; consumes 30–50 MB RAM when opening Settings)
  * `/product/app/ThoriumWebView` (unless you use an app/frontend requiring login WebViews, removing or keeping `ro.config.webview_zygote_lazy=true` prevents WebView Zygote from ever starting)
* **78 RRO Overlay APKs in `/product/overlay/`:**
  * Remove all 5 `DisplayCutoutEmulation*` APKs, all 6 `NavigationBarMode*` APKs, all 32 `IconPack*` APKs, all 7 `IconShape*` APKs, and the 28 unused `AccentColor*` / `Lineage*Accent` / `Andr36oid*Accent` APKs. Reducing `/product/overlay/` from 78 APKs to 0–2 APKs significantly speeds up `PackageManagerService` and `idmap2d` on every boot.

### 4.5. Single 64-Bit Zygote (`ro.zygote=zygote64`) Option (+45–60 MB Free RAM)
* Currently, `/vendor/build.prop` sets `ro.zygote=zygote64_32`, which starts both `zygote64` (`app_process64`) and `zygote_secondary` (`app_process32`).
* If your emulator suite is 64-bit (`arm64-v8a` — RetroArch AArch64, PPSSPP, DuckStation, Mupen64Plus-FZ, Flycast, Redream, MelonDS, Drastic 64-bit), changing `ro.zygote=zygote64` in `/vendor/build.prop` and removing 32-bit `abilist32` eliminates the entire 32-bit Zygote process and all duplicated 32-bit preloaded framework classes/resources, saving **45–60 MB of permanent RAM**.

---

## 5. Completed v45 Build & Verification Results

All recommended optimizations (`Andr36oidLauncher` default frontend, 64-bit-only `zygote64`, Option 1 `rg34xx-lid-sleep.sh` Clamshell Deep-Sleep + Radio Cut Manager, Cortex-A53 targets, kernel `sdcardfs`, VM/THP/MMC queue tuning, removal of input-sniffing/diagnostic loops, and full service/HAL/APK/overlay debloating while preserving lazy-loaded `ThoriumWebView`) have been built and verified in this repository:

| Output Artifact | Size | SHA-256 Checksum | Verification |
| :--- | :--- | :--- | :--- |
| `releases/RG34XXSP-Andr36oid-Android11-v45-perf-complete.img.gz` | `892.02 MiB` (`-147.2 MiB` vs v43) | `55ec71e6f7ec92c9f869796f77f0bd800f290a41cc887676c6049f01daa890d8` | GPT CRC32 + GZIP + V48 video fix merged (`1,364 MB` free RAM at idle) |
| `releases/RG34XXSP-Andr36oid-Android11-v45-perf-complete.img` | `11.27 GiB` (`12,101,615,616 B`) | `9f7e4c086876018f1493ffd0d1fce3c2fc7234fa39495851a498dbfaae584588` | Primary & Backup GPT verified |
| `releases/v45-perf-partitions/RG34XXSP-v45-system.img` | `2048 MiB` (`516 MiB` free, `72%` used) | `8d1e6032368126353f07bbbfce9dbed1e4b74428f900800fd2a40167b8d4af49` | `e2fsck -f -n` + SELinux verified |
| `releases/v45-perf-partitions/RG34XXSP-v45-vendor.img` | `512 MiB` (`349 MiB` free, `31%` used) | `f1ace680605db47ed1f451ae191fbe26417c100e6f72dbb306b0dc024ead7056` | `e2fsck -f -n` + `sh -n` + V48 `rg34xx-hidl-memory` + `keymint` fix verified |
| `releases/v45-perf-partitions/RG34XXSP-v45-product.img` | `512 MiB` (`176 MiB` free, `62%` used) | `229e5a4bf274e422bed9dec5ecfdf328426b13cf1d3bfce68b937a3f4ee8709b` | `e2fsck -f -n` + SELinux verified |

### Build & Verification Scripts
* [build_v45_partitions.sh](scripts/build_v45_partitions.sh)
* [verify_and_zerofill_v45.sh](scripts/verify_and_zerofill_v45.sh)
* [assemble_complete_image.py](scripts/assemble_complete_image.py)
* [compress_and_verify_image.py](scripts/compress_and_verify_image.py)
* [Update-Card-v45.ps1](scripts/card-updaters/Update-Card-v45.ps1) & [UPDATE-CARD-V45.cmd](scripts/card-updaters/UPDATE-CARD-V45.cmd)
* [RG34XXSP-v45-SHA256SUMS.txt](scripts/card-updaters/RG34XXSP-v45-SHA256SUMS.txt)
