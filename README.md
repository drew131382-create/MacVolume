# MacVolume

macOS 菜单栏逐应用音量调节工具。基于 Core Audio Process Tap（macOS 14.2+），无需驱动，本地实时混音，独立控制每个应用的音量。

![macOS](https://img.shields.io/badge/macOS-14.2%2B-2ea44f) ![Swift](https://img.shields.io/badge/Swift-5.9-F05138)

## 功能

- **主音量与系统音量同步**：拖动主音量滑块即调节系统输出设备音量；按键盘音量键或系统改音量时，滑块实时跟随
- **逐应用音量/静音**：显示当前拥有 Core Audio 进程对象的应用，每个应用可独立调节音量占比（0%–100%）；Edge、微信等多进程应用会自动合并其 Helper
- **双击滑块复位**：双击某应用的音量滑块，立即复位为 100%
- **自动隐藏系统代理**：coreaudiod、ControlCenter 等系统进程不会出现在列表
- **音量记忆**：按 bundleID 记住每个应用的音量，下次打开自动恢复
- **开机自启动**：可选

## 要求

- macOS 14.2 及以上（依赖 Core Audio Process Tap API）

## 安装

从 [Releases](https://github.com/drew131382-create/MacVolume/releases) 下载 `MacVolume.dmg`，打开后将 `MacVolume.app` 拖入「应用程序」。

> **注意**：应用未使用苹果开发者证书签名（ad-hoc），首次打开时如被 Gatekeeper 拦截，请**右键 → 打开**；若仍提示"已损坏"，在终端执行：
> ```bash
> xattr -dr com.apple.quarantine /Applications/MacVolume.app
> ```
>
> 无需任何系统权限（不使用屏幕录制/麦克风），打开即可用。

## 从源码构建

需要 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 和 Xcode。

```bash
# 生成 Xcode 工程
xcodegen generate

# 构建 Debug 版本
make build
# 或直接构建并运行
make run
```

## 原理

- 通过 `AudioHardwareCreateProcessTap` 捕获指定进程的音频（`mutedWhenTapped`）
- 构建私有聚合设备，在 IOProc 中实时应用该应用的音量/静音（带防爆音 ramp）
- 主音量交由系统输出设备音量控制，最终响度 = 设备音量 × App 音量占比

## 项目结构

```
Sources/
  MacVolumeApp.swift         # 入口（MenuBarExtra）
  AudioProcessManager.swift  # 主管理：应用枚举、音量/静音状态
  AudioTapManager.swift      # tap 生命周期管理
  ProcessTapController.swift # 实时音频处理回调
  DeviceVolume.swift         # 系统设备音量监听与控制
  MixerView.swift            # 面板 UI
  VolumeState.swift          # 音量记忆（UserDefaults）
```

## 隐私

音频仅在设备本地实时混音，**不会录制、上传或存储**。
