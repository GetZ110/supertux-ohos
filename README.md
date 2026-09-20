# supertux-ohos

把 [SuperTux](https://github.com/SuperTux/supertux) 跑到 OpenHarmony / HarmonyOS 上的构建脚本、补丁与移植笔记。

> **非官方社区移植。** 与华为、开放原子开源基金会、SuperTux 开发团队均无隶属或背书关系。
> HarmonyOS / OpenHarmony 是其各自所有者的商标，此处仅作描述性使用。详见 [NOTICE](NOTICE)。

> 🚧 **仍在开发中。** 下面的「已知问题」里还有几项没解决，行为、坐标与产物都可能变动。

## 现状

| 状态 | 项目 |
|---|---|
| ✅ | 交叉编译 → 打包 HAP → 签名 → 安装 → 启动，全链路在真机跑通 |
| ✅ | 标题画面 / 主菜单正常渲染，横屏铺满整屏（2720×1260，状态栏与导航条都已隐藏） |
| ✅ | 输入可用：触摸（触屏虚拟按键）与 `uinput` 注入按键都能操作菜单 |
| ✅ | 资源加载：`data.zip` 从 HAP 的 rawfile 解包到应用沙箱，由 PhysFS 挂载 |
| ✅ | 日志走 hilog（SuperTux 的日志流已接到 `SDL_Log`） |
| ✅ | 音频可用：`patches/openal-ohos-sdl3.patch` 给 OpenAL Soft 加了 SDL3→OHAudio 输出后端 |
| ⚠️ | 触摸落点还差一个状态栏/导航栏高度偏移（机制已通，坐标偏上约 100px） |
| ⚠️ | 方向键在"按键映射表"路径下不生效（SDL 鸿蒙键映射表把 `KEY_DPAD_DOWN` 映成了非 `SDL_SCANCODE_DOWN`） |
| ⚠️ | 音乐默认不打包（`data.zip` 排除 145 MB 的 `music/`，需加 `--include-music`；菜单本身不放音效） |

## 环境要求

- **华为命令行工具**（含 HarmonyOS SDK）：本仓库在 `26.0.0.821` / SDK **API 26** / hvigor `6.26.4` 上验证过。
  默认路径写的是 `E:\harmony_os\command-line-tools`，可用 `-CLT <path>` 或 `$env:OHOS_CLT` 覆盖。
- **真机**：HarmonyOS 5.0.4（API 16）及以上（SDL 鸿蒙后端的下限）。验证机型 Mate 60 Pro / HarmonyOS 7.0.0.107 / API 26。
- Windows + PowerShell、git、JDK（`hap-sign-tool` 需要）、已实名的华为开发者账号（签名用）。

## 快速开始（Linux / HarmonyOS 主机，bash）

`scripts/*.sh` 是 `scripts/*.ps1` 的等价实现，用于没有 PowerShell 的 Linux 或 HarmonyOS 本机。
已在本机（HarmonyOS aarch64 + Mate 60 Pro / API 26）**实跑通过全链路**：构建 → 打包 → 签名 →
`hdc install` → 启动 → 抓 hilog → 截图，标题画面与主菜单正常渲染。

```bash
git clone <this repo> supertux-ohos
cd supertux-ohos

scripts/fetch-sources.sh                       # 1. 拉固定版本源码 + 应用 patches/
scripts/build-ohos-deps.sh                     # 2. libpng physfs fmt glm freetype ogg vorbis openal
scripts/build-sdl-ohos.sh                      # 3. SDL3 / SDL3_image / SDL3_ttf
scripts/build-supertux-ohos.sh                 # 4. SuperTux → build/supertux/libmain.so
scripts/build-supertux-hap.sh                  # 5. 打包 + 签名 + 安装 + 启动 + hilog + 截图
```

只出 HAP 不上机：`scripts/build-supertux-hap.sh --skip-install`；
想带上音乐：`--include-music`（data.zip 从 ~139 MB 涨到 ~287 MB）。

> 音频依赖 SDL3：`build-ohos-deps.sh` 构建 OpenAL 前会先确保前缀里有 `libSDL3.so`，
> 没有就自动先跑一次 `build-sdl-ohos.sh --skip-image --skip-ttf`（SDL3_image/SDL3_ttf 需要
> 本脚本产出的 libpng/freetype，所以不能简单调换两步的顺序）。

环境变量：`OHOS_CLT`（命令行工具根目录）、`OHOS_NATIVE`（native SDK，见下方“SDK 版本”）、
`SUPERTUX_OHOS_KEY_PWD`（密钥库口令，不要写进文件）。

### 本机实测环境与两处与 Windows 文档的差异

1. **hvigor / SDK 版本**：`deveco_tools` 里带的 SDK 是 **API 23（HarmonyOS 6.0.33）**，不是文档写的
   API 26。`build-profile.json5` 的 `targetSdkVersion`/`compatibleSdkVersion` 因此用
   `6.1.0(23)`；hvigor 的 `modelVersion` 必须 ≤ `6.1.0`（写成 `6.1.1` 会直接报
   `Unsupported modelVersion of Hvigor`）。
2. **`hap-sign-tool` 不是 jar**：当前 SDK 提供的是 arm64 原生二进制
   `sdk/default/openharmony/toolchains/lib/hap-sign-tool`，脚本会优先用它，找不到才回退 `java -jar`。

> 若手上是 API 26 的 native SDK，用 `OHOS_NATIVE=<path> OHOS_COMPATIBLE_SDK_VERSION=26` 覆盖即可。

### 签名（真机必需，且只能来自 AGC）

真机安装要求 HAP 由 **AppGallery Connect 签发的调试 Profile** 签名，三件套放进 `signing/`
（已被 `.gitignore` 忽略），命名随意，脚本会自动发现，或用 `--cert/--profile/--keystore` 指定：

| 文件 | 是什么 |
|---|---|
| `*.p12` | 你自己的密钥库（私钥） |
| `*.cer` | AGC 用你的 CSR 签发的调试证书 |
| `*.p7b` | AGC 签发的调试 Profile，绑定 `bundleName` + 设备 UDID |

**Profile 只能由华为签发，不能本地改包名重签。** 实测：用 SDK 自带的 OpenHarmony 证书链
`sign-profile` 出一个 `com.supertux.game` 的 profile 再签名 HAP，设备直接拒绝：

```
error: failed to install bundle. code:9568257 error: fail to verify pkcs7 file.
```

同理，`.cer`/`.p7b`/`.p12` 三者必须同属一份 Profile（`p7b` 内嵌了它对应的开发证书）；
证书不匹配时 hvigor 报 `No certificates configured for sign`。所以换 `bundleName` 就要在 AGC
重新申请 Profile（调试证书同一账号可复用，但 Profile 必须重签）。

> 一个容易踩的点：`.cer` 与 `.p12` 里的证书**指纹可以不同**，这不算不匹配 —— AGC 重新签发证书时
> 复用同一个密钥对。判定依据应是**公钥**而不是指纹：把 `p12` 的私钥导出公钥、与 `p7b` 内嵌的
> `development-certificate` 比公钥，一致即可。本机 `com.supertux.game` 就是这样验通的
> （`signing/sdl3demo.p12` 别名 `sdl3demo`，私钥 / `sdl3demo.cer` 叶子证书 / Profile 内嵌证书
> 三者的公钥均为 `1a35a2b1…`）。
>
> 另外 `--key-alias` 要按密钥库里的实际别名传（本机是 `sdl3demo`，默认值是 `debugKey`）。

## 快速开始

```powershell
git clone <this repo> supertux-ohos
cd supertux-ohos

# 1. 拉第三方源码（按 scripts/versions.txt 固定版本）并应用 patches/
.\scripts\fetch-sources.ps1                     # GitHub 需要代理时加 -Proxy http://127.0.0.1:7890

# 2. 依赖链 → build/ohos-prefix
.\scripts\build-ohos-deps.ps1                   # libpng physfs fmt glm freetype ogg vorbis openal

# 3. SDL3 + SDL3_image + SDL3_ttf → build/ohos-prefix
.\scripts\build-sdl-ohos.ps1

# 4. SuperTux → build/supertux/libmain.so
.\scripts\build-supertux-ohos.ps1

# 5. 打包 + 签名 + 安装 + 启动 + 抓日志 + 截图（签名材料见 docs/signing-howto.md）
$env:SUPERTUX_OHOS_KEY_PWD = '<你的密钥库口令>'
.\scripts\build-supertux-hap.ps1
```

只想出 HAP 不上机：`.\scripts\build-supertux-hap.ps1 -SkipInstall`；
想带上音乐：`-IncludeMusic`（HAP 会从 ~150 MB 涨到 ~290 MB）。

## 目录结构

```
supertux-ohos/
├── app/supertux-ohos/        ArkTS 壳（EntryAbility / Index.ets / module.json5 / build-profile.json5）
│                             entry/libs 与 rawfile/data.zip 由脚本生成，不入库
├── docs/
│   ├── porting-notes.md      移植方案 + 实施结果 + 踩过的坑（含日志证据）
│   └── signing-howto.md      AGC 调试证书 / Profile / 本地签名步骤
├── patches/
│   ├── supertux-ohos.patch   SuperTux 侧改动
│   └── sdl-ohos.patch        SDL 侧本地改动
├── scripts/
│   ├── versions.txt          固定的第三方版本（可复现构建）
│   ├── fetch-sources.ps1     克隆 + 应用补丁            （Windows）
│   ├── build-ohos-deps.ps1   依赖链交叉编译             （Windows）
│   ├── build-sdl-ohos.ps1    SDL3 / SDL3_image / SDL3_ttf（Windows）
│   ├── build-supertux-ohos.ps1   SuperTux → libmain.so  （Windows）
│   ├── build-supertux-hap.ps1    打包 + 签名 + 安装 + 验证（Windows）
│   └── *.sh                  同上五个脚本的 bash 等价实现（Linux / HarmonyOS）
└── NOTICE                    第三方组件、许可证与商标声明
```

`third_party/`、`build/`、`signing/` 都是本地产物，已被 `.gitignore` 忽略。

## 它是怎么跑起来的

1. **鸿蒙上 SDL3 只支持 main callbacks**（`SDL_main_impl.h` 里对 OHOS 直接 `#error`），所以 SuperTux 的
   阻塞主循环被拆成 `Main::ohos_init / ohos_iterate / ohos_shutdown`，由 `src/ohos/main_ohos.cpp` 里的
   `SDL_AppInit / SDL_AppIterate / SDL_AppEvent / SDL_AppQuit` 驱动，产物是 **`libmain.so`**（不是可执行文件）。
2. **ArkTS 壳先解包数据再交接**：`onCreate` 里同步把 `resources/rawfile/data.zip` 解到应用沙箱
   （`SDL_GetPrefPath` 指向的位置），然后才调 `provideArkTSObjects()` 把控制权交给 SDL。顺序不能反 ——
   SDL 的 window-stage 钩子必须在那之前装好，否则 XComponent 永远不会被创建。
3. **事件在 `InputManager::update()` 之后投递**：`SDL_AppEvent` 只入队，
   `ScreenManager::process_events()` 在 `update()` 之后排空队列；顺序反了的话控制器状态会被 flush 掉，
   菜单永远收不到按键。
4. **全屏**：`module.json5` 用 `orientation: landscape`，系统栏由 SDL 在其 `onWindowStageCreate` 钩子里隐藏。
5. **音频**：SuperTux 用 OpenAL Soft（不是 SDL 音频）。OpenAL 在鸿蒙上原本没有任何可用后端
   （OpenSL 那条路要 Android 的 `SLAndroidSimpleBufferQueueItf`，鸿蒙用 `SLOHBufferQueueItf`），
   于是新增 SDL3 后端把输出交给 SDL3，再由 SDL3 的 OHAudio 后端落到 `libohaudio.so`。

每个坑的根因、失败现象和修法（包括"同一份 libSDL3 被加载两份导致窗口创建失败"这种硬骨头）都记在
[docs/porting-notes.md](docs/porting-notes.md)。

## 补丁说明

| 补丁 | 内容 |
|---|---|
| `patches/supertux-ohos.patch` | `file_system.cpp` 的 curl 头改为按需包含；日志流接到 `SDL_Log`；主循环拆分 + 鸿蒙入口 `src/ohos/main_ohos.cpp`（**新增文件**：`SDL_AppInit/AppIterate/AppEvent/AppQuit` 四个回调，事件经 `ScreenManager::push_ohos_event()` 缓冲后在 `InputManager::update()` 之后回灌）；`ScreenManager::begin()/process_event()`；窗口创建重试；`custom_mouse_cursor(false)` + `Config::load()` 后强制覆盖（触摸生效后软件光标会跟着手指跑）；viewport 用窗口真实尺寸而非配置里的 1280x800；CMake 的 OHOS 分支（共享库 + `OUTPUT_NAME main`） |
| `patches/sdl-ohos.patch` | OHOS 上不设 SOVERSION（**关键**：否则 ArkTS 按名字加载一份、`libmain.so` 按 SONAME 又加载一份，两份全局变量会让 `SDL_CreateWindow` 失败）；在 `onWindowStageCreate` 和建窗口后隐藏系统栏；在 `OPENHARMONY_VideoInit()` 里主动 `SDL_AddTouch()`（否则 `SDL_GetTouchDevices()` 启动时返回 0，SuperTux 判定"无触摸屏"从而不启用触屏虚拟按键）；`SetWindowFullscreen(LEAVE)` 不再重新显示系统栏；两处 `OPENHARMONY-DEBUG` 日志 |
| `patches/openal-ohos-sdl3.patch` | 给 OpenAL Soft 1.23.1 新增 **SDL3 输出后端**（`alc/backends/sdl3.{cpp,h}`，照自带的 `sdl2.cpp` 移植）并把 OpenAL 的输出接到 SDL3 音频子系统；SDL3 在鸿蒙上已有可用的 **OHAudio** 后端，因此 OpenAL 不再只有 null/wave |

> SDL 仓库里的 `AGENTS.md` 明确表示不接受 AI 生成内容 / PR，所以 SDL 侧改动请**只作为本仓库的本地补丁**使用，
> 不要往上游提 PR；SuperTux 侧建议先开 issue 讨论再提。

## 许可与商标

本仓库的脚本、补丁与文档按 **GPL-3.0** 提供（补丁是 SuperTux 的派生作品，SuperTux 为 GPL-3.0）。
第三方组件的许可证与商标声明见 [NOTICE](NOTICE)。

## 致谢

- SDL3 的 HarmonyOS / OpenHarmony 后端由 Ryan C. Gordon ([icculus](https://github.com/icculus)) 完成，由 [Outfit7](https://outfit7.com/) 赞助
- [SuperTux](https://github.com/SuperTux/supertux) 开发团队
