# 依赖边界

依赖来自正式软件包仓库，版本写入锁文件。不维护 vendor 目录、源码拷贝或 `[patch.crates-io]`。应用负责资源预算和信任策略，协议与密码学实现交给库。

## HTTP 与 TLS

内容、图片和媒体请求使用 Reqwest 0.12 / Rustls 0.23。Rustls 根据服务器证书构建验证路径，检查签名、有效期和目标名称；信任锚来自系统证书库与 webpki-roots。交叉签名回归覆盖完整 GTS 链、错误域名、过期和损坏签名。没有截短链、固定信任叶证书或跳过验证的分支。

`net.rs` 负责 URL、凭据、重定向和客户端缓存；`transport.rs` 负责连接及有界响应。直连使用已经检查的 DNS 地址，保留原 Host 和 TLS 目标名；客户端按来源与安全模式隔离，缓存 30 秒。自动重定向、自动 Referer 与传输层重试关闭。业务层只对允许重试的幂等操作重试，写操作不重放。

HTTP/SOCKS5 代理按显式配置、环境和 Windows 固定系统设置选取，失败不偷偷直连。代理是受信任的网络中间人：HTTP CONNECT 和 socks5h 可能在代理端解析域名，客户端不能证明代理内部使用了本机检查过的地址。远程部署应在出口代理隔离私网与元数据地址。PAC 和移动端 Wi-Fi 代理自动发现尚未实现。

适配层采用可取消的异步 I/O。API/图片最多四个请求持有许可，完整响应最多 8 MiB，总等待最多 20 秒。媒体另有两个许可，按消费者需求读入，每次向网关交付不超过 32 KiB，不缓冲整个视频。连接超时 8 秒，读取停滞超时 20 秒。每个来源最多两个空闲连接，15 秒回收。

媒体 Range 直接转发，沿一个上游响应流式交付，不再通过多个条件 Range 人工拼接，也不要求强 ETag。中途错误终止当前响应，交由播放器决定后续操作。HLS 清单改写最多缓冲 2 MiB，分片、密钥和初始化段经同一受控流式入口传输。

## DNS 与数据

RecurseX 0.2.6 保留系统解析与有界 DoH 回退；其 Courierust 1.1.2 仅用于 DNS 加密上游，不再承担内容线路 TLS。系统信任库不可读取或为空时，DNS 使用随包 Mozilla CA。该包是公开证书数据，不是第三方源码。

只启用 `std`、`doh`、`persist`，不编译应用未使用的 DoT、DoH3、DoQ 与 DNSSEC 验证。加密解析明确禁止明文递归；同一地址族按配置顺序尝试上游，不进行上游竞速，最多接触配置中的 1–4 个 IP。A/AAAA 仍并行查询。TLS 身份验证不等于 DNSSEC 验证，诊断明确返回 `dnssec_validation: false`。

NextJson 处理业务 JSON 与 DNS 配置；RustBinary 供 RecurseX 持久化缓存使用。tzcraft 处理 UTC 格式化，单调超时使用 Instant / Duration。Axum 提供回环网关和 Web 服务，tower-http 静态文件功能仅在 server feature 下编译。

## 界面与媒体

Material 3 Expressive 组件由 material_3_expressive 与 material_ui 提供。Google Sans 用于界面，Google Sans Code 用于等宽诊断文字，Noto Sans SC 回退中文；字体离线打包并保留 OFL。来源为 [Google Fonts](https://github.com/google/fonts/tree/main/ofl/googlesans) 和 [Google Sans Code](https://github.com/google/fonts/tree/main/ofl/googlesanscode)。Google Sans 是比例字体，不通过修改字形冒充等宽字体。

许可证使用 flutter_markdown_plus 渲染，标题有语义标记，内部链接定位章节，外链只接受 HTTPS。正文直接读取 LICENSE，不改写授权条款。

media_kit 管理解码，页面共用 PlaybackSession 和 FullscreenSession。播放器按需创建，未播放时不初始化解码器。横竖屏保持播放器槽位稳定；浏览器全屏仍受用户手势限制。
