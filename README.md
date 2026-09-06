# SoundMate

这是 MacVolume 的通用语音/视频通话保护版本，应用显示名称为 SoundMate，使用独立的 Bundle ID：
`com.ivandrew.macvolume.communication`。

安装后的应用名称为 `SoundMate.app`；Bundle ID 和可执行文件名保持不变，以保留已有权限与配置。

SoundMate 与普通应用音量调节工具的核心区别，是专门解决通话过程中 macOS 自动压低其他发声软件音量的问题：通话时保持音乐、视频和系统声音的正常音量，不靠数字增益硬拉，因此避免额外失真。

这是一个普通的 macOS 窗口应用，启动后显示主窗口并出现在 Dock 中，不创建菜单栏状态项或弹出面板。关闭最后一个窗口会退出应用。

特点：

- 支持调整主窗口大小，并提供标准 macOS 应用菜单。
- 保留 Core Audio 多进程枚举、Helper 归并和独立音量控制功能。
- 任意用户应用同时使用输入和输出音频并持续被检测到时，自动识别为语音/视频通话；支持 Zoom、Teams、Discord、FaceTime、微信等应用。
- 通话期间为其他应用启用独立路由；各应用保存的音量设置保持不变。设备级 ducking 恢复可能影响同一输出设备上的所有应用，并非按应用关闭 ducking。
- 应用启动时不创建视频应用 Tap，也不写入系统 ducking 属性；只有检测到通话并存在待保护的媒体进程时才启用恢复循环。
- 通话保护保持用户原有增益，不再根据音乐电平自动放大，不再叠加第二次限幅；排除名单可在主窗口配置。
- 通过独立音频 Tap 路由播放；通话期间尝试恢复设备的临时 ducking 系数。HAL 的 `duck` 属性未公开文档，仅在存在、可写且数据长度符合预期时使用；不支持或写入失败会记录日志，不会退回倍增补偿。接口调用成功不等于实际通话效果已验证。
- 通话结束后延迟停止设备恢复操作，并清理不再需要的音频 Tap。
- 蓝牙耳机麦克风引起的传输音质下降无法由本功能修复；可在通话软件中选择 Mac 内置麦克风。需要以实际微信通话确认设备兼容性。
- 主窗口可直接选择系统默认输入、输出设备，并控制当前输出设备支持的硬件音量和静音。
- 内置系统隔空播放设备选择按钮。

设备属性的调查参考：[Unduck-Pro 的设备 ducking 实现](https://github.com/MrRockySL/Unduck-Pro/blob/main/Sources/DuckAudioCore/PerAppTapEngine.swift)。这里的 `duck` 属性并非 Apple 公开支持的 API，不能保证未来系统版本兼容。

## 验证

退出旧版后打开 `SoundMate.app`，将以前为补偿而调高的应用滑块恢复到 100%。播放同一段音乐，比较微信通话前、通话中和结束后的响度及音质。也需检查静音、通话中切换输出设备，以及未授权音频捕获时的表现。

本次已通过信号测试和 arm64 编译；当前默认输出设备的 `duck` 属性存在、可写且为 16 字节。尚未完成真实微信通话听音验证。查看日志中的 `Device ducking restore` 可分辨属性被支持还是只启用了原音路由。

## 构建

在 Xcode 中打开 `MacVolumeCommunication.xcodeproj`，或使用：

```bash
xcodegen generate --spec project.yml
xcodebuild -project MacVolumeCommunication.xcodeproj -scheme MacVolumeCommunication -configuration Release build
```

当前工程默认生成 `arm64 + x86_64` Universal 版本，最低支持 macOS 14.2。
