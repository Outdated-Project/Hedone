# 构建与部署

使用 Flutter 3.47.9 / Dart 3.13.7、Rust 1.99.1。`pubspec.lock` 与 `rust/Cargo.lock` 必须一起提交。首次原生构建会安装 `rust/rust-toolchain.toml` 声明的目标标准库，需要联网和足够磁盘空间。

## 原生应用

```sh
flutter pub get --enforce-lockfile
flutter run -d windows
flutter build windows --release
flutter build linux --release
flutter build macos --release
flutter build ios --release --no-codesign
flutter build apk --debug --target-platform android-arm64
flutter build apk --release --target-platform android-arm64
```

只在对应宿主系统上执行平台构建。Linux 需要 GTK、libsecret、libmpv 与 C++ 工具链，具体软件包见 CI。Android 需要 SDK/NDK，Apple 需要 Xcode；iOS/macOS 正式分发还需要自己的签名、描述文件与公证流程。

Android release 不会偷用 debug 密钥。将签名信息放在忽略提交的 `android/key.properties`：`storeFile`、`storePassword`、`keyAlias`、`keyPassword`。未配置时产物未签名，不能当作可安装的正式发行包。保持 `com.hghub.huangguo` 应用标识；不要覆盖原有发行私钥。

从集成测试或 Debug/Profile 切换到 Release 时，使用上面的完整构建命令，不附加 `--no-pub`。Flutter 3.47 在该选项下也会跳过按构建模式重新生成插件注册文件，可能残留 `integration_test`，而 Gradle 的 Release 依赖已经排除了它。不要手工编辑 `GeneratedPluginRegistrant.java`。

评估动画使用 Profile/Release 构建。仓库的正式签名配置保持独立；交付文件名含 `local-test` 的 APK 仅供本机测试，使用开发签名，不作为商店发布包。

旧 WebView 的 localStorage 收藏/历史没有自动迁入 Flutter。旧明文 `session.json` 不导入，升级后重新登录；新会话使用系统安全存储。

Windows 工程与 Pub 缓存位于不同盘符时，Kotlin 增量缓存可能无法相对化插件路径，因此工程关闭 Kotlin 增量编译。Android 播放器原生构件由依赖的 Gradle 脚本从官方 GitHub Release 下载并校验；Java 的代理配置与系统代理不一定相同，下载超时需要修正构建环境网络，不能删除校验逻辑。

重新生成 FFI 绑定时使用与运行库相同的生成器：`cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked`，随后执行 `flutter_rust_bridge_codegen generate --config-file flutter_rust_bridge.yaml --no-auto-upgrade-dependency`。

## DNS 配置

默认不需要配置文件。原生端在应用数据目录、Web 服务在 `HEDONE_DATA_DIR` 中读取可选的 `dns.json`，修改后重启：

```json
{
  "mode": "auto",
  "upstreams": [
    { "ip": "223.5.5.5", "host": "223.5.5.5" },
    { "ip": "1.1.1.1", "host": "1.1.1.1" }
  ]
}
```

`auto` 保留通过安全检查的 VPN FakeIP 答案，普通域名优先使用 RecurseX DoH，失败时才采用安全的系统答案。这样不会把返回成功但被污染的系统解析直接当成正确结果；普通域名也会被发送到配置的 DoH 上游。`system` 完全遵循系统解析，适合必须统一 DNS 的受管网络；`encrypted` 只使用配置的加密上游。三种模式的最终地址均须通过网络策略检查。该版本 RecurseX/Courierust 的固定 IP DoH 要求 `host` 与 `ip` 相同，服务器证书必须包含该 IP 的 SAN；不允许关闭证书校验。最多配置 4 个真实公网 IP，使用 HTTPS 443 的 `/dns-query`。不接受任意自定义解析 URL。

加密 DNS 直连这些公共服务，不使用 `HEDONE_PROXY` 的 HTTP 代理配置。TUN 可以按自身策略接管；受管网络要求统一 DNS 时使用 `system`。系统信任库不可读取的平台使用随包附带的 Mozilla 公共 CA，证书包来源及更新方式见 [证书说明](../rust/assets/README.md)。

设置页的“网络自检”报告解析模式、系统/加密成功次数及错误。DNS 能恢复解析链路，但无法修复已撤销的域名、HTTP 404 或上游停止服务。`dns-cache.rxc` 只存解析缓存，可在应用退出后删除。

## Web 服务

```sh
flutter build web --release --no-web-resources-cdn
cargo build --manifest-path rust/Cargo.toml --release --features server --bin hedone-server --locked
```

产物为 `build/web/` 和 `rust/target/release/hedone-server`（Windows 带 `.exe`）。服务默认从当前工作目录读取 `build/web`，默认监听 `127.0.0.1:8080`。

Flutter 引导文件显式将 CanvasKit 指向随包的 `canvaskit/`。即使手工构建时漏掉 `--no-web-resources-cdn`，也不会因渲染器访问外部 CDN 被服务 CSP 拦截而白屏。该配置使用 Flutter 的[官方初始化接口](https://docs.flutter.dev/platform-integration/web/initialization)，不是第二套前端框架。

| 环境变量 | 用途 |
| --- | --- |
| `HEDONE_WEB_TOKEN` | 必填，至少 32 字节的随机访问密钥；浏览器第一次连接时输入 |
| `HEDONE_BIND` | 监听地址，默认 `127.0.0.1:8080` |
| `HEDONE_PUBLIC_ORIGIN` | 浏览器实际访问的完整 origin，默认 `http://127.0.0.1:8080` |
| `HEDONE_WEB_DIR` | Flutter Web 产物目录 |
| `HEDONE_DATA_DIR` | Rust 服务配置目录，默认 `.hedone-data` |
| `HEDONE_PROXY` | 指定 HTTP / SOCKS5 代理；失败不自动直连，代理侧解析和路由由部署者负责 |

密钥用密码管理器或系统随机源生成，不提交到仓库，不放在前端构建变量或 URL 里。开发时在当前 shell 设置环境变量，然后运行服务；浏览器打开配置的 origin。

远程部署必须使用 HTTPS 反向代理。前端、`/api/`、`/media/` 必须位于同一个 origin；代理要保留 Host，放行 Range，并关闭媒体响应缓冲。服务不启用跨域访问，也不信任客户端提供的转发主机头。`HEDONE_PUBLIC_ORIGIN` 必须与浏览器一致，否则请求被拒绝。

浏览器会话最多 128 个，12 小时过期。黄果账号令牌只在各自 Rust 会话内存中，服务重启后需要重新连接、登录。所有使用者共享部署访问密钥；它适合个人或受信任的小范围部署，不是带租户管理和计费能力的公共 SaaS。

Web 的线路与诊断日志由管理员管理。要更换服务线路，停止进程，修改数据目录下 `line.json` 的 `base` 为合法 HTTPS origin 后重启。镜像始终不能接收账号密码和令牌。

浏览器播放仍受浏览器编解码器、自动播放与上游可用性限制。media_kit 的 Web 适配依赖随包提供的 HLS 运行时；这是 Flutter 媒体依赖，不是恢复旧的 React/Vite 应用。

Windows 应分发 `build/windows/x64/runner/Release` 的完整目录，不能单独复制 hedone.exe。程序使用自身目录定位 Flutter data 与 hedone_core.dll，可从其他工作目录启动。重命名后遇到旧 CMake 目标缓存时，清理平台构建缓存再构建。移动端应用 ID 和安全存储键保留旧标识以保持升级兼容，界面、产物和包名统一为 Hedone。
