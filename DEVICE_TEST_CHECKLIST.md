# 待真机验证

本地构建支持 iOS 16 及以上版本。USB 摄像头采集需要支持原生外接视频输入的 iPad 与 iPadOS 17 或更新版本。

轨道 B 用于用户拥有完全控制权的 TrollStore / rootless 越狱设备。录屏和后台输出由用户主动启动，ReplayKit 保留系统广播授权流程。

- [ ] 在 iPhone 上分别添加前后摄像头，切换横竖屏、分辨率和帧率，确认预览、录像和推流的方向与尺寸一致。
- [ ] 在 iPad 上连接 UVC 采集卡，验证视频设备枚举、分辨率与帧率选择、录制期间断开和重新连接。
- [ ] 分别选择内置麦克风、蓝牙输入和 USB 声卡，验证音量电平、多轨录像、三种监听模式、来电中断及路由恢复。iOS 在同一音频会话中使用系统当前输入路由。
- [ ] 用 VideoToolbox 连续录制 H.264 和 HEVC Main10。分别检查 NV12、P010、Rec. 2100 PQ 和 HLG，核对成片的色彩标签与实际画面。观察长时间推流时的掉帧、音画同步及设备温度。
- [ ] 安装侧载 IPA，首次连接局域网推流目标及 WebSocket 控制器。确认“文件”可以访问 Documents/OBS，切到后台再返回时预览恢复，录像文件仍能打开。
- [ ] 通过 USB-C HDMI 和 AirPlay 连接外屏，分别投影节目、预览、单场景及单来源。检查外屏拔插、旋转和多视图。
- [ ] 在已有授权的设备上安装特权构型。确认已安装且架构兼容的动态插件可以载入，公共录像目录权限可用，`obs-ffmpeg-mux` 能生成并关闭 MKV、FLV 和 TS 文件。
- [ ] 安装轨道 B，核对主应用含 `com.apple.security.temporary-exception.mach-register.global-name`，扩展含对应的 `mach-lookup.global-name`，服务名均为 `com.obsproject.ios.screen.mach`，二者含同一 App Group。打开显示器采集源属性，通过系统广播选择器启动 OBS。日志应出现宿主 `IOSurface Mach receiver ready` 和扩展 `video transport: IOSurface Mach`。
- [ ] 切换到播放音频的应用，检查画面、旋转、色彩、混音器电平和录像音画同步。分别验证 BGRA、NV12 与设备支持的 P010，确认视频调用链为 `CVPixelBufferGetIOSurface` → `IOSurfaceCreateMachPort` → `mach_msg` → `IOSurfaceLookupFromMachPort` → `CVPixelBufferCreateWithIOSurface` → Metal，扩展不进入 `copy_video` / `write_slot`。音频继续通过共享页套接字传递。
- [ ] 暂停、恢复、停止并重启广播，确认暂停和结束时清除旧画面。持续广播并观察 Instruments 的内存与 Mach 端口数量，核对扩展峰值低于 20 MB，重复启停后端口及 IOSurface 使用计数回落。接收队列满时允许丢帧，视频不得切换到复制通道。
- [ ] 用移除命名 Mach 查询权限的独立测试签名运行扩展，确认仅在 `bootstrap_look_up` 失败时出现 `shared pages (Mach lookup failed)` 并启用视频共享页通道。恢复轨道 B 完整权限签名后，应重新默认使用 Mach 通道。
- [ ] 在只提供 ScreenCaptureKit 授权的 iOS 27 或更新版本中，从系统选择器授权整个屏幕，检查切换应用的画面与结束共享后的清屏。
- [ ] 核对轨道 B 主应用含 `com.apple.multitasking.systemappassertions`、`com.apple.private.memorystatus` 与后台 GPU 权限，`UIBackgroundModes` 含 `audio`。分别开始推流、录制或回放缓冲，确认日志出现 `Process assertion acquired`，后台音频引擎启动。切换应用、锁屏并持续输出，检查帧率、音画同步和成片完整性。
- [ ] 同时开启多个输出及 ReplayKit 广播，逐项停止，确认剩余任务仍保有断言与后台音频。停止最后一个输出和广播后，应立即停止静音引擎并出现 `Process assertion released`。在麦克风采集期间反复启停，检查输入路由和监听正常，再验证来电中断、音频路由切换后的恢复。
- [ ] 在支持 iOS 26 后台 GPU 延续任务的设备上，验证任务申请、取消及到期。仍持有有效进程断言时应继续输出，全部保活依据结束后应挂起后台视频，返回前台恢复。

本地已验证跨进程 Mach 传输保留原 IOSurface 身份，涵盖 BGRA、NV12 和 P010，并验证旋转元数据、发送失败清理及接收缓冲生命周期。上述设备权限生效、后台连续输出与扩展内存上限由真机执行本清单确认。
