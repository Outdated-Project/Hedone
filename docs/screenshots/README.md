# 截图与素材 / Screenshots and credits

`settings.png`、`playback-hidden.png` 与 `playback.png` 来自实际运行的 Windows Flutter 界面。播放图分别记录控制栏自动收起与暂停后展开的状态。入口 `tool/readme_capture.dart` 复用正式版的 SettingsScreen、PostVideoScreen、PlaybackSession、主题、FFI 与 Rust 媒体网关；初始化独立游客目录，不导入用户账户、不构造片库数据。

These images capture the running production screens and transport with an isolated guest session. The capture entry point does not fabricate catalog records or successful responses.

播放素材为 **Big Buck Bunny**，(c) copyright 2008, Blender Foundation / www.bigbuckbunny.org，依据 [CC BY 3.0 及官方署名说明](https://peach.blender.org/about/) 使用。传输样片来自 [Test Videos 的公开 H.264 样片](https://test-videos.co.uk/bigbuckbunny/mp4-h264)。它仅用于截图与播放器验证，不代表黄果提供此影片。截图画面人工检查为非成人内容。

The film is used only to document and verify playback, not as a claimed upstream catalog item. The captured frames contain no adult content.

## 复现 / Reproduce

在 Windows 项目根目录运行（需要联网与原生构建工具链）：

```powershell
flutter run -d windows -t tool/readme_capture.dart --dart-define=HEDONE_CAPTURE_OUTPUT=D:/RustProject/Hedone/docs/screenshots
```

将输出路径替换为自己的工作区路径。工具先捕获设置页，再打开真实播放器，等待首帧与控制层自动隐藏，然后跳到 3 秒后短暂播放并暂停，直接导出 Flutter 渲染帧。`capture.json` 记录实际播放位置和 mpv 解码属性；不使用生成图、占位视频或截图拼接。不同分辨率、设备与上游网络可能产生不同结果。失败时保留错误，不伪造成功截图。截图后使用终端 `q` 退出；自动采集可添加 `--dart-define=HEDONE_CAPTURE_EXIT=true` 使应用自行退出。

Replace the output path with your checkout. Capture waits for a real video frame, seeks, pauses and exports the Flutter-rendered screen. Inspect the result before publishing: graphics backends may differ in texture capture support. `capture.json` records the actual playback position and decoder properties.
