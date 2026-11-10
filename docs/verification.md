# 验证

```sh
flutter analyze
flutter test
cargo test --manifest-path rust/Cargo.toml --features server --locked
cargo clippy --manifest-path rust/Cargo.toml --features server --all-targets --locked -- -D warnings
flutter test integration_test/native_bridge_test.dart -d windows
```

布局测试覆盖 320、390、800、1440 逻辑像素，窄屏同时检查两倍字号。分页测试覆盖旧请求晚返回、失败页重试和销毁后完成。Rust 覆盖 URL/DNS/重定向策略、HLS 重写、Range、会话来源隔离、网关访问密钥、Web 会话与 CSRF、日志脱敏。

只有 `test/` 中使用本地测试数据。应用与服务没有演示数据、假登录、假更新或失败时替换成假成功的路径。

## 2026-11-10 本机记录

宿主为 Windows，Flutter 3.47.9 / Dart 3.13.7、Rust 1.99.1。

| 检查 | 已观察到的结果 |
| --- | --- |
| Dart 静态分析 | 无问题 |
| Flutter 回归 | 22 项通过；含 320 像素两倍字号、主题逐帧颜色一致性、连续切页、减少动态效果、异步 LRU、分页去重、500 集惰性构建、竖滑停稳选择，以及未初始化媒体插件时查看详情、选集和评论 |
| Rust 回归 | 45 项通过，6 项外网测试默认忽略；含字节预算 LRU、过期淘汰与 Range 共享分配检查 |
| Clippy | 所有目标及 server feature，警告视为错误，通过 |
| Windows | release 构建通过；打包库加载与原生桥接集成测试通过 |
| Android | arm64 debug APK 构建通过；未进行设备安装与播放验收 |
| Web | release 构建与 Rust 优化版服务构建通过 |
| Web HTTP 边界 | 本机真实进程验证 Origin、访问密钥、Cookie、CSRF、管理员操作限制、媒体会话和退出失效 |
| 上游只读联调 | 新版 Rust 服务在固定线路返回真实列表、详情、帖子；封面解密、HLS 清单与实际分片读取通过 |
| Windows 播放 | 实际 PlaybackSession / Video 经 Rust 网关读取时长、渲染首帧、静音播放、跳转进度、竖滑到下一集并继续播放通过；断言切集前后 Player 是同一实例 |
| RecurseX 联网 | `example.com` 与 `huangguoai.com` 的固定 IP DoH、Courierust TLS 校验、真实 A 记录查询分别通过 |

初次迁移时固定线路 1 的系统 DNS 解析失败。此次接入 RecurseX 后，`huangguoai.com` 加密解析成功，并使用该固定线路重新通过 Windows 真实列表、详情、首帧、播放和跳转集成测试。此前固定线路 2 的入口返回 HTTP 404，没有将 DNS 恢复误记为 HTTP 404 修复。没有将镜像加入账号凭据白名单，没有使用真实账号进行注册、评论、点赞或收藏写入验证。

布局可以用 `flutter test --dart-define=HG_CAPTURE_LAYOUTS=true` 导出到 `build/qa/`。图中使用明确标注的测试内容，只用于检查页面尺寸与排版。Windows 截图通道先后报告 `FrameArrived timed out` 和 `window capture timed out`，浏览器预览报告 access host unavailable；这些工具失败不计作视觉或浏览器播放验收通过。

macOS、iOS、Linux 尚未在本次 Windows 环境中构建或实机运行。没有测量跨设备帧率、长时间内存曲线或声画同步，也没有进行独立安全审计。

真实上游测试与离线测试分开：

```sh
cargo test --manifest-path rust/Cargo.toml net::tests::diag -- --ignored --nocapture
```

播放联调应使用你有权访问且当时可用的内容。指定 `HGHUB_TEST_VIDEO_ID` 后运行 `media::tests::live_play_chain`。它依次检查播放接口、清单与媒体分片，失败不能替代真实设备上的解码、音画同步和拖动验收。

Windows 播放器集成测试可传 `--dart-define=HGHUB_LIVE_BASE=<当时可用的 HTTPS origin>`。测试使用独立临时目录，从第一页读取一条内容，保持音量为零，并检查时长、播放和跳转；如果提供多集，继续验证竖滑切集、单播放器复用与下一集播放位置推进。不提供此参数时只运行本地桥接与边界检查。测试输出不打印媒体签名地址。

单独验证加密 DNS：`cargo test --manifest-path rust/Cargo.toml dns::tests::live_encrypted_dns -- --ignored --nocapture`。默认查询 `example.com`；通过 `HGHUB_DNS_TEST_HOST` 指定需要排查的域名。此测试绕开系统解析，实际验证 RecurseX/Courierust 链路，不把系统缓存命中计作加密 DNS 成功。

CI 工作流包含 Windows、Linux、macOS、iOS 编译与 Android ARM64 debug 构建。提交工作流不代表 CI 已执行；远端运行结果、Apple 签名和真机播放需要独立确认。发布前还应检查横竖屏、后台恢复、辅助功能、弱网、长片 Range 与长时间播放内存占用。
