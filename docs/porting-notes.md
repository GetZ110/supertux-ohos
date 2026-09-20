# SuperTux → HarmonyOS 移植方案（阶段 b）

> **状态：已在真机跑起来。** SuperTux 0.7.0 dev 以 `libmain.so` 形式被 SDL3 的 main callbacks 驱动，
> 在 Mate 60 Pro（HarmonyOS 7.0.0.107 / API 26）上安装、启动、渲染出标题画面与主菜单，进程稳定存活。
> 待办：菜单输入（触摸→菜单激活）尚未确认生效；横屏、音乐、音频后端为后续打磨项。

## 0. 实施结果（本轮）

**产物**：`supertux-ohos/entry/build/default/outputs/default/entry-default-signed.hap`（149.5 MB，
含 14 个 native 库 + `resources/rawfile/data.zip` 132.6 MB）。

**脚本**：
| 脚本 | 作用 |
|---|---|
| `build-ohos-deps.ps1` | 交叉编译依赖链到 `ohos-prefix`（libpng/physfs/fmt/glm/freetype/ogg/vorbis/openal） |
| `build-supertux-ohos.ps1` | 配置 + 编译 SuperTux 为 `libmain.so`（子模块、PhysFS shim、CMake 参数） |
| `build-supertux-hap.ps1` | 收集 .so、生成 data.zip、hvigor 打包、hap-sign-tool 签名、hdc 安装/启动/抓日志/截图 |
| `supertux-ohos.patch` | 对 SuperTux 的本地补丁（`git diff`） |

**SuperTux 侧改动（全部在 `supertux-ohos.patch` 里）**：
1. `src/util/file_system.cpp`：`#include <curl/curl.h>` 改为 `#elif defined(HAVE_CURL)`（上游在非 curl 平台上会编不过）。
2. `src/util/log.cpp`：鸿蒙上把日志流接到 `SDL_Log()`（照搬它已有的 Android logcat 分支）。
3. `src/supertux/main.hpp/.cpp`：把阻塞的 `Main::run()` 拆成 `init_subsystems()` + `ohos_init/ohos_iterate/ohos_shutdown`；鸿蒙分支的 PhysFS 数据目录逻辑；`SDL_GetPrefPath` 作为 userdir。
4. `src/ohos/main_ohos.cpp`（新增）：`SDL_AppInit/Iterate/Event/Quit` 四个回调，事件缓冲 + 每帧回灌（SDL 的 main-callback 分发会**排空**队列，而 SuperTux 自己 `SDL_PollEvent`）。
5. `src/supertux/screen_manager.hpp/.cpp`：拆出 `ScreenManager::begin()`（`run()` 循环前的那两步），因为初始屏幕是 `push_screen()` **排队**的，要 `handle_screen_switch()` 才落栈。
6. `src/video/sdlbase_video_system.cpp`：鸿蒙上 `SDL_CreateWindow` 失败时重试（surface 生命周期竞态）。
7. `CMakeLists.txt`：`OHOS` 分支产出 `SHARED` 库、`OUTPUT_NAME main`；`USE_STATIC_SIMPLESQUIRREL`/`HIDE_NONMOBILE_OPTIONS` 把 OHOS 当移动平台。

**SDL 侧改动（本地，未上游）**：
- `CMakeLists.txt`：`elseif(UNIX AND NOT (ANDROID OR OHOS OR CYGWIN))` —— 鸿蒙也不设 SOVERSION（**关键**，见下）。
- `src/video/openharmony/SDL_openharmonyvideo.c` / `SDL_openharmonywindow.c`：加了 `OPENHARMONY-DEBUG` 日志（诊断用，可去掉）。

**鸿蒙工程（`supertux-ohos/`）**：ArkTS 侧在 `onCreate` 里**同步**把 rawfile 的 `data.zip` 解到
`<app filesDir>/supertux2/data.zip`（即 `SDL_GetPrefPath` 指向的位置），然后才 `provideArkTSObjects()`；
native 库走 `entry/libs/arm64-v8a/` 预编译入库，不启用 hvigor 的 CMake 构建。

## 0.1 踩过的坑（按发现顺序，都是硬骨头）

| # | 现象 | 根因 | 修法 |
|---|---|---|---|
| 1 | 可执行文件链接失败 `undefined symbol: main` | 鸿蒙上 `SDL_main.h` 把 `main` 改名成 `SDL_main`，且 **OHOS 只支持 main callbacks**（`SDL_main_impl.h` 里直接 `#error`） | 走 callbacks 路线，新增 `src/ohos/main_ohos.cpp` |
| 2 | `SDL_Init` 报 "did you include SDL_main.h…" | SDL 的 OHOS 启动路径 `SDL_EnterAppMainCallbacks` **没有**经过 `SDL_CallMainFunction`，`SDL_SetMainReady()` 从没被调用 | 在 `SDL_AppInit` 里自己调 `SDL_SetMainReady()` |
| 3 | OpenAL 编译不过 | master 用 C++20 `lexicographical_compare_three_way`，鸿蒙 libc++ 没有 | 退到 **1.23.1** |
| 4 | OpenAL 编过了但**一个符号都不导出** | 它的 `AL_API` 导出宏来自 `check_c_source_compiles` 探测，交叉编译下探测失败 → 宏为空 + `-fvisibility=hidden` | `-DHAVE_GCC_DEFAULT_VISIBILITY=1` |
| 5 | `SDL_LoadFile("data.zip")` 失败（连 18 字节小文件也失败） | 见 #7 —— 是同一个"库被加载两份"的连锁反应 | 由 #7 一并解决 |
| 6 | `SDL_CreateWindow` 报 "Don't have Native XComponent or Native Window"，且**没有** surface 销毁回调 | 同一份 `libSDL3.so` 被加载了**两份**：ArkTS 按 `libSDL3.so` 加载一份，libmain.so 的 NEEDED 是 `libSDL3.so.0`（HAP 里另一个文件）→ 两份全局变量，回调写 A、`CreateWindow` 读 B | 让 SDL 的 SONAME 不带版本号（同 Android 的处理），HAP 里只放 `libSDL3.so`；SDL_image/SDL_ttf 也要重新链接 |
| 7 | 第一帧就退出 | 初始屏幕是 `push_screen()` 排队的，`ScreenManager::run()` 进循环前会先 `handle_screen_switch()`，我漏了 | 拆出 `ScreenManager::begin()` 并在 `ohos_init` 里调用 |
| 8 | 启动后 `SetUIContent timeout`，SDL_AppInit 不执行 | 我把 `provideArkTSObjects()` 放到异步回调里，错过了 `onWindowStageCreate` 钩子 | 改成同步解包 + 同步交接 |
| 9 | ArkTS 解包到 `haps/entry/files`，SuperTux 找不到 | `this.context.filesDir` 是**模块级**目录，`SDL_GetPrefPath` 用的是**应用级**目录 | 用 `getApplicationContext().filesDir` |

## 0.2 输入链路的两个关键修复（已解决）

真机上"能渲染但按键/触摸无反应"有两个独立原因，缺一不可：

1. **XComponent 必须可聚焦**：`entry/src/main/ets/pages/Index.ets` 里给 XComponent 加
   `.focusable(true).defaultFocus(true)`。否则系统不会把按键事件送给 XComponent，
   SDL 的 `RegisterKeyEventCallback` 永远收不到东西。
2. **事件必须在 `InputManager::update()` 之后投递**：`ScreenManager::process_events()` 的顺序是
   `update()`（会 flush 控制器状态）→ 再 poll 事件 → 菜单读控制器。而 SDL 的 main-callback
   分发发生在 `SDL_AppIterate` **之前**，所以直接把事件喂进 `process_event()` 等于"在 update()
   之前设置状态"，下一帧 update() 就把它冲掉了，菜单永远看不到。
   修法：`SDL_AppEvent` 只入队（`ScreenManager::push_ohos_event`），`process_events()` 在
   `update()` 之后排空这个队列。这样也顺带消除了"事件在队列和回调之间反复弹跳"的重复投递。

验证：`uinput -K -d 2013 -u 2013`（DPAD_DOWN）×2 再 `2054`（ENTER）→ 标题菜单进入
"Installed Add-ons" 界面 ✓。

## 0.3 已知遗留

- **触摸坐标**：`uinput` 的屏幕坐标 → SDL 归一化坐标之间还有状态栏/导航栏偏移
  （SuperTux 看到的窗口是 2720x1046，而屏幕是 2720x1260），点击落点会偏上约 100px。
  机制本身是通的（finger → SuperTux 合成 mouse-button 事件已确认到达），只需校正偏移。
- **DPAD 键码**：SDL 的 OHOS 键映射把 `KEY_DPAD_DOWN` 映射成了非 `SDL_SCANCODE_DOWN` 的键码
  （日志里 key=0x40000080），所以方向键在"按键映射表"路径下不生效；但菜单路径走的是
  `process_menu_key_event()` 里的 `SDLK_DOWN` 硬编码分支，需要 SDL 侧键映射修正才能完全对齐。
- 音乐（data.zip 排除了 `music/`）、音频后端（OpenAL 只有 null/wave）、独立 bundleName 的 AGC Profile。

## 0.3 全屏 / 系统栏（本次排查）

**白边的成因**：SDL 只在窗口是 fullscreen 时才会去关系统栏
（`OPENHARMONY_SetWindowFullscreen` → `setSystemBarEnable`），而 SuperTux 的
`use_fullscreen` 默认值只有 **Android** 是 true，鸿蒙落到 false（窗口模式）→ 系统给状态栏和
导航条留出条带，SDL 的窗口因此是 2720x1046（而不是 2720x1260），上下就是两条白边。

**走过的两条路**：

1. 让 SDL 切 fullscreen（把 OHOS 也默认成 true）——**不可行**：状态栏确实被关掉了，但 SDL
   自己的 FIXME（"make sure this causes an XComponent resize event"）导致 surface 没重算，
   画面被旋转/挤成一条竖条（失败截图 `signing/supertux-fullscreen.jpeg`）。
2. **从 ArkTS 侧处理（采用）**：`window.getLastWindow()` →
   `setWindowLayoutFullScreen(true)` + `setImmersiveModeEnabledState(true)`。
   SuperTux 保持窗口模式不动几何。

**结果**：白边消失、游戏铺满 2720x1260、**底部导航条已隐藏**；但**状态栏图标仍叠在画面上**。
sceneboard 日志显示它被系统重新打开：
```
SCBStatusBarView: isEnable changed: false, ... immersive is true
SCBStatusBarView: isEnable changed: true,  ... immersive is false   (70ms 后)
```
`setWindowSystemBarEnable([])` 与 `setSpecificSystemBarEnabled('status', false)` 都返回成功，
但同样被系统覆盖；`setImmersiveModeEnabledState(true)` 亦然。也就是说在这台
HarmonyOS 7.0.0.107 上，应用侧目前没能把状态栏保持隐藏。

**可继续尝试的方向**：把状态栏属性设为完全透明
（`setWindowSystemBarProperties({ statusBarColor: '#00000000' })`）让图标不刺眼；或在窗口获得
焦点的事件里重新应用一次隐藏；或查一下是否与状态栏的"实况窗胶囊"（日志里的
`live_view_capsule`）有关。

**补充实测（把隐藏调用挪到官方时机）**：按华为 FAQ 的说法，隐藏系统栏应该在
`onWindowStageCreate` 里做。我在 SDL 的 `SDL_JS_UIAbility_OnWindowStageCreate`
（它自己 monkey-patch 的那个钩子）里、拿到 `getMainWindowSync()` 之后调用了 SDL 自带的
`SDL_OpenHarmonyToggleSystemBars(false, false)`，并在 `OPENHARMONY_CreateWindow` 末尾又调了一次。
日志显示**确实关掉了**：

```
SCBStatusBarView: onStatusBarLayoutFinishedEvent false false     ← 关掉了
SCBStatusBarView: isEnable changed: false, ... immersive is true  ← 关掉了
SCBStatusBarView: isEnable changed: true,  ... immersive is false ← 15ms 后系统自己打开
```

即：不是竞态、也不是我们调用时机不对，而是**系统在极短时间内主动把状态栏恢复并取消 immersive**。
导航条能保持隐藏，状态栏不行。同时把 ArkTS 侧那套 `setWindowLayoutFullScreen` /
`setImmersiveModeEnabledState` 调用去掉了（它们反而会重置状态）。

> 关于"是不是证书/应用分类的问题"：AGC 的证书只有调试/发布（+企业发布）三类，没有"游戏证书"；
> 应用 vs 游戏是**分类与上架资质**的差别，华为的沉浸式文档和游戏上架文档都没有提到分类会影响
> 系统栏行为。所以证书不是原因。

## 0.4 下一步

1. 校正触摸坐标偏移（把状态栏/导航栏高度计入，或在 ArkTS 侧用窗口尺寸换算）。
2. 修 SDL 的 OHOS 键映射表（DPAD 等）。
3. 接上音乐 + 音频后端。
4. 为 `com.example.supertux2` 建 AGC 调试 Profile，脱离临时复用的 demo 包名。

---

## 1. 已核实的事实

| 项 | 事实 | 来源 |
|---|---|---|
| 版本 | SuperTux `0.7.0` dev，HEAD `b9c527f`（2026-09-20，"Fix Android builds"） | 本地 clone |
| 依赖解析 | `mk/cmake/SuperTux/AddPackage.cmake` 只做 `find_package(CONFIG)` / `pkg-config`，**没有自动下载** | 已读该文件 |
| 强制依赖 | PNG、ZLIB、PhysFS、fmt、glm、Freetype、SDL3、SDL3_image、SDL3_ttf、**OpenAL**、Ogg、Vorbis、VorbisFile（均 `REQUIRED`） | `CMakeLists.txt` L169-211 |
| 可选依赖 | libcurl（仅 `ENABLE_NETWORKING=ON` 时）→ 移植时置 `OFF` | L198-203 |
| 图形 | `ENABLE_OPENGL=ON` 时：`ANDROID` 分支走 `USE_OPENGLES2`；其它平台走 `find_package(OpenGL)` + GLEW/libepoxy。**鸿蒙不在任何分支里** → `HAVE_OPENGL=NO` → 回落到 SDL_Renderer 路径（正好对上 SDL3 鸿蒙后端的 GLES2 2D renderer） | L250-287 |
| 内置子模块 | `external/{sexp-cpp, SDL_SavePNG, simplesquirrel, partio_zip, findlocale, obstack, tinygettext}` 直接 `add_subdirectory`，无需外部包 | L226-237 |
| 产物形态 | `add_library(supertux2 SHARED ...)` 或 `add_executable(supertux2 ...)` —— **鸿蒙不能装可执行文件，必须做成 `libmain.so`** | L~505+ |

## 2. 依赖交叉编译状态

统一安装到 `E:\work\AnimalWell\harmony\ohos-prefix`，工具链 = SDK 自带 cmake + `ohos.toolchain.cmake`，`OHOS_COMPATIBLE_SDK_VERSION=26`。

| 依赖 | 状态 | 说明 |
|---|---|---|
| zlib | ✅ 无需构建 | OHOS sysroot 自带 `libz.so`（SDL_image 已 `find_package(ZLIB)` 命中） |
| SDL3 | ✅ 已构建并 install | `build-ohos` → `ohos-prefix`，`SDL3Config.cmake` 就位 |
| SDL3_image | ✅ 已构建 | `libSDL3_image.so` 285 KB（后端：stb/ani/bmp/gif/jpg/lbm/pcx/png/pnm/qoi/svg/tga/xcf/xpm/xv） |
| SDL3_ttf | ⏳ 待构建 | 需要 FreeType（`SDLTTF_VENDORED=ON` 会 FetchContent 拉 FreeType/HarfBuzz/plutosvg）；`SDLTTF_SAMPLES` 必须 OFF |
| libpng / physfs / fmt / glm / freetype / ogg / vorbis / openal | ⏳ `build-ohos-deps.ps1` 正在跑 | 见该脚本 |

**OpenAL 的坑**：SuperTux 把 OpenAL 列为 `REQUIRED`，但 OpenAL Soft 在鸿蒙上没有音频后端。先用 `ALSOFT_BACKEND_NULL/WAVE` 让它能链接、游戏能跑（无声），后续再把音频接到 SDL3 的 OHAudio 后端（或替换 SuperTux 的音频层）。

**通用坑（已踩到）**：OHOS 工具链带 `-Wl,--no-undefined`，而鸿蒙**不允许链接可执行文件**——SDL_image 的 `showgpuimage` 样例就因为 "undefined symbol: main" 链接失败（库本身没问题）。所以所有依赖都要关掉 tests/samples，或只构建库 target。

## 3. 入口点策略（关键设计决策）

鸿蒙的 SDL3 启动流程（`docs/README-harmonyos.md`）：ArkTS `EntryAbility` → `XComponent` surface 创建 → SDL 加载 **`libmain.so`**，然后：

1. 若 `libmain.so` 里有 **Main Callbacks**（`SDL_AppInit/SDL_AppIterate/SDL_AppEvent/SDL_AppQuit`）→ SDL 按 XComponent 的 `OnFrame` 回调驱动 `SDL_AppIterate`（**推荐路径**）；
2. 否则若有 `SDL_main` 符号 → SDL 起一个后台线程调用它，函数返回时 `exit()`（官方文档明说"能跑但自担风险"，可能有竞态）。

对应两条移植路线：

- **路线 A（先试，快）**：把 SuperTux 现有 `main()` 编进 `libmain.so`，靠 SDL_main 的宏改名成 `SDL_main`，让第 2 条路径接管。**不需要改 SuperTux 的代码**，最快能看到画面；风险是线程竞态。
- **路线 B（稳，推荐长期）**：把 `src/main.cpp` 的主循环拆成 `SDL_AppInit/Iterate/Event/Quit` 四段，SuperTux 的 `ScreenManager` 每帧推进一步，`SDL_AppEvent` 把事件喂给 SuperTux 的输入层。工作量大但符合鸿蒙的应用模型。

先 A 后 B：A 用来验证"依赖链 + 渲染 + 输入 + 资源加载"整条路是否通，再决定是否投入 B。

## 4. 资源与路径

- SuperTux 从 `data/` 目录读资源（`BUILD_DATA_DIR`），鸿蒙侧 HAP 内资源必须走 `assets://` / RawFile，或首次启动解包到 `SDL_GetPrefPath()`（`/data/storage/el2/base/files/<bundle>`）。
- **大小写敏感**：SuperTux 的 `data/` 里存在大小写不一致的引用（Linux 上没问题，Windows 上靠不敏感掩盖），鸿蒙是大小写敏感文件系统，要跑一遍引用校验。
- 存档路径：SuperTux 用 PhysFS 写用户目录，鸿蒙上要指到 prefpath。

## 5. 下一步顺序

1. 依赖链全部构建进 `ohos-prefix`（含 SDL3_ttf + freetype + openal + ogg/vorbis）。
2. 用 `ohos-prefix` 配置 SuperTux：`-DENABLE_NETWORKING=OFF`、`-DENABLE_OPENGL=OFF`、`-DBUILD_TESTING=OFF`、`-DCMAKE_PREFIX_PATH=<prefix>`。
3. 先按路线 A 出 `libmain.so` + 资源打包成 HAP，上机看画面。
4. 视情况做路线 B 的循环重构 + 音频接 OHAudio。
