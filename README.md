# Magic Mouse 中键

为了方便使用Apple Magic Mouse的用户在达芬奇调色软件使用中键进行色彩应用复制，给 Apple Magic Mouse 加一个可调的中键区域。用一根手指按下触控表面中央，即可触发鼠标中键。默认仅在 DaVinci Resolve 前台生效。

## 安装与使用

1. 从 [Releases](../../releases) 下载应用 ZIP，解压后将应用放入「应用程序」。
2. 打开应用，从菜单栏鼠标图标选择「启用权限…」，按 macOS 提示授权。
3. 从菜单栏打开「设置…」，拖动滑块调整中央区域宽度，并在鼠标示意图上试按，确认收到中键。
4. 在 DaVinci Resolve 的调色页先选目标镜头，再把光标移到源镜头缩略图上，单指按下鼠标中央即可应用调色。

支持 macOS 13 或更新版本，应用包含 Apple 芯片和 Intel 构建。应用使用 macOS 私有多点触控接口读取触点，系统更新可能影响兼容性。下载包采用临时签名，升级后如果权限开关已打开但应用仍提示未授权，可在菜单栏选择「重置权限记录…」并重新授权。更多操作见 [使用说明](使用说明.md)。

## 从源码构建

安装 Xcode 命令行工具，运行：

```sh
./build.sh
"./Magic Mouse 中键.app/Contents/MacOS/MagicMouseMiddle" --self-test
```

## 许可证

设计与版权归 J.zero 所有。源码按 [MIT 许可证](LICENSE) 开放。
