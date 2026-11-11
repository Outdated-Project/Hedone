# 平板 ADB 实测：2026-11-11

设备为 WGRR-W19，Android API 31，2560 × 1600，320 dpi。显示器暴露 60 和 120 Hz 两种模式。测试时通过 USB 充电，省电状态为关闭；没有修改系统分辨率、刷新率设置或厂商白名单。

## 问题来源与处理

平板原先安装的 APK 带 `DEBUGGABLE` 标记，SHA-256 为 `3E5537431806321B87456AC6B5112A9AC0462D8D5D12D6B1DF2B28A5914EF967`，与工作区旧 `app-debug.apk` 完全一致。旧界面仍有折叠按钮，显示设备实际模式为 60 Hz。

核对签名一致后，通过 `adb install -r` 覆盖安装 `Hedone-1.0.1-navigation-arm64-local-test.apk`，没有卸载或清除应用数据。该 APK 的 SHA-256 为 `BC46B73BC7B668FDF84A699108BB1C3B1CC42EDD9D0EE17840E231BE5A613980`；安装后不再带 `DEBUGGABLE` 标记。

新版窗口报告 `preferredRefreshRate=120.00001`，显示设备实际切换到 mode 2，SurfaceFlinger 报告周期为 8,333,333 ns。横屏截图确认折叠按钮消失，文字侧栏保持展开。截图保留在本地 `build/qa/tablet-after-swipes.png`，不将真实内容封面提交到文档。

## 测量方式

在真实发现页执行四轮持续 2 秒的上下交替滑动，物理坐标为 `(1800,1300)` 与 `(1800,600)`。采集 Flutter BLAST SurfaceView 的 SurfaceFlinger `--latency` 历史，按实际呈现时间去重，去除无效时间戳，并舍弃首尾各 150 ms。使用实际呈现时间间隔计算该连续滑动窗口内的 FPS，保留原始三列时间戳。

三列分别是 desiredPresentTime、actualPresentTime、frameReadyTime，定义见 [AOSP FrameTracker](https://android.googlesource.com/platform/frameworks/native/+/cdb6b16dec3a541b455be99d075004cb2f0a0cd7/services/surfaceflinger/FrameTracker.cpp)。没有把 Android View 的 gfxinfo 或屏幕显示模式数字当作 Flutter 的实际呈现 FPS。

| 轮次 | 旧 Debug / 60 Hz：FPS | 新 Release / 120 Hz：FPS | 新版间隔 p95（ms） |
| --- | ---: | ---: | ---: |
| 1 | 49.43 | 112.97 | 16.61 |
| 2 | 51.89 | 119.71 | 8.35 |
| 3 | 53.14 | 119.11 | 8.34 |
| 4 | 57.20 | 117.29 | 8.34 |

新版四轮间隔中位数均约 8.312 ms，超过 1.5 个显示周期的间隔分别为 12、1、2、5 个。仍有掉帧，不能描述为锁定 120 FPS。两组同时变化了构建模式、刷新率策略和界面实现，不是某一项优化的隔离对照，也不能将结果外推为视频解码帧率或所有页面的稳定帧率。

原始记录：[旧 Debug](tablet-debug-before-frames.json)、[新 Release](tablet-release-120hz-frames.json)。

## 复现

先打开待测发现页并等待内容加载，保持相同方向、滚动位置与系统设置。测试期间不要手动操作。脚本在每轮前检查应用焦点，避免在其他应用内注入滑动。

```sh
adb devices -l
python tool/measure_android_frames.py --serial DEVICE_SERIAL --swipe 1800 1300 1800 600 --output build/qa/tablet-frames.json
```

此坐标仅适用于本次 2560 × 1600 横屏；其他设备应按实际内容区域调整。脚本不更改显示设置，不支持查询该 SurfaceFlinger 接口的设备会明确失败。

尝试通过 `cmd power set-mode 1` 验证省电策略时，设备因正在充电保持 `low_power=0`，因此本次不计省电场景通过。随后执行 `set-mode 0` 并确认原状态恢复。90/165 Hz、长时间运行、视频播放与断开充电后的省电场景尚未验收。
