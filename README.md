# FloatingClock · 漂浮时钟

macOS 原生极简指针时钟。圆角方形表盘，可拖动、始终置顶，在右上角菜单栏调整透明度、锁定位置。

## 开发

需要 macOS 13 或以上，以及 Xcode Command Line Tools。

```sh
bash scripts/build.sh
open dist/FloatingClock.app
bash scripts/test.sh
```

应用仅在本地运行，不联网，不需要辅助功能或屏幕录制权限。

## 使用

- 双击 `dist/FloatingClock.app`。应用不显示 Dock 图标，右上角菜单栏有一个时钟图标。
- 按住表盘拖动。位置会自动保存，下次启动会恢复。
- 点击菜单栏时钟图标，拖动透明度滑块实时调整，精度为 1%。0% 完全不透明，90% 最透明，默认 20%。透明度影响整个时钟。
- 选择“锁定位置（鼠标穿透）”后，时钟不再接收鼠标，底下的窗口可正常点击。再次从菜单栏取消勾选即可解锁。
- 可调整三档大小、暖白/墨黑/跟随系统、秒针与日期，也可临时隐藏时钟。
- “移回当前屏幕”能找回移动到其他显示器上的时钟。拔掉外接屏幕时会自动移回可见区域。
- 未锁定时也可右键点击时钟打开设置。
- 退出请使用菜单栏中的“退出漂浮时钟”。

时钟使用不抢焦点的原生 NSPanel，在普通应用与浮动窗口上方显示，并配置了全部桌面和全屏辅助窗口行为。macOS 锁屏、安全界面及系统菜单由系统管理，不承诺覆盖这些界面。

设置保存在用户偏好域 `local.lian.FloatingClock`，无需额外服务或权限。项目没有第三方依赖。

## 工程记录

本地 Git 按基础工程、时钟实现、菜单栏设置、验证交付分别提交。

## Apple 文档

- [NSPanel 的非激活窗口](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel)
- [跨全屏空间显示](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenauxiliary)
- [NSStatusItem 菜单栏入口](https://developer.apple.com/documentation/appkit/nsstatusitem)
