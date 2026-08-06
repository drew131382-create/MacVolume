# MacVolume Clean Rebuild

这是 MacVolume 的全新菜单栏构建版本，使用独立的 Bundle ID：
`com.ivandrew.macvolume.clean`。

特点：

- AppKit 原生 `NSStatusItem`，固定显示 `MV` 文字按钮。
- 独立的用户偏好域，不继承旧版本菜单栏状态。
- 单实例保护，避免同时打开 DMG 副本和安装版时互相抢菜单栏状态项。
- 保留 Core Audio 多进程枚举、Helper 归并和独立音量控制功能。
