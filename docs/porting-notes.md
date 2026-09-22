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

### 菜单点不中：悬停命中判定没有跟着 `get_distance()` 走（已解决）

**症状**：Options 首页（选 Locale / Video / … 那一屏）点画出来的 `Back` 会进入当前高亮的
选项（通常是 Locale），必须点 `Back` **上方**一点才能返回。进入各分项后的 `Back` 正常。

根因在 `src/gui/menu.cpp` 的 `SDL_EVENT_MOUSE_MOTION` 分支。它按"菜单左上角 + 累加高度"
推算鼠标落在哪个 item 上，但 `Menu::draw()` 的布局是
`get_distance() + get_height() + get_distance()`：

```cpp
// Menu::draw()  —— 画的时候
y_pos += m_items[i]->get_distance();
draw_item(context, i, y_pos + m_items[i]->get_height()/2);
y_pos += m_items[i]->get_height() + m_items[i]->get_distance();

// Menu::event() —— 判定的时候（修复前）
item_y += m_items[i]->get_height();   // 少了 get_distance()
```

`MenuItem::get_distance()` 默认 0，全仓库**只有 `ItemHorizontalMenu` 覆写成 10.f**。
所以每经过它一次，后面所有 item 的命中带就整体上移 `2 × 10 = 20` 逻辑像素。
Options 首页正好是 `label / hl / ItemHorizontalMenu / hl / Back`，于是 `Back` 的命中带
（上移后的 405.9..429.9）和它**画出来的位置**（中心 437.9，字形约 425.9..449.9）几乎不重叠：
点画出来的中心会落到所有 item 之外的空白，`new_active_item` 保持初值 0（label，skippable），
活动项于是留在上面那个图标行上，`HIT` 就进去当前高亮的那个分类（一般是 Locale）；
往上挪 20px 才落进 `Back` 真正的命中带——这正是"要点 `Back` 上面一点"的来源。

对照实验（同一屏，点画出来的 `Back` 中心 1355,872）：点下去进的是 Locale，符合
"命中带偏移"的推断；各分项菜单没有 `ItemHorizontalMenu`，无累积误差，所以只有首页有问题。

修法：让 `Menu::event()` 的累加与 `Menu::draw()` 完全一致，前后各加一次 `get_distance()`：

```cpp
item_y += m_items[i]->get_distance();
if (y >= item_y && y <= item_y + m_items[i]->get_height()) { new_active_item = i; break; }
item_y += m_items[i]->get_height() + m_items[i]->get_distance();
```

真机验证：点画出来的 `Back`（1355,872）能正常返回上一层 ✓。

> 顺带记一个"看着像 bug 其实不是"的点：`SDL_EVENT_MOUSE_BUTTON_DOWN` 分支用的是
> `ev.motion.x/y` 而不是 `ev.button.x/y`。SDL3 里两个结构体在 `x`/`y` 上的偏移恰好都是
> 28/32，所以能跑对；换 SDL 版本时值得留意。

### 语言菜单卡死闪退：压缩 zip 里的字体被反复重解压（已解决）

**症状**：Options → Locale → Select Language 点下去，画面定住约 6 秒，然后应用直接消失 ——
不是崩溃弹窗，是被系统杀掉。在语言列表里点任何一项也一样，所以语言根本改不了。

**根因**：`LanguageMenu` 构造时会为每个需要"自定义字体"的语言各建一个 `TTFFont`，而
`Resources::get_font_for_locale()` 把 `cmn / ja / zh_CN / zh_TW` 全指向同一个
`fonts/NotoSansCJKjp-Medium.otf`。这个文件在 `data.zip` 里是 **deflate 压缩**的 16.5 MB 条目，而
PhysFS 对压缩条目**无法真正 seek**：`ZIP_seek()` 在 `offset < uncompressed_position` 时会
`inflateEnd` 后从条目开头重新解压，再按 512 字节一块读到你想要的位置
（`third_party/deps/physfs/src/physfs_archiver_zip.c` 的 395-434 行）。FreeType 打开字体会先读 sfnt
表目录、再逐个 seek 回去读表，于是"打开一次字体"要把整个条目从头重解压几十遍。

加计时探针后的真机日志（Mate 60 Pro，hilog）：

```
LANGMENU get_languages: 0 ms (60 langs)
LANGMENU   font fonts/NotoSansCJKjp-Medium.otf (cmn): 3333 ms
LANGMENU   font fonts/NotoSansCJKjp-Medium.otf (ja):  3502 ms
LANGMENU   font fonts/MapoBackpacking.ttf       (ko):    32 ms
... 四个 CJK 语言合计 ~14 s
```

主线程被占住 6 秒以上，鸿蒙 `AppDfr` 依次报 `THREAD_BLOCK_3S` → `THREAD_BLOCK_6S` →
`APP_INPUT_BLOCK`，最后 `PROCESS_KILL ... reason=THREAD_BLOCK_6S`（`appspawn` 侧
`exit with signal:9`）。**"闪退"是看门狗强杀，不是段错误** —— 这一点很关键，一开始按崩溃去查
faultlog 是查不到的。

**修法**：字体先整份读进内存再交给 SDL_ttf（`get_physfs_SDLRWops_memory()`，
`src/physfs/physfs_sdl.cpp`），FreeType 之后在内存里随便 seek；缓冲区按文件名缓存，
四个语言共用一份。修后同一次菜单构造：

```
LANGMENU get_languages: 0 ms (60 langs)
LANGMENU   font fonts/NotoSansCJKjp-Medium.otf (cmn): 2 ms
LANGMENU   font fonts/NotoSansCJKjp-Medium.otf (ja):  2 ms
... LANGMENU total: 17-19 ms
```

> 另一条验证过的路：把 `data.zip` 里 `fonts/` 改成 STORED（不压缩），PhysFS 会走直接 seek
> 分支，3333 ms 同样降到 2 ms；但 HAP 要 +4 MB，而且只治"字体"这一类文件，所以最终选了内存缓冲。
>
> 这个对比一度把排查带偏：脚本的 `KEY_ALIAS` 默认是 `debugKey`，和本机密钥库别名 `sdl3demo`
> 不一致，签名报 `-105 ... GetSigner: key is NULL`，而脚本**照样继续安装上一次留下的旧签名 HAP**，
> 看起来像"改了没用"。实际跑的一直是旧包（连探针都没打进去）。现在签名失败会直接 `fail` 退出，
> 见 `scripts/build-supertux-hap.sh` 的 3b 段。

**顺带修掉**：无网络构建（`ENABLE_NETWORKING=OFF`，`config.h` 里没有 `NETWORKING`）下切到非英语语言时，
`LanguageMenu::menu_action()` 仍会 push `LANGPACK_AUTO_UPDATE_MENU`，它去下载 `index-0_7.nfo`，
必然抛 `Networking is disabled`，于是刚切好的语言上被盖一个报错框。`AddonManager::has_online_support()`
原本硬编码 `return true`，现在按 `NETWORKING` 如实返回，push 之前先问它；Add-ons 菜单里的
"Check Online" 也会正确变成禁用态。

### 触摸下的长菜单：拖动滚动、抬起才算点按（已解决）

**症状**：语言列表有 60 项，一屏放不下；手指一碰就立刻选中手指下面那一项，所以既看不到后面的
语言，也滚不动 —— 想"滑一下"反而改了语言（一开始还被误当成"有个光标跟着手指跑"）。

**根因**：菜单的命中判定是给鼠标 hover 用的。`ScreenManager::process_event()` 把 `FINGER_DOWN`
转成 `MOUSE_BUTTON_DOWN` 事件塞回 SDL 队列，`Menu::event()` 收到就 `process_action(HIT)`；
而 `FINGER_DOWN` 还会顺手生成一个 `MOUSE_MOTION`，`Menu::event()` 里那段 hover 命中逻辑于是把
高亮移到手指所在项。滚动本身只有鼠标滚轮（`SDL_EVENT_MOUSE_WHEEL`）+ 键盘，触摸一个都没有，
所以列表长了就没法用。

**修法**（`src/gui/menu.cpp` / `src/supertux/screen_manager.cpp`）：

1. `ScreenManager` 合成鼠标事件时把 `which` 标成 `SDL_TOUCH_MOUSEID`（SDL 自己的触摸鼠标模拟
   也用它），菜单据此把触摸和真鼠标分开 —— 桌面端行为完全不变。
2. 触摸**永不做 hover**：`MOUSE_MOTION` 里遇到 `SDL_TOUCH_MOUSEID` 直接走滚动分支，不再动选中项。
   滚动用独立偏移 `m_scroll_offset`（`scroll_by()` 里按内容上下边夹住），叠加在 `m_pos.y` 上；
   `draw()` 和 `item_at()` 都算上它，所以画在哪就能点到哪。
3. `MOUSE_BUTTON_DOWN` 对触摸只记起点，**不选中**；`MOUSE_BUTTON_UP` 时若手指移动没超过
   `TOUCH_DRAG_THRESHOLD`（16 逻辑像素）才算点按 —— 这时才 `set_active_item()` + `HIT`，
   而拖动过就什么都不选。
4. `set_active_item()` 里把 `m_scroll_offset` 清零，让键盘/鼠标重新按"滚动到选中项"定位。

> 这里踩了个坑：一开始把清零放在 `process_action()` 里，结果拖动完全没反应。原因是
> `MenuManager::process_input()` **每帧**都会调一次 `current_menu()->process_action(NONE)`，
> 于是偏移刚加上就被下一帧清掉。放在 `set_active_item()` 里才对 —— 它只在选中项真的变化时才走。

**顺带**：`LanguageMenu` 构造完会用 `set_active_item_id()` 把高亮放到当前语言那一项
（`g_dictionary_manager->get_language()`；英语走固定的 English 项，匹配不到则回落到 `<auto-detect>`）。
列表会因此自动滚到当前语言，用户一进来就知道现在用的是哪个。

## 0.4 已知遗留

- ~~**触摸坐标**：状态栏/导航栏偏移，点击落点偏上约 100px~~ —— **已不成立**。这条是窗口还是
  2720×1046 时的结论；现在窗口铺满 2720×1260，`m_rect.top/left = 0`、`m_scale = 2720/1368 = 1.9883`，
  实测 tap 设备坐标 872/1355 对应 `to_logical()` 的 438.56/681.49，与理论值
  `设备坐标 / 1.9883` **逐位吻合**，没有偏移。菜单点不中另有原因，见上面
  "菜单点不中：悬停命中判定没有跟着 `get_distance()` 走"。
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

1. 修 SDL 的 OHOS 键映射表（DPAD 等）。
2. 为 `com.supertux.game` 建 AGC 调试 Profile，脱离临时复用的 demo 包名。

> ~~校正触摸坐标偏移~~ 已解决且**无需修改**：窗口铺满 2720×1260 后 `m_rect.top/left = 0`，
> `to_logical()` 实测值与理论值逐位吻合，见「0.4 已知遗留」。

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
