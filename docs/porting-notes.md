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

## 0.3 触摸、光标与音频（已解决）

### 触摸完全无反应：SDL 的 OHOS 触摸设备是"懒注册"的

`src/video/openharmony/SDL_openharmonyevents.c` 原本只在
`SDL_OpenHarmonyDispatchTouchEvent()` 里**第一次收到触摸时**才调用 `SDL_AddTouch()`。
而 SuperTux 在启动时就用 `SDL_GetTouchDevices()` 判断"有没有触摸屏"，据此决定是否启用
`MobileController`（触屏虚拟按键）。启动时设备数还是 0 → `mobile_controls=false` →
`m_screen_width/height` 一直是 0（只在 `MobileController::draw()` 里赋值，而它提前 return 了）。

修法：新增 `OPENHARMONY_InitTouch()`，在 `OPENHARMONY_VideoInit()` 里**主动**
`SDL_AddTouch((SDL_TouchID)1, SDL_TOUCH_DEVICE_DIRECT, "OpenHarmony Touch")`，
与 Android 的 `Android_InitTouch()` 保持一致。

### 触摸修好后光标又跑出来了

`gameconfig.cpp` 里 `custom_mouse_cursor` 的默认值按平台分叉，鸿蒙落进了**桌面分支** `true`。
触摸时 SuperTux 会调 `MouseCursor::set_pos()`（顺带把 `m_mobile_mode` 置真）让光标可见，
于是手指到哪儿光标跟到哪儿。修法两处：

1. `#if defined(__ANDROID__) || defined(__OHOS__)` → `custom_mouse_cursor(false)`。
2. `Config::load()` 之后**再强制覆盖一次**。因为配置会持久化到
   `<app filesDir>/supertux2/config`，老配置里的 `custom_mouse_cursor` 会在 `load()` 时
   把编译期默认值盖掉，只改默认值不够。

### 没有声音：OpenAL 根本没有输出后端

日志证据（configure 阶段）：`Could NOT find OpenSL (missing: OPENSL_ANDROID_INCLUDE_DIR)` →
`Building OpenAL with support for the following backends: ALSOFT_BACKEND_NULL`。
产出的 `libopenal.so` 只带 `WAVE`/`wave`/`null` —— 也就是说 OpenAL 一直在把混音结果
**丢进空后端**，游戏再"正常"也不可能有声音。

根因：OHOS 的 OpenSL ES 用的是 `SLOHBufferQueueItf` / `SL_IID_OH_BUFFERQUEUE`，
而 OpenAL 的 `alc/backends/opensl.cpp` 依赖 Android 的
`SLAndroidSimpleBufferQueueItf`（还 include 了 `jni.h`），所以 `find_package(OpenSL)` 必然失败。

修法：新增 `alc/backends/sdl3.cpp` + `sdl3.h`（照 1.23.1 自带的 `sdl2.cpp` 移植），
把 OpenAL 的输出接到 **SDL3 的音频子系统**；SDL3 在鸿蒙上已经有可用的 **OHAudio** 后端
（`src/audio/ohaudio/SDL_ohaudio.c`，运行时 dlopen `libohaudio.so`）。
`CMakeLists.txt` 增加 `ALSOFT_BACKEND_SDL3`（默认 OFF，本移植显式打开），
`config.h.in` / `alc/alc.cpp` 各加一处 `HAVE_SDL3`。补丁见 `patches/openal-ohos-sdl3.patch`。

移植 SDL2→SDL3 API 时两处必须注意：

- SDL3 删掉了 `SDL_OpenAudioDevice`（回调式）和 `SDL_AUDIO_ALLOW_ANY_CHANGE`，
  改用 `SDL_OpenAudioDeviceStream()`：返回的流的回调就是"取数据"回调，
  **初始为 paused**，必须 `SDL_ResumeAudioStreamDevice()` 才会跑；销毁流即关闭设备。
- SDL3 **没有 `SDL_AUDIO_U16`**（只有 U8/S8/S16/S32/F32），`DevFmtUShort` 只能落到 S16。
- 踩坑记录：`mFrameSize` 忘了赋值（=0），回调里 `if(!mFrameSize) return;` 直接短路，
  表现为"回调在跑但每个 buffer 全是 0"。改成先看 `SDL_GetAudioStreamFormat()` 的真实
  app 侧格式再算 `BytesFromDevFmt(type) * channels`。

验证（`uinput -T -c x y` 注入点击 + hilog）：

- 后端确实被选中：启动日志无 `Audio error`，系统侧出现
  `OHAudioRenderer: [Initialize]`，`libopenal.so` 的 `NEEDED` 里出现 `libSDL3.so`。
- 混音器确实出音：临时探针播放 `sounds/coin.wav` 后，系统侧
  `AudioLogUtils: [ProcessVolumeData] ... not slient 36frames change to slient`。
- 音乐确实在循环：打入 `music/` 后标题曲按 `.music` 的 loop 点循环，
  系统侧可见 `slient → not slient → (1233frames) → slient → 5frames → not slient`。

### 音乐默认没打包

`data.zip` 默认**排除 `music/`**（145 MB）。所以即使后端修好，标题画面依然是静音 ——
菜单本身**不放任何音效**（包里的 90 个 `sounds/` 全是关卡内音效）。
要听音乐请加 `--include-music`，打包体积约 139 MB → 287 MB。

## 0.4 已知遗留

- **触摸坐标**：`uinput` 的屏幕坐标 → SDL 归一化坐标之间还有状态栏/导航栏偏移
  （SuperTux 看到的窗口是 2720x1046，而屏幕是 2720x1260），点击落点会偏上约 100px。
  机制本身是通的（finger → SuperTux 合成 mouse-button 事件已确认到达），只需校正偏移。
- **DPAD 键码**：SDL 的 OHOS 键映射把 `KEY_DPAD_DOWN` 映射成了非 `SDL_SCANCODE_DOWN` 的键码
  （日志里 key=0x40000080），所以方向键在"按键映射表"路径下不生效；但菜单路径走的是
  `process_menu_key_event()` 里的 `SDLK_DOWN` 硬编码分支，需要 SDL 侧键映射修正才能完全对齐。
- 独立 bundleName 的 AGC Profile（`com.supertux.game` 目前复用 demo 的调试 Profile）。

## 0.3 全屏 / 系统栏（已解决）

**症状**：游戏只占屏幕左上角，状态栏和导航条都还在，右侧和下方是大片黑边。

排查后有**两个互相独立**的成因，之前的结论（"系统会把状态栏强制恢复，应用侧做不到"）是错的 ——
其实是我们自己的代码在把状态栏打开。

### 成因 1：viewport 用的是配置里的 1280x800，不是窗口的真实尺寸

SDL 在 `OPENHARMONY_CreateWindow` 里把窗口尺寸设成 XComponent 的尺寸（实测 2720x1046），
但 `SDLVideoSystem::apply_config()` 是按 `g_config->window_size`（默认 **1280x800**）算 viewport 的：

```cpp
Size target_size = ... g_config->window_size;   // 1280x800
m_viewport = Viewport::from_size(target_size, m_desktop_size);
```

而且 OHOS 后端**没有实现 `SetWindowSize`**，所以 `apply_video_mode()` 里那句
`SDL_SetWindowSize(1280, 800)` 只会失败（`SDL_Unsupported()`），窗口不会被改小 ——
结果就是"2720x1046 的 surface 上画了一个 1280x800 的游戏"。

修法：OHOS 上直接用窗口的真实尺寸当 viewport 目标
（`third_party/SuperTux/src/video/sdl/sdl_video_system.cpp`）：

```cpp
#if defined(__OHOS__)
    Size target_size = get_window_size();   // 2720x1046，而不是配置里的 1280x800
```

SuperTux 自己的自动缩放（`Viewport::from_size`）随后会把画面放大铺满。

### 成因 2：SuperTux 自己调 `SDL_SetWindowFullscreen(window, 0)`，SDL 把它翻译成"显示系统栏"

这是状态栏"关不掉"的真正原因，也是之前几轮排查都没想到的地方：

```c
SDL_FullscreenResult OPENHARMONY_SetWindowFullscreen(...)
{
    const bool show_bars = (fullscreen == SDL_FULLSCREEN_OP_LEAVE);
    SDL_OpenHarmonyToggleSystemBars(show_bars, show_bars);   // LEAVE => 显示系统栏！
```

`g_config->use_fullscreen` 在非 Android 平台是 `false`，于是
`SDLBaseVideoSystem::apply_video_mode()` 每次都会走

```cpp
if (!g_config->use_fullscreen) { SDL_SetWindowFullscreen(m_sdl_window.get(), 0); ... }
```

即**主动请求"退出全屏"**，SDL 就照着"显示状态栏和导航条"执行。日志时序完全对得上（同一进程内）：

```
22:58:52.393  SDL/STARTUP: layout is full screen
22:58:52.395  SDL/STARTUP: system bars hidden
22:58:52.399  SCBStatusBarView: isEnable changed: true, immersive is false   ← 4ms 后又被打开
```

所以"系统 15ms 内自己恢复"的观感，其实是应用自己在几百微秒内先关后开，
而关的那次是我们调的、开的那次是 SDL 按 LEAVE 语义调的。**不是系统覆盖，也不是竞态。**

修法（两处，缺一不可）：

1. `SDL_openharmonywindow.c`：`SetWindowFullscreen` 不再把 LEAVE 翻译成"显示系统栏"。
   鸿蒙上窗口本来就铺满整个 display，退出"全屏"没有任何理由把栏要回来：
   ```c
   (void) fullscreen;
   SDL_OpenHarmonyToggleSystemBars(false, false);
   ```
2. `SDL_openharmony.c`：隐藏系统栏改用**未废弃**的 API，并且**顺序**是"先 layout 后隐藏"——
   `setWindowLayoutFullScreen()` 会把栏重新显示出来，所以它必须排在前面：
   ```c
   CallNapiMethod(env, window, "setWindowLayoutFullScreen", ...);      // 先
   CallNapiMethod(env, window, "setWindowSystemBarEnable", ...);       // 后（setSystemBarEnable 自 API 9 起已废弃）
   ```

ArkTS 侧（`EntryAbility.ets`）同样改成"先 layout、后 `setWindowSystemBarEnable([])`"，
并且**不使用** `setImmersiveModeEnabledState`。

### 结果（Mate 60 Pro / HarmonyOS 7.0.0.107 实测）

- 游戏铺满 **2720x1260**，状态栏与导航条都不再出现。
- sceneboard 只剩**一次**状态切换且之后不再反弹：
  `isEnable changed: false, immersive is true`（此前是每 20ms 反复 true/false）。
- 判定方法是拿系统和游戏截图比对**黑边**：桌面截图唯一的全黑扫描行是最后一行 `y=1259`，
  游戏截图也**只有** `y=1259`，即游戏覆盖范围与系统 UI 完全一致。

> 附带结论：`setWindowLayoutFullScreen` 单独用不足以隐藏栏，`setWindowSystemBarEnable([])`
> 单独用也不够（会被 layout 调用重置），两者必须按上述顺序配合，且不能让
> `SetWindowFullscreen(LEAVE)` 再插一脚。

> 关于"是不是证书/应用分类的问题"：AGC 的证书只有调试/发布（+企业发布）三类，没有"游戏证书"；
> 应用 vs 游戏是**分类与上架资质**的差别。本次实测证明系统栏行为与证书无关，
> 换成 `com.supertux.game` 的 AGC 调试证书后现象完全一样，真正的原因在成因 2。

## 0.5 下一步

1. 校正触摸坐标偏移（把状态栏/导航栏高度计入，或在 ArkTS 侧用窗口尺寸换算）。
2. 修 SDL 的 OHOS 键映射表（DPAD 等）。
3. 为 `com.supertux.game` 建 AGC 调试 Profile，脱离临时复用的 demo 包名。

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
