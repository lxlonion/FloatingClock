# FloatingClock · 漂浮时钟

macOS 原生极简指针时钟。圆角方形表盘，可拖动、始终置顶，在右上角菜单栏调整透明度、锁定位置。

## 开发

运行已打包的应用需要 macOS 13 或以上。当前交付版面向 Apple Silicon Mac。

修改源码后重新编译需要 Xcode Command Line Tools；重新生成图标另需 Python 3。

```sh
bash scripts/build.sh
open dist/FloatingClock.app
bash scripts/test.sh
dist/FloatingClock.app/Contents/MacOS/FloatingClock --smoke-test
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
- 项目根目录的“启动时钟.command”可以重新启动应用，首次运行后会继续使用上次保存的位置和设置。

时钟使用不抢焦点的原生 NSPanel，在普通应用与浮动窗口上方显示，并配置了全部桌面和全屏辅助窗口行为。macOS 锁屏、安全界面及系统菜单由系统管理，不承诺覆盖这些界面。

设置保存在用户偏好域 `local.lian.FloatingClock`，无需额外服务或权限。项目没有第三方依赖。

## 工程记录

本地 Git 按基础工程、时钟实现、菜单栏设置、验证交付分别提交。

## 验证

- 5 项核心测试：时针分针秒针计算、透明度边界、偏好保存与损坏恢复、负坐标副屏、断开显示器后的位置恢复。
- 12 项 AppKit 检查：实际窗口层级、跨空间标记、不抢焦点、滑块改变窗口透明度、锁定穿透、菜单解锁、偏好保存、大小调整、屏幕边界、秒针设置、显示与隐藏。
- 本机启动并目视检查表盘和设置菜单，进行了拖动操作，确认位置写入偏好文件。
- 应用通过本地 ad-hoc 签名完整性检查。构建脚本将缓存留在工程的 `.build` 中。

可用 `bash scripts/regenerate-icon.sh` 重建图标。运行时不需要 Swift、Python 或第三方依赖。未设置开机自启动。

## Apple 文档

- [NSPanel 的非激活窗口](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel)
- [跨全屏空间显示](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenauxiliary)
- [NSStatusItem 菜单栏入口](https://developer.apple.com/documentation/appkit/nsstatusitem)
