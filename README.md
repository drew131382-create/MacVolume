# MacVolume Communication

这是 MacVolume 的通用语音/视频通话保护版本，使用独立的 Bundle ID：
`com.ivandrew.macvolume.communication`。

特点：

- 仅使用 AppKit 原生 `NSStatusItem`，显示随静音状态变化的系统音量图标，不创建独立菜单栏浮层。
- 控制页打开时，点击桌面、其他 App 或菜单栏其他区域会自动收起。
- 控制页顶部动态贴合所在屏幕的菜单栏下边缘，不使用固定屏幕坐标。
- 使用 AppKit 官方状态项自动保存机制，不写入私有菜单栏位置或可见性偏好。
- 单实例保护，避免同时打开 DMG 副本和安装版时互相抢菜单栏状态项。
- 保留 Core Audio 多进程枚举、Helper 归并和独立音量控制功能。
- 任意用户应用同时使用输入和输出音频并持续被检测到时，自动识别为语音/视频通话；支持 Zoom、Teams、Discord、FaceTime、微信等应用。
- 通话期间自动保护其他应用的音量，通话应用自身不被补偿；通话应用和各应用保存的音量设置保持不变。
- 补偿默认从保守增益开始，并根据音频 Tap 的可观测电平自适应调整，最高 4 倍；排除名单可在菜单页配置。
- 通话结束后延迟恢复临时补偿，并清理不再需要的音频 Tap。
- 菜单页可直接选择系统默认输入、输出设备，并控制当前输出设备支持的硬件音量和静音。
- 内置系统隔空播放设备选择按钮。

## 构建

在 Xcode 中打开 `MacVolumeCommunication.xcodeproj`，或使用：

```bash
xcodegen generate --spec project.yml
xcodebuild -project MacVolumeCommunication.xcodeproj -scheme MacVolumeCommunication -configuration Release build
```

当前工程默认生成 `arm64 + x86_64` Universal 版本，最低支持 macOS 14.2。
