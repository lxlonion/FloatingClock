# FloatingClock · 漂浮时钟

macOS 原生极简指针时钟。圆角方形表盘，可拖动、始终置顶，在右上角菜单栏调整透明度、锁定位置。

## 开发

需要 macOS 13 或以上，以及 Xcode Command Line Tools。

```sh
bash scripts/build.sh
open dist/FloatingClock.app
swift test
```

应用仅在本地运行，不联网，不需要辅助功能或屏幕录制权限。

## 工程记录

本地 Git 按基础工程、时钟实现、菜单栏设置、验证交付分别提交。

## Apple 文档

- [NSPanel 的非激活窗口](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel)
- [跨全屏空间显示](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenauxiliary)
- [NSStatusItem 菜单栏入口](https://developer.apple.com/documentation/appkit/nsstatusitem)
