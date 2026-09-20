# supertux-ohos

把 [SuperTux](https://github.com/SuperTux/supertux) 跑到 OpenHarmony / HarmonyOS 上的构建脚本、补丁与移植笔记。

> **非官方社区移植。** 与华为、开放原子开源基金会、SuperTux 开发团队均无隶属或背书关系。
> HarmonyOS / OpenHarmony 是其各自所有者的商标，此处仅作描述性使用。详见 [NOTICE](NOTICE)。

![SuperTux 在鸿蒙上的标题画面](docs/images/supertux-title.jpeg)

## 现状

| 状态 | 项目 |
|---|---|
| ✅ | 交叉编译 → 打包 HAP → 签名 → 安装 → 启动，全链路在真机跑通 |
| ✅ | 标题画面 / 主菜单正常渲染，横屏铺满整屏（2720×1260） |
| ✅ | 输入可用：`uinput` 注入方向键 + 回车，菜单进入 "Installed Add-ons"（见 [截图](docs/images/supertux-input-works.jpeg)） |
| ✅ | 资源加载：`data.zip` 从 HAP 的 rawfile 解包到应用沙箱，由 PhysFS 挂载 |
| ✅ | 日志走 hilog（SuperTux 的日志流已接到 `SDL_Log`） |
| ⚠️ | 触摸落点还差一个状态栏/导航栏高度偏移（机制已通，坐标偏上约 100px） |
| ⚠️ | 方向键在"按键映射表"路径下不生效（SDL 鸿蒙键映射表把 `KEY_DPAD_DOWN` 映成了非 `SDL_SCANCODE_DOWN`） |
| ⚠️ | 状态栏图标无法隐藏（调用成功但系统 15ms 内恢复；导航条可以隐藏） |
| ❌ | 音乐未打包（`data.zip` 默认排除 143 MB 的 `music/`）；音频后端是 OpenAL 的 null/wave，目前无声 |

## 环境要求

- **华为命令行工具**（含 HarmonyOS SDK）：本仓库在 `26.0.0.821` / SDK **API 26** / hvigor `6.26.4` 上验证过。
  默认路径写的是 `E:\harmony_os\command-line-tools`，可用 `-CLT <path>` 或 `$env:OHOS_CLT` 覆盖。
- **真机**：HarmonyOS 5.0.4（API 16）及以上（SDL 鸿蒙后端的下限）。验证机型 Mate 60 Pro / HarmonyOS 7.0.0.107 / API 26。
- Windows + PowerShell、git、JDK（`hap-sign-tool` 需要）、已实名的华为开发者账号（签名用）。

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
│   ├── signing-howto.md      AGC 调试证书 / Profile / 本地签名步骤
│   └── images/               真机截图
├── patches/
│   ├── supertux-ohos.patch   SuperTux 侧改动
│   └── sdl-ohos.patch        SDL 侧本地改动
├── scripts/
│   ├── versions.txt          固定的第三方版本（可复现构建）
│   ├── fetch-sources.ps1     克隆 + 应用补丁
│   ├── build-ohos-deps.ps1   依赖链交叉编译
│   ├── build-sdl-ohos.ps1    SDL3 / SDL3_image / SDL3_ttf
│   ├── build-supertux-ohos.ps1   SuperTux → libmain.so
│   └── build-supertux-hap.ps1    打包 + 签名 + 安装 + 验证
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

每个坑的根因、失败现象和修法（包括"同一份 libSDL3 被加载两份导致窗口创建失败"这种硬骨头）都记在
[docs/porting-notes.md](docs/porting-notes.md)。

## 补丁说明

| 补丁 | 内容 |
|---|---|
| `patches/supertux-ohos.patch` | `file_system.cpp` 的 curl 头改为按需包含；日志流接到 `SDL_Log`；主循环拆分 + 鸿蒙入口 `src/ohos/main_ohos.cpp`；`ScreenManager::begin()/process_event()`；窗口创建重试；CMake 的 OHOS 分支（共享库 + `OUTPUT_NAME main`） |
| `patches/sdl-ohos.patch` | OHOS 上不设 SOVERSION（**关键**：否则 ArkTS 按名字加载一份、`libmain.so` 按 SONAME 又加载一份，两份全局变量会让 `SDL_CreateWindow` 失败）；在 `onWindowStageCreate` 和建窗口后隐藏系统栏；两处 `OPENHARMONY-DEBUG` 日志 |

> SDL 仓库里的 `AGENTS.md` 明确表示不接受 AI 生成内容 / PR，所以 SDL 侧改动请**只作为本仓库的本地补丁**使用，
> 不要往上游提 PR；SuperTux 侧建议先开 issue 讨论再提。

## 许可与商标

本仓库的脚本、补丁与文档按 **GPL-3.0** 提供（补丁是 SuperTux 的派生作品，SuperTux 为 GPL-3.0）。
第三方组件的许可证与商标声明见 [NOTICE](NOTICE)。

## 致谢

- SDL3 的 HarmonyOS / OpenHarmony 后端由 Ryan C. Gordon ([icculus](https://github.com/icculus)) 完成，由 [Outfit7](https://outfit7.com/) 赞助
- [SuperTux](https://github.com/SuperTux/supertux) 开发团队
