# 验证

## 2026-11-11：官方 Courierust 连接与 Range 回归

环境：Windows、Flutter 3.47.9 / Dart 3.13.7、Rust 1.99.1。当前仅引用 crates.io 的 Courierust 1.1.2 和 RecurseX 0.2.5，无本地库补丁。Cargo metadata 确认全部第三方依赖来自 registry。

| 检查 | 当前结果 |
| --- | --- |
| Rust 回归 | 64 项通过，8 项外网测试默认忽略；启用 server feature |
| Clippy | server feature 和全部 targets，警告视为错误，通过 |
| Flutter 静态分析 | 无问题 |
| Flutter 回归 | 39 项通过，含横竖屏连续切换、零尺寸视口、拖动中旋转、主题及线路设置 |
| Android 构建 | 包含地址回退、连接复用和条件 Range 的多架构 debug APK 构建通过 |
| 本次 Android 真机 | 本轮设备列表为空；没有安装测试包，播放与旋转未重新验收 |
| RecurseX 实际 DoH | `example.com` 的 A 记录解析通过 |
| 固定线路 1 HTTPS | 多地址回退后再次实测仍连接超时，未通过；系统代理模式按设计明确拒绝 |
| 交叉签名证书 | 本地夹具确认官方验证器仍拒绝完整交叉签名链；可达信任锚的短链验证通过，过期、无信任锚及签名损坏被拒绝 |

本地传输测试覆盖：固定 IP 连接保留原 Host、首个地址失败后回退、地址数量限制保留两个地址族、跨来源拒绝、认证头不残留、同一连接复用、POST 响应丢失不重放、配置代理拒绝、单响应超过 8 MiB 拒绝、chunked、截断与关闭连接定界。

Range 回归使用正式 Courierust 与本地 TCP 服务传输 9 MiB + 19 字节，验证十次 1 MiB 内的请求按需拼接，逐字节检查内容与逻辑响应长度。另覆盖进度跳转、长尾部区间、ETag 变化时停止交付、弱验证器拒绝、错误范围拒绝、忽略 Range 的小响应以及取消后不预取。这是协议回归，不是实际视频解码、真实 CDN 或低端设备性能测试。代理拒绝和证书错误不是功能成功，不能将其计为代理或 TLS 兼容性验收。

此前含维护分支的构建曾在 PLK110 真机通过首帧、横竖屏旋转、跳转进度和切集。该结果只说明此前的播放器改动接受过实测，不代表移除补丁后的网络栈仍有相同播放兼容性。未在 iOS、macOS、Linux 真机验收，也未测量低端手机帧时间、功耗和内存峰值。

普通 debug APK：`build/app/outputs/flutter-apk/app-debug.apk`。SHA-256：`914335815682208DAD22DC7BB3AC49DDA1B60C2FFCD37B153C69CF0DB5003007`。

## 重现

```sh
flutter analyze --no-pub
flutter test --no-pub
cargo fmt --manifest-path rust/Cargo.toml --check
cargo test --manifest-path rust/Cargo.toml --features server --locked
cargo clippy --manifest-path rust/Cargo.toml --features server --all-targets --locked -- -D warnings
cargo test --manifest-path rust/Cargo.toml live_encrypted_dns --locked -- --ignored --nocapture
```

`live_bundled_roots_validate_primary_origin` 是显式直连的适配器测试，不使用系统代理；它只验证固定线路 1 和随包 CA，不代表应用路由或所有线路可用。证书夹具使用固定时间，真实联网测试使用设备时钟。

Windows 原生桥接测试：

```sh
flutter test integration_test/native_bridge_test.dart -d windows
```

Android 播放与系统旋转测试：

```sh
flutter test integration_test/native_bridge_test.dart -d <Android设备ID> --dart-define=HGHUB_LIVE_BASE=https://huangguoai.com --dart-define=HGHUB_DEVICE_ROTATION=true
```

不提供 `HGHUB_LIVE_BASE` 时仅检查原生库加载、本地线路选择和网络边界。提供后使用独立临时数据目录，从真实列表选择内容，静音播放并检查首帧、进度、旋转及单播放器复用。测试结束应恢复普通应用 APK；测试包不能作为日常应用分发。

媒体单独联调需要 `HGHUB_TEST_VIDEO_ID`，运行 `media::tests::live_play_chain` 或 `transport::tests::live_manifest_can_reopen_same_origin` 的 ignored 测试。日志不打印带签名的媒体地址。上游不可用时测试失败，不用演示内容替换为假成功。

传输限制、证书路径与代理行为见 [依赖边界](dependencies.md)。单请求完整缓冲和新连接握手仍会影响首帧等待；不能把布局回归通过描述为全平台流畅播放或渲染性能已经达标。
