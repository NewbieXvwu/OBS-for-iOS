# OBS-for-iOS 开发与移植任务清单（TODO.md）

> **目标受众**：本文件是面向本地 AI Coding Agent（包括 GPT-6.2 Sol 等高推理模型）的**唯一执行规范与任务清单**。请严格按本文要求推进，做到功能不阉割、轮子不乱造、进度不自阻。

## 0. Agent 行为红线（最高优先级，违反即停工回滚）

本节约束优先级高于一切默认“工程最佳实践”。请严格遵守：

1. **严禁哈希强迫症（Zero Unrequested Hashing）**
   * **禁止**为源码、tarball、静态库（`.a` / `.xcframework`）、构建产物、Info.plist、Entitlements 或 IPA 编写任何 SHA-256 / SHA-512 / MD5 校验清单、哈希锁定表或哈希比对脚本。
   * 依赖下载直接用 `curl -fL` 拉取指定版本号的官方发布包或固定 Git Tag；不要自己维护任何 `checksums.txt` 或 `verify-hash.py`。

2. **严禁自造门禁、元测试与自我阻塞（Zero Self-Invented Gates）**
   * **禁止**自行创建 `pre-flight`、`hard-gate`、`audit-harness`、`self-review`、`verify-runtime-*.py`、`check-syms.sh` 等未在本文明确要求的脚本或测试框架。
   * **禁止**在主线功能未完成时，以“需要先补完我自己设计的单元测试 / 静态检查 / 安全审计”为由拖延、分支开发或宣布被阻塞。
   * 每个阶段的验收标准**仅限本文各阶段末尾明确写出的那几条**，达标即勾掉任务进入下一步。

3. **严禁过度防御与并行回退垃圾（Zero Defensive Bloat & Dead Fallbacks）**
   * **禁止**为“理论上不可能发生”的场景编写多层防御包装或冗余校验。
   * **禁止**保留旧实现作为并行 fallback（改写某个接口后直接删掉旧代码，不要留老路径并行兜底）。
   * **禁止**引入本文未列出的 Linter、Formatter 或无意义的抽象包装层。

4. **复用优先，严禁无故手写造轮子（Reuse First, Prove Every Custom Wheel）**
   * **最高原则**：能直接复用官方 `obs-studio` 源码（`libobs`、`libobs-metal`、`mac-videotoolbox`、`mac-avcapture`、`coreaudio-encoder`、`obs-websocket`、`obs-webrtc`、全部跨平台插件、官方 `data/locale/` 与配置体系）的必须直接复用或打最小补丁；有成熟开源库可用的**严禁自己手写**。
   * **自研举证义务**：如果某个模块确实必须自己手写（而非复用官方实现或现成开源库），**必须在该模块主文件顶部注释以及对应的 git commit 说明中写明“自研必要性证明”**，列出已调研过的官方模块与现成开源库名称，并逐条说明为什么它们全部不适用且无法通过修改/打补丁适配。拿不出充分证明的一律视为违规造轮子。

5. **SwiftUI 严格 1:1 复刻原版，严禁自行设计、偷懒简化或自写 UI 文案**
   * **功能与信息架构 1:1 复刻**：必须以官方 `obs-studio/frontend/`（桌面 `.ui` 布局、菜单栏、Docks 面板、设置页全部 Tab、二级对话框与右键上下文菜单）为唯一设计蓝本，仅做移动端触控热区与横竖屏自适应排版，**严禁自行发明“极简版设计”、严禁偷懒砍掉高级/二级设置项**。
   * **严禁自写任何 UI 文案**：所有按钮、菜单、标签、表头、提示与弹窗文案，**必须直接解析加载官方 `obs-studio/frontend/data/locale/` 与各插件 `data/locale/` 下的 `.ini` 多语言词条文件**（沿用官方 `Str("...")` 与 `obs_module_text("...")` 键名），完整支持官方多语言切换。除 iOS 平台特有且官方词条库中确实不存在的极少数权限/双轨字段外，禁止在 SwiftUI 中硬编码自写 UI 字符串。

6. **持续推进到客观极限，禁止等用户实机验收，模拟器用完即关**
   * **严禁为了等待用户实机验收而暂停开发**：只要下游还有可编写、可编译、可在模拟器中验证的任务，必须持续向前推进，直到客观上所有能在当前环境完成的工作全部做完、确实无法再往前推进为止，最后再统一给出一份简洁的“待真机验证项清单”。
   * **模拟器尽力验收与强制清理**：所有编译、启动、UI 复刻、场景编排、本地推流/录像、WebSocket 联调等尽量通过 `iphonesimulator` 构型 + `xcrun simctl` 自动化验证；**每次模拟器测试结束后必须立即执行 `xcrun simctl shutdown all` 并彻底退出 `Simulator.app`（`osascript -e 'quit app "Simulator"' 2>/dev/null || killall Simulator 2>/dev/null || true`），严禁让模拟器在后台长期滞留占用系统资源。**

7. **认真通读参考仓库 `~/OBS-for-Android`（只读不改）**
   * 认真、系统地阅读 `~/OBS-for-Android`（不限制读取范围，包括文档、构建脚本、`libobs`/`libobs-opengl` 移植、各插件实现、前端适配与排坑注释），充分吸收其跨平台移植架构与真机稳定性经验。
   * 严格保持**只读**：绝对不要对 `~/OBS-for-Android` 执行任何写入、构建或 `git` 修改；同时绝不照搬 Android 专属 API（EGL/GLES3、MediaCodec、Java 宿主、Qt Widgets）。

8. **严禁污染全局环境**
   * 所有下载的编译工具、第三方库源码、中间构建产物与预编译静态库，**必须全部放在本仓库工作目录下且被 `.gitignore` 忽略的目录内**。不得执行 `brew install` 修改系统全局环境（仅允许只读调用本机已安装的 Xcode / Command Line Tools）。

9. **严禁以“当前环境缺少特权/授权接口/真机”为由将任务标为受阻（Zero False Blocking）**
   * Entitlements 是打包期静态写入 plist 的配置，私有 API 均采用 `dlsym` / `NSClassFromString` 运行时动态解析，两者在 Mac 上均可 100% 完成编码、编译、链接与打包，**不存在“Mac 编译环境缺少授权接口”的阻塞**。
   * 凡属“需真机运行期才能验证权限是否生效”的项，一律完成全部代码、Entitlements 注入与产物打包后勾选完成，并将真机验证步骤写入 `DEVICE_TEST_CHECKLIST.md`，严禁标为受阻停工。

## 1. 仓库拓扑与本地隔离目录规范

本项目采用 **“独立外壳仓库 + 官方 `obs-studio` Fork 作为 Git Submodule”** 的双仓结构，严格保持对上游 `obs-studio` 的极薄侵入。

### 目录结构

```text
OBS-for-iOS/                          # 本独立外壳仓库（工作根目录）
├── TODO.md                           # 本任务清单
├── .gitignore                        # 忽略所有本地工具链、依赖与构建缓存
├── deps-ios/                         # 第三方依赖交叉编译脚本（入库）
│   ├── versions.sh                   # 依赖版本清单
│   └── build.sh                      # 编译 iphoneos(arm64) + iphonesimulator(arm64) 静态库
├── scripts/                          # 精简构建、模拟器验证与双轨打包脚本（入库）
│   ├── build-libobs-ios.sh           # 编译 libobs + 静态插件为 XCFramework
│   └── package-ipa.sh                # 打包非越狱 IPA 与特权 IPA / .deb
├── obs-studio/                       # Git Submodule（指向 NewbieXvwu/obs-studio 的 ios-port 分支）
│   ├── cmake/ios/                    # 新增：iOS 工具链与平台配置
│   ├── libobs/obs-ios.{h,c}          # 新增：iOS 单向宿主总线
│   ├── libobs-metal/                 # 最小化改造：适配 UIView / CAMetalLayer + 10-bit/HDR
│   └── plugins/
│       ├── CMakeLists.txt            # 追加 OS_IOS 插件清单与静态注册表生成
│       ├── ios-videotoolbox/         # 复用改造自 mac-videotoolbox（8-bit + 10-bit/HDR 零拷贝）
│       ├── ios-avcapture/            # 复用改造自 mac-avcapture（相机 + iPadOS 17+ 原生 UVC）
│       ├── ios-audio/                # AVAudioEngine 采集 + 监听 + 复用 coreaudio-encoder
│       ├── ios-browser/              # WKWebView 透明浏览器源
│       └── ios-screen/               # 按能力位切换公/私屏幕采集
├── ios-app/                          # SwiftUI + Objective-C++ 主工程（入库）
│   ├── CoreBridge/                   # C/ObjC++ 桥接、官方 .ini 词条加载器、静态插件注册
│   ├── HostSideload/                 # 轨道 A：非越狱侧载宿主实现（公开 API）
│   ├── HostPrivileged/               # 轨道 B：越狱 / TrollStore 特权宿主实现
│   ├── BroadcastUploadExtension/     # 极简 ReplayKit 跨进程转发扩展（不链接 libobs）
│   ├── Entitlements/                 # Sideload.entitlements 与 Privileged.entitlements
│   └── UI/                           # 1:1 复刻官方 OBS 前端全部面板、设置页与对话框
│
│   # ====== 以下目录全部写入 .gitignore，严禁入库 ======
├── .workspace-tools/                 # 本地下载/解压的 cmake、ninja、pkg-config、autoconf 等工具
├── .deps-src/                        # 下载的第三方库源码压缩包与解压目录
├── .deps-build/                      # 第三方库交叉编译中间目录
├── .deps-prebuilt/                   # 编译产出的 iphoneos-arm64 与 iphonesimulator-arm64 静态库
└── .build/                           # libobs CMake 构建目录、Xcode DerivedData 与输出 IPA
```

### 双轨架构定位

| 轨道 | 目标环境 | 核心能力边界 | 打包产物 |
| :--- | :--- | :--- | :--- |
| **轨道 A（主线）** | 非越狱侧载（AltStore / SideStore / 个人自签） | 完整前台导播台：1:1 官方 UI/工作室模式/多音轨/重放缓冲/外接屏投影/WebSocket/WHIP/SRT/RIST/10-bit HDR/相机/iPadOS 原生 UVC/WKWebView、`hybrid_mp4`/`hybrid_mov` 录像、静态插件 | `OBS-Sideload.ipa` |
| **轨道 B（增量）** | 越狱（rootless） / TrollStore | 在轨道 A 全部能力上，运行时探测私有 Entitlement 解锁：ReplayKit 轻量跨进程转发 + 后台 GPU 保活、可选动态探测私有抓屏、外部 `.dylib` 动态插件加载、`obs-ffmpeg-mux` 伴生进程（MKV/FLV/TS）、公共目录录像 | `OBS-Privileged.ipa` / `.deb` |

## 2. 阶段执行清单

请严格按顺序连续推进，每完成一项将 `[ ]` 改为 `[x]` 并做小步提交，除非客观上完全无法继续，否则不要中途停下等待人工验收。

### 阶段 0：通读参考仓、仓库初始化与本地双构型工具链

- [x] **0.1 系统通读 `~/OBS-for-Android`（只读，不限范围）**
  * 完整阅读其文档、构建链、`libobs` 宿主总线、`libobs-opengl` 移植、各类原生插件与前端适配代码及排坑注释，总结可复用的工程经验（如插件白名单、无子进程 muxer 策略、前后台保护、容量检查等），写入简短的移植备忘供后续阶段对照。
- [x] **0.2 初始化 `OBS-for-iOS` 外壳仓库与 `.gitignore`**
  * `.gitignore` 必须完整忽略：`.workspace-tools/`、`.deps-src/`、`.deps-build/`、`.deps-prebuilt/`、`.build/`、`.DS_Store`、`*.xcuserdata`。
  * 创建目录 `deps-ios/`、`scripts/`、`ios-app/`。
- [x] **0.3 挂载官方 `obs-studio` Fork 为 Git Submodule**
  * 将 `NewbieXvwu/obs-studio` 作为 submodule 挂载到 `obs-studio/`，切出独立分支 `ios-port`。
  * **约束**：不得修改 `obs-studio/frontend/` 下的桌面 Qt 源码（仅将其作为 1:1 复刻蓝本和 `.ini` 词条/资源数据源）。
- [x] **0.4 配置工作区隔离构建工具（`.workspace-tools/`）**
  * 检查本机 Xcode / Command Line Tools（`iphoneos` 与 `iphonesimulator` SDK）。
  * 所有缺失的构建工具（`cmake`、`ninja`、`pkg-config`、`autoconf`、`automake`、`libtool`、`gas-preprocessor.pl` 等）一律下载解压至 `.workspace-tools/bin/`，脚本内统一 `export PATH="$PWD/.workspace-tools/bin:$PATH"`。
- [x] **0.5 编写 `deps-ios/versions.sh` 与 `deps-ios/build.sh`（支持真机 + 模拟器双构型）**
  * 为 `iphoneos-arm64` 与 `iphonesimulator-arm64`（`IPHONEOS_DEPLOYMENT_TARGET=16.0`）交叉编译静态库至 `.deps-prebuilt/`，确保不因缺库而阉割官方功能：
    * 核心与编解码：`simde`、`uthash`、`jansson`、`x264`、`x265`（可选软编兜底）、`mbedtls`、`ffmpeg`（启用常用解封装/解码 + `--enable-videotoolbox` + `--disable-programs`）。
    * 滤镜与文字：`speexdsp`、`rnnoise`、`freetype`。
    * 网络流与远控协议：`libsrt`、`librist`（保留官方 SRT/RIST 推流）、`libdatachannel` 或官方 `obs-webrtc` 依赖（保留 WHIP 超低延迟推流）、`asio` + `websocketpp` + `nlohmann/json`（保留官方 `obs-websocket` 5.x 远程导播控制）。
  * 严禁在下载或编译脚本中添加 SHA-256 哈希校验逻辑。
- [x] **阶段 0 验收**：`.deps-prebuilt/` 下产出 `iphoneos-arm64` 与 `iphonesimulator-arm64` 静态库（`lipo -info` 校验架构无误），且 `git status` 中无任何工具链或依赖文件被追踪。

---

### 阶段 1：`obs-ios.h` 宿主总线、`libobs-metal`、零拷贝硬编与静态插件核心

- [x] **1.1 在 `obs-studio/libobs/` 新增 `obs-ios.h` 与 `obs-ios.c`**
  * 定义能力位枚举 `obs_ios_track_flags`（`OBS_IOS_CAP_BACKGROUND_GPU`、`OBS_IOS_CAP_PRIVATE_SCREEN`、`OBS_IOS_CAP_DYNAMIC_PLUGIN`、`OBS_IOS_CAP_SPAWN_MUXER`、`OBS_IOS_CAP_PUBLIC_STORAGE`）。
  * 定义单向回调表 `struct obs_ios_host`（`get_capabilities`、`set_keepalive`、`start_screen_capture`、`stop_screen_capture`、`get_recording_dir`、`load_extra_plugins`），提供 `obs_ios_set_host()` 及默认包装函数。
- [x] **1.2 配置 `obs-studio/cmake/ios/` 与全功能插件白名单 + 静态模块注册**
  * 新建 `obs-studio/cmake/ios/defaults.cmake`：关闭 `ENABLE_UI`、`ENABLE_BROWSER`（CEF）、`ENABLE_SCRIPTING`、`ENABLE_VIRTUALCAM`、`ENABLE_SERVICE_UPDATES`；**保持开启** `ENABLE_WEBSOCKET=ON`、`ENABLE_NEW_MPEGTS_OUTPUT=ON`（SRT/RIST）、`ENABLE_WEBRTC=ON`（WHIP）。
  * 在 `obs-studio/plugins/CMakeLists.txt` 增加 `if(OS_IOS)` 分支，纳入全部可复用的官方跨平台插件：`image-source`（含颜色源、图片源、幻灯片 `slideshow`）、`obs-transitions`、`obs-filters`、`text-freetype2`（通过 CoreText / 系统字体目录实现 `find-font-ios.m`，不引 Fontconfig）、`rtmp-services`（复用 stub 顶住 `file-updater`，完整保留 83+ 平台 `services.json`）、`obs-outputs`（RTMP/RTMPS/增强型 RTMP/Hybrid MP4 & MOV/Replay Buffer）、`obs-ffmpeg`（含 `ffmpeg_source` 媒体源与 AAC/音频编码，轨道 A 不拉 `ffmpeg-mux` 子进程）、`obs-x264`、`obs-webrtc`、`obs-websocket`。
  * 生成 `ios-static-modules.c` 静态模块注册表，在启动期完成全量插件注册，不依赖 `dlopen`；同时打包所有插件的 `data/`（含 `.effect` 着色器与全部 `locale/*.ini`）到 App Bundle。
- [x] **1.3 直接复用改造 `obs-studio/libobs-metal/` 到 iOS**
  * 将 macOS `NSView` 替换为 iOS `UIView` / `CAMetalLayer`。
  * 将 `MTLStorageModeManaged` 替换为 iOS 统一内存支持的 `MTLStorageModeShared` / `MTLStorageModePrivate`。
  * **完整保留 10-bit / HDR（P010 / RGBA16F / HLG / PQ）色彩管线支持**，不要照搬 Android 裁剪 10-bit。
  * 移除 macOS 独有的多显卡枚举与 `CVDisplayLink`，增加前后台切换时 Metal 命令队列安全排空钩子。
- [x] **1.4 复用改造 `obs-studio/plugins/ios-videotoolbox/`**
  * 直接基于官方 `mac-videotoolbox` 改造为 iOS H.264 / HEVC（含 Main10 10-bit HDR）硬编插件。
  * 通过 `CVMetalTextureCache` 将合成后的 Metal 纹理零拷贝映射到 `CVPixelBuffer` 送入 `VTCompressionSession`，保留完整码率控制（CBR/VBR/CRF）、Profile、Keyframe Interval 与动态码率（Dynamic Bitrate）支持。
- [x] **1.5 编写 `scripts/build-libobs-ios.sh` 并打通模拟器无界面推流/录像闭环**
  * 产出包含 `iphoneos` + `iphonesimulator` 的 `libobs.xcframework`（或静态归档集）到 `.build/ios/`。
  * 在 `ios-app/` 建立最小可启动工程，在模拟器中加载 `color_source` + `text-freetype2` + `obs-filters` + 编码器 + `mp4_output`（Hybrid MP4）与本地 RTMP 推流验证。
- [x] **阶段 1 验收**：`iphoneos` 与 `iphonesimulator` 均编译链接通过；在 iOS Simulator 中自动启动 App 完成 `hybrid_mp4` 录像（用 `ffprobe` 校验轨道正常），随后立即关闭并清理模拟器。

---

### 阶段 2：1:1 复刻官方前端（SwiftUI）与核心原生采集源

- [x] **2.1 搭建 `ios-app/CoreBridge/` 与官方 `.ini` 词条加载器**
  * 封装 `libobs` 生命周期、配置管理、场景/来源/转场/滤镜/混音器/热键/推流/录像/重放缓冲 API。
  * **直接复用官方本地化资源**：实现 `OBSLocale` 加载器，读取打包进 Bundle 的 `obs-studio/frontend/data/locale/*.ini` 与各插件 `data/locale/*.ini`，SwiftUI 侧全部通过 `OBSLocale.str("Basic.Main.StartStreaming")` 等官方 Key 渲染文本，支持跟随系统或设置页手动切换官方语言。
- [x] **2.2 复用改造 `ios-avcapture` 与 `ios-audio` 插件**
  * `ios-avcapture`：基于官方 `mac-avcapture` 改造，使用 `AVCaptureSession` + `AVCaptureDeviceDiscoverySession` 枚举前置、后置及 iPadOS 17+ `.external` 原生 UVC 采集卡，零拷贝 `CVPixelBuffer` 入 Metal，正确处理设备旋转与分辨率/帧率档位。
  * `ios-audio`：基于 `AVAudioEngine` / `AudioUnit` 采集内置麦、蓝牙、USB 声卡，监听 `AVAudioSession` 路由变更与通话中断自动恢复；复用官方 `coreaudio-encoder` 的 AudioToolbox AAC 硬编；完整实现音频监听输出（`Monitor Off / Monitor Only / Monitor and Output`）。
- [x] **2.3 1:1 复刻官方 OBS 主界面与完整工作区（SwiftUI）**
  * 严格对照 `obs-studio/frontend/` 复刻全部核心面板（横屏为标准导播台多 Dock 布局，竖屏/小窗自适应切换分页或抽屉，不砍任何功能）：
    * **主预览画布（`CAMetalLayer`）+ 工作室模式（Studio Mode）**：支持单画布与双画布（Preview + Program）切换、转场推杆（T-Bar）与快速切换按钮；支持来源选中框、拖拽移动、等比/自由缩放、边缘裁剪（Crop）、锁定与对齐吸附。
    * **场景（Scenes）与来源（Sources）面板**：完整支持增删改名、排序、显隐、锁定、**来源分组（Group）**、**场景嵌套（Scene as Source）**、来源右键/长按完整上下文菜单（含**变换 Transform 对话框**：位置/旋转/尺寸/裁剪/边界框/适配屏幕/拉伸/居中；**显示/隐藏转场**；**滤镜 Filters**；**属性 Properties**）。
    * **场景转场（Scene Transitions）面板**：转场类型切换（Cut/Fade/Swipe/Slide/Stinger/Luma Wipe）、时长（ms）、属性页与场景覆盖转场（Transition Override）。
    * **混音器（Audio Mixer）与高级音频属性对话框**：真峰值电平表（Peak Meter，dB 刻度与削波指示）、音量推子、静音、以及完整的**高级音频属性（Advanced Audio Properties）**（音量 dB/百分比、单声道、声道平衡、同步偏移 Sync Offset、监听模式、Track 1–6 多音轨勾选）。
    * **控制（Controls）与统计（Stats）面板**：开始/停止推流、开始/停止录像、**暂停/恢复录像（Pause/Resume）**、**重放缓冲（Replay Buffer）启停与保存**、工作室模式开关、设置、退出；Stats 面板实时展示 FPS、渲染平均耗时、渲染/编码/网络丢帧、CPU/内存与实时码率。
    * **顶部菜单栏**：复刻官方“文件（含查看录像、日志查看器 Log Viewer） / 编辑（撤销重做、变换、高级音频） / 视图（Docks、Stats、Multiview） / 配置文件（Profiles 增删改导入导出） / 场景集合（Scene Collections 增删改导入导出） / 工具（WebSocket 服务器设置等）”。
- [x] **2.4 1:1 复刻官方设置对话框（Settings）全部可用 Tab 与通用 `OBSPropertiesView`**
  * 实现通用的 `OBSPropertiesView`，递归解析任意 `obs_properties_t` 自动生成全部官方控件类型（Bool、Int/Float 滑块与输入框、List、EditableList、Path/File、Color、Font、Text、Group、Button），严禁跳过控件类型或自写文案。
  * 1:1 复刻官方 Settings 全部适用分页：**常规（General，含语言/自动重连/确认提示）**、**直播（Stream，完整 83+ `rtmp-services` + 自定义 RTMP/SRT/RIST/WHIP）**、**输出（Output，完整 Simple 与 Advanced 模式、推流/录像/音频多轨/重放缓冲独立页签，非越狱态按能力位隐藏需子进程的容器）**、**音频（Audio，采样率/声道/全局音频设备/监听设备/峰值衰减）**、**视频（Video，基础/输出分辨率/缩放滤镜/FPS）**、**热键（Hotkeys，接入 `obs_hotkey_*` 支持外接键盘快捷键）**、**高级（Advanced，含色彩格式 NV12/I420/P010、色彩空间 Rec.709/2100 PQ/HLG、推流延迟、自动重连、动态码率）**。
- [x] **阶段 2 验收**：在 iOS Simulator 中自动构建、安装并启动 App，验证所有主面板、工作室模式、设置页全 Tab、官方多语言词条加载、来源变换、高级音频属性、Stats 面板及 WebSocket 端口监听正常，无崩溃与缺失文案，随后立即关闭并清理模拟器。

---

### 阶段 3：浏览器源、外接屏投影、多视图与轨道 A 侧载发布闭环

- [x] **3.1 实现 `ios-browser` 插件（WKWebView 浏览器源）**
  * 托管系统 `WKWebView`，支持自定义 URL、分辨率、帧率上限、自定义 CSS 注入、刷新缓存与透明背景（`isOpaque = false` + `clear` 背景保留 Alpha）。
- [x] **3.2 实现多视图（Multiview）与外接显示器全屏投影仪（Projector）**
  * 复刻官方 Multiview 网格布局。
  * 利用 iOS `UIWindowScene` 外部屏幕连接通知，将官方全屏投影仪（Fullscreen Projector：Program / Preview / 单场景 / 单来源）直接通过 `CAMetalLayer` 输出至 USB-C HDMI 或 AirPlay 外接显示器。
- [x] **3.3 完善轨道 A 前后台 Metal 队列排空、沙盒共享与容量预警**
  * 轨道 A 收到 `willResignActive` / `didEnterBackground` 时，同步排空当前 `MTLCommandBuffer` 并挂起视频线程，杜绝后台提交 GPU 被杀；回到前台自动重建可绘制面。
  * 在 `Info.plist` 开启 `UIFileSharingEnabled` 与 `LSSupportsOpeningDocumentsInPlace`，录像默认落盘 `Documents/OBS`；通过 `volumeAvailableCapacityForImportantUsage` 检测剩余空间（低于 100 MiB 安全停录）。
- [x] **3.4 编写 `scripts/package-ipa.sh`（轨道 A）**
  * 使用最小权限 `Sideload.entitlements`（相机、麦克风、本地网络）产出无个人证书绑定的纯净 `OBS-Sideload.ipa` 至 `.build/release/`。
- [x] **阶段 3 验收**：模拟器完成 WKWebView 源加载、Multiview 渲染与 `OBS-Sideload.ipa` 完整打包产物结构验证（随即关闭模拟器）；真机专属项（UVC 采集卡、外接 HDMI 屏、长时间硬编热稳）记录进待真机验证清单，**不阻塞进入阶段 4**。

---

### 阶段 4：轨道 B（越狱 / TrollStore 特权宿主）增量解锁

- [x] **4.1 实现运行时特权探测与 `ios-app/HostPrivileged/`**
  * 启动时探测进程实际持有的 Entitlements 或 rootless 越狱路径，动态返回 `obs_ios_track_flags`。
  * 所有私有类/私有符号一律通过 `NSClassFromString` / `dlsym` 动态解析，解析失败即清零对应能力位，平滑退回轨道 A。
- [x] **4.2 实现跨应用屏幕采集（`ios-screen`）与后台保活通路（严禁标为受阻）**
  * **主通路（ReplayKit 轻量转发 Extension + 主进程合成）**：广播扩展不链接 `libobs`。主进程注册 `com.obsproject.ios.screen.mach`，扩展查询端口，使用 `IOSurfaceCreateMachPort` 与 `MACH_MSG_TYPE_MOVE_SEND` 发送系统 IOSurface。宿主通过 `IOSurfaceLookupFromMachPort` 和 `CVPixelBufferCreateWithIOSurface` 接入既有 Metal 管线，视频全程不经 CPU 复制。只有 `bootstrap_look_up` 失败时启用共享页视频通道，音频 PCM 沿用 App Group 套接字。主应用及扩展分别声明命名服务的注册与查询权限，接收和发送失败路径均释放端口，缓冲及 GPU 消费结束后归还 IOSurface。扩展内存低于 20 MB 的运行期验证列入真机清单。
  * **后台保活与特权 Entitlements**：主应用声明 `com.apple.multitasking.systemappassertions`、`com.apple.private.memorystatus` 与后台 GPU 权限。运行时通过 `dlopen` / `NSClassFromString` 解析 `BKSProcessAssertion`，在输出或用户授权的广播活跃时持有断言及 `AVAudioSession` 静音引擎，最后一个任务停止时立即释放。`UIBackgroundModes` 含 `audio`，原生前端输出事件与广播连接共同管理生命周期。
  * **验收**：Mac 端完成全部代码、`BroadcastUploadExtension` 嵌入、`Privileged.entitlements` 静态写入与 `OBS-Privileged.ipa` 重新打包，即视为本项完成；真实跨应用抓屏与后台 GPU 连续推流记入 `DEVICE_TEST_CHECKLIST.md`，绝不允许标为受阻。
  * **本地验收**：`iphoneos` 与 `iphonesimulator` 编译链接通过。跨进程 Mach 测试确认 IOSurface 身份相同，覆盖 BGRA、NV12 和 P010，并验证旋转元数据、队列满发送失败清理和缓冲使用计数回落。三份安装包已重新生成并核对宿主及扩展的签名权限，设备权限和长时间后台运行步骤见 `DEVICE_TEST_CHECKLIST.md`。
- [x] **4.3 解锁外部 `.dylib` 动态插件加载与公共目录存储**
  * 检测到 `OBS_IOS_CAP_DYNAMIC_PLUGIN` 时，在静态核心插件之后额外扫描 `/var/jb/Library/OBS/Plugins` 或自定义目录调用 `obs_open_module` 加载外部插件。
  * 检测到 `OBS_IOS_CAP_PUBLIC_STORAGE` 时，开放自定义路径写入 `/var/mobile/Media/OBS`。
- [x] **4.4 解锁 `obs-ffmpeg-mux` 伴生进程与全容器格式**
  * 轨道 B 打包附带 `obs-ffmpeg-mux` 二进制；检测到 `OBS_IOS_CAP_SPAWN_MUXER` 时，设置页自动解锁 MKV / FLV / TS 等全部封装格式。
- [x] **4.5 完善 `scripts/package-ipa.sh`（轨道 B 双产物输出）**
  * 注入 `Privileged.entitlements`，单次脚本同时输出 `OBS-Sideload.ipa`、`OBS-Privileged.ipa`（TrollStore）与 rootless `.deb` 至 `.build/release/`。
- [x] **阶段 4 验收**：单次构建脚本同时产出两套完整安装包，确认权限文件（Entitlements）与附带二进制差异符合预期；汇总最终《待真机验证清单》结束交付。
  * `.build/release/` 已生成 `OBS-Sideload.ipa`、`OBS-Privileged.ipa` 与 `OBS-Privileged.deb`。轨道 B 的广播扩展、命名 Mach 权限和后台权限均已写入安装包，rootless 包中宿主及扩展权限一致，轨道 A 保持原有最小权限。

---

## 3. 工作流与交付纪律

1. **连续推进，小步提交**：按 `[ ]` 逐项完成并勾选为 `[x]`，每完成一个小项做一次简洁 git commit，**不要做完一个阶段就停下来问“是否继续”或“请你在真机上测试后再告诉我”**，持续推进到所有可在本地完成的工作全部结束。
2. **保持 Diff 克制**：禁止顺手重构无关代码或编写未要求的检查脚本。
3. **模拟器随用随关**：任何涉及 `xcrun simctl` 的验证命令，必须在脚本 `trap EXIT` 中绑定清理逻辑，确保哪怕验证失败也会自动 `shutdown` 并退出 `Simulator.app`。
4. **真机阻塞项记录而不停工**：遇到只能在真实 iOS 设备上验证的环节（如物理 UVC 采集卡、真实摄像头画面、越狱后台抓屏），记录到仓库根目录的 `DEVICE_TEST_CHECKLIST.md` 后继续往下推进，直到全部代码与构建产物就绪。
