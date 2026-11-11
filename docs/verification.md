# 验证

## 2026-11-11—12：推荐、CI 依赖下载与 DNS 回退

推荐修复覆盖四类实际问题：归一化抵消兴趣的时间衰减、短播放覆盖同一视频已有的有效观看、去重空页被误判为列表结束，以及可选搜索召回拖住首页。超过 90 天的兴趣不参与排序；召回最多等待 2 秒，底层请求仍由网络层超时约束。新增回归包含重复分页后继续加载、近期观看与旧搜索的排序，以及召回超时后迟到的错误。

Ubuntu CI 截图中的停顿发生在 APT 下载阶段。工作流将 Azure Ubuntu 镜像替换为官方 Ubuntu 源，保留发行套件与签名检查；增加网络超时、有限重试和步骤时限。已通过 YAML 解析、Bash 语法与内嵌 Python 编译检查；没有把这些本地检查当作 GitHub Linux 构建通过。

DNS `auto` 不再直接采用含内网、回环或保留地址的系统答案。合法 FakeIP 保留给 VPN；普通域名优先使用验证证书的 DoH，仅在 DoH 失败时回退到已通过地址策略的系统答案。IPv4 映射形式的 FakeIP 同样识别。最终目标、重定向和 TLS 校验继续执行。

PLK110 关闭 VPN 后，旧包的地址策略错误已复现；修复版取得 2 个非 FakeIP 地址，诊断累计 `encrypted_answers=4`、`system_answers=0`、`failures=0`，但内容接口在 20 秒后超时。该结果说明加密解析链路已经执行，不能证明解析答案对应的站点在当前网络可达；无 VPN 播放仍未通过。原始记录位于 `build/dns-recovery-native.log` 与 `build/dns-recovery-diagnostic.log`。后一次诊断导出曾写入 Android 的只读工作目录，掩盖测试异常；已改由 integration driver 在电脑端保存 `build/integration_response_data.json`，失败时也保留报告。

本轮完整 Flutter 回归 75 项通过，Rust 回归 65 项通过、8 项联网测试默认忽略，Clippy 全 targets / server / 警告视为错误通过，Flutter analyze 无问题；最终诊断脚本另行静态检查通过。日志为 `build/dns-final-{flutter-tests,tests,clippy,analyze,integration-analyze}.log`。本轮没有改动导航渲染实现，也没有新增可证明帧时间下降的性能数据。

用户恢复 VPN 后，第一次测试仍出现 DNS 超时和媒体加载失败；保留记录后复测通过，未放宽断言或延长播放超时。成功轮的内容接口用时 772 ms，加密解析成功 2 次、失败 0 次；真实视频首帧、播放进度、横竖屏旋转、进度跳转、第一集切到第二集与单播放器复用均通过，随后验证应用主页、设置和许可证页面。日志为 `build/dns-final-vpn-retry.log`，成功和失败的结构化报告分别为 `build/dns-final-vpn-passed-report.json` 与 `build/dns-final-vpn-first-report.json`。这些结果不能替代尚未通过的无 VPN 验收。

最终 Windows 与 Android ARM64 Release 构建通过。Windows ZIP 包含 41 个发布文件，CRC 校验通过；APK 的 CRC 与 v2/v3 签名验证通过。已通过 ADB 保留数据安装到 PLK110，替换测试包，冷启动返回 `Status: ok`。APK 使用现有本机开发密钥，仅供本次设备安装，不作为商店发行签名。

| 最终产物 | SHA-256 |
| --- | --- |
| `build/releases/Hedone-1.0.1-dns-recommendations-windows-x64.zip` | `30E6D0834BB775CFBB73D20C3598C93EEB91992EE59A245EB16C28762277B69A` |
| `build/releases/Hedone-1.0.1-dns-recommendations-arm64-local-test.apk` | `8B6B9C6FA96DBEE4CC0166A7907E275670D44225E3C3ABBAC21C390EEF01236D` |

本节文件同时包含推荐与 DNS 修复。此前 `recommendations-fix` 和 `recursex026` 包不包含最终 DNS 逻辑；下文历史验收及哈希不能混用。

## 2026-11-11：RecurseX 0.2.6、连续动量与合成层修复

本轮基于现有工作区增量修改，未回退此前未提交的功能。RecurseX 使用 crates.io 的 0.2.6，显式启用 std/doh/persist；设置页和诊断版本同步更新。加密解析禁止明文递归、关闭上游竞速，系统根证书库为空时使用随包 CA，保留 IP 身份验证、工作许可、超时和缓存预算。

导航改选接续当前位移、缩放与弹簧速度，同时保留透明度和可见页面的叠放顺序。使用不透明主题背景与加权合成后，普通双页交叉过渡只需一个透明层。所有页面继续共用导航 VSync，不增加轮询定时器，逐帧不重新 build/layout。

已执行并通过：

- Rust：64 项回归通过，8 项外网测试默认忽略；另行运行真实 DoH 测试通过。Clippy 全 targets / server / 警告视为错误通过；rustfmt 通过。
- Flutter：最终 70 项回归通过；完整 analyze 无问题，最后一轮动效修改另行定向 analyze 无问题。覆盖反向切换实际绘制矩阵、速度、叠放连续性、合成权重与 60/90/120/165 Hz 下不逐帧构建布局。
- PLK110：Profile 原生集成使用独立临时目录、匿名请求真实内容；首帧、进度、横竖屏旋转、切集和单播放器复用通过。测试没有读取既有账号凭据。
- 手机渲染：两次 Profile 导航采样通过，原始数据与限制见[帧时间记录](benchmarks/README.md)。最新 405 帧中仍有 20 帧超过约 16.67 ms，不能宣称所有动画零掉帧；系统报告刷新率在两轮间改变，也不能据此推导 GPU 负载下降比例。
- Windows：最终 Release 构建通过，41 个发布文件 ZIP CRC 校验通过，内置 DLL 包含 0.2.6。合成层优化前的同轮 Release 已从项目根目录启动并加载真实首页；最终构建另行完成，没有把进程存在等同于所有功能验收。
- Android：最终 ARM64 Release 构建通过，APK CRC、内置库版本、v2/v3 签名验证通过。ADB 保留数据安装到 PLK110 成功，最终包冷启动 Status 为 ok，包标志不含 DEBUGGABLE。

交付文件：

| 文件 | SHA-256 |
| --- | --- |
| `build/releases/Hedone-1.0.1-recursex026-windows-x64.zip` | `EA6CADAF4EF36EFE8C7E47AD27F52418F40A26E37CE261DD338628726F52E6C6` |
| `build/releases/Hedone-1.0.1-recursex026-arm64-local-test.apk` | `70E9628E37951CA988815449C6F1594FA6207917C56143B1FE16D46DEFF5CCD6` |

APK 为 Release AOT、本机已有开发密钥签署，供本次设备安装；仓库没有配置正式发行签名，不能当作商店发布包。Windows 需完整解压目录再运行 hedone.exe。首次 Android 构建因官方播放器依赖下载超时失败，补齐原始下载并核对依赖声明的全部校验值后成功，未绕过校验或修改第三方源码。

这些结果覆盖本轮修复和明确列出的场景，不是全代码安全审计，也不构成无漏洞或所有设备满帧的证明。下文是此前阶段记录，不能混用包名、哈希或性能数据。

## 2026-11-11：平板 ADB 验收

已连接 WGRR-W19 平板完成真实测试。原安装包哈希确认是旧 Debug 构建；同签名保留数据升级至最新 Release 后，横屏折叠按钮消失、侧栏固定展开，窗口请求与显示设备实际模式均达到 120 Hz。四轮真实内容滑动从旧包约 49–57 FPS 变为新版约 113–120 FPS，仍有少量长帧。数据、采样方法及边界见[平板 ADB 记录](benchmarks/tablet-adb.md)。

本轮没有继续修改已验证的导航和原生刷新率逻辑，新增可复现的 ADB 呈现帧采样脚本。省电模式因 USB 充电而未能启用，不计为通过。下文尚无 Android 实机数据的陈述属于此前检查阶段。

## 2026-11-11：固定侧栏、胶囊导航与系统刷新率

Flutter analyze 无问题，68 项 Flutter 回归通过。新增覆盖手机横竖屏、平板横竖屏、三种桌面平台、无折叠入口、键盘不改变导航形态，以及旋转保留同一个搜索输入框与草稿。动画测试按 60/90/120/165 Hz 步长执行，确认没有逐帧 build/layout。修复手机横屏下加载与空状态的高度溢出。

Windows Profile 运行通过，423 帧中 1 帧超出系统报告的 60 Hz 帧预算；完整结果见 [复测记录](benchmarks/navigation-responsive.json)。这不是 165 Hz 实机验收。Android 刷新率策略通过 ARM64 Release 编译；省电、温控与厂商高刷策略仍须实机验证。未修改 Rust 业务逻辑，没有重复运行上一轮 Rust 检查。

已检查 320（两倍文字）、390 和 1440 宽度的真实 Widget 截图，位于 `build/qa/shell-*.png`。截图中的条目明确使用布局测试数据，没有作为真实内容或播放验收。工作区递归扫描未发现 Vendor 目录。

最终 Windows Release 与 Android ARM64 Release 构建通过。首次 Windows 安装步骤遇到正在运行的旧版占用输出文件，改用独立安装目录后成功；已恢复本地 CMake 默认安装路径。交付包中的 `data/app.so` 与本轮 Release 编译产物 SHA-256 一致。

- `build/releases/Hedone-1.0.1-navigation-windows-x64.zip`：完整发布目录，41 个文件，ZIP CRC 校验通过。SHA-256：`AD578B8A7FF654F22D422DEC0D9F8C95A3181E619525AB0687F873C8777310A6`。
- `build/releases/Hedone-1.0.1-navigation-arm64-local-test.apk`：Release 构建、本机现有开发密钥签署，v2/v3 验签通过。用于安装测试，不是正式发行签名。SHA-256：`BC46B73BC7B668FDF84A699108BB1C3B1CC42EDD9D0EE17840E231BE5A613980`。

下方 `fluid` 包是上一轮产物，不包含本轮导航与刷新率修改。

## 2026-11-11：流式媒体与绘制阶段动效

本轮完成的检查：Flutter analyze 无问题；Flutter 回归 56 项通过；Rust 回归 62 项通过、8 项外网测试默认忽略；Clippy 全 targets / server / 警告视为错误通过。移除了旧的条件 Range 拼接实现及对应测试，改为单响应流式传输与新的网络回归，没有把旧测试数量沿用为新结果。

Windows Profile 原生集成通过，验证实际打包 DLL、URL 边界、主页、设置和许可证导航。Windows Release 构建通过。320 / 390 / 800 / 1440 / 1920 / 3840 宽度布局回归通过；这不是 4K 视频硬件解码或 HDR 验收。

新增回归覆盖：场景动画不触发子树重新 build/layout；最多两个导航页面保活；历史通知不重建 MaterialApp；淘汰后保留搜索草稿；保持比例的 cover 解码与像素预算；连续点击只开一页；共享封面入场中返回，以及加载完成时 Hero 节点身份保持稳定。

Rust 本地 TCP 测试传输 24 MiB + 7 字节，验证头部先于正文交付、每块不超过 32 KiB、无需强 ETag、取消释放许可和截断报错。网关测试覆盖跨块 HLS 签名、子地址重写、2 MiB 清单上限、Range 头与字节保留，以及响应丢弃后的许可释放。

真实网络复测：镜像发布页返回 19 个候选；固定线路 1 的内容 API 通过（约 1008 ms）；固定线路 2 返回 HTTP 404（约 759 ms）。`probe_live` 的测试进程成功仅表示完成探测，不代表两个上游都可用。仍保留证书、DNS 和每跳重定向校验。

性能使用本机 Windows Profile 实测，完整数据和局限见 [导航对照](benchmarks/README.md)：raster p90 5.294 → 3.468 ms，采样 RSS 峰值 241.40 → 234.79 MiB；build/raster p99 均有小幅上升。一次 UI 隔离场景不能证明所有帧更快或全局内存大幅下降。没有测量 Android 真机视频帧时间、GPU 利用率、功耗或不同编码的高清解码能力。

Android ARM64 Release 构建通过，Release Lint 通过。修复本地明文域名缺少 `includeSubdomains="false"` 的配置错误；构建时让 Flutter 重新生成 Release 插件注册文件，避免测试插件残留。CI 增加 Release 构建。工作区 Vendor 目录复查为 0。

本轮交付：

- `build/releases/Hedone-1.0.1-fluid-windows-x64.zip`：完整 Windows Release 目录，解压后运行 `hedone.exe`。SHA-256：`3AA76DDBBDBF9264E29F1A6BF14FD0E72DD8B377D00CE6F45E897DF78A0BA01D`。
- `build/releases/Hedone-1.0.1-fluid-arm64-local-test.apk`：Release AOT 构建，使用本机现有 Android 开发密钥签署，v2/v3 验签通过；用于安装测试，不是正式发行签名。SHA-256：`177591FD187874C6C045561235B5FE3263C4A23F8083DFE1AA4F5D3568A8FCB4`。

下文属于上一轮构建，不能混用其哈希。此轮没有 Android 真机安装与播放验收。

## 上一轮：Hedone 修复与重命名

环境：Windows，Flutter 3.47.9 / Dart 3.13.7，Rust 1.99.1。以下是本轮真实执行的结果，后面的 Courierust 记录属于迁移前历史。

| 检查 | 结果 |
| --- | --- |
| Flutter analyze | 无问题 |
| Flutter 回归 | 50 项通过 |
| Rust 回归 | 63 项通过，8 项联网测试默认忽略 |
| Clippy | server、全部 targets，警告视为错误，通过 |
| Windows 原生集成 | Profile 模式通过：打包 DLL、URL 边界、真实主页、设置导航、许可证入口 |
| Windows Release | 构建通过，最终交付文件见 build/releases |
| Web Release | 构建通过，Wasm dry run 通过；未进行浏览器功能验收 |
| Android ARM64 | debug APK 构建通过；本轮没有安装到真机 |
| 镜像发布页 | 两次真实请求通过，包含解析加强后的复测 |
| 固定线路 1 | 按当前系统代理配置访问内容接口成功，约 608 ms；显式直连仍超时 |
| 固定线路 2 | 内容接口返回 HTTP 404，未把可验证证书等同于内容可用 |
| 交叉签名回归 | 完整 GTS 链通过，错误域名、过期、缺失中间证书、损坏签名被拒绝 |
| Vendor | 工作区递归扫描为 0 个目录，没有本地依赖补丁 |

Flutter 覆盖冷启动随机推荐、观看/搜索权重、时间衰减、去重、过时刷新隔离、偏好持久化及文本预算；同时检查 320/390/800/1440 宽度、深浅主题、减少动效、快速导航和已有播放布局。许可证截图位于 build/qa，已检查正确字体、标题、换行和链接；内部章节链接也有滚动定位回归。

桌面截图工具的 Windows.Graphics.Capture 持续超时，因此不将该截图步骤计为通过。可访问性树读取到了真实主页和内容，原生 integration_test 使用真实窗口完成主页、设置和许可证导航。曾进行渲染后端对照，但未获得足以证明 Impeller 故障的证据，最终代码保留 Flutter 默认后端。

本轮没有 iOS、macOS、Linux 真机构建，也没有低端机 UI/raster 帧时间、功耗或 GPU 负载百分比数据；无法从测试通过推导出所有设备均无掉帧或绝无漏洞。固定线路 2 的 HTTP 404 和直连超时是当前实测边界，不用演示数据覆盖。

复现桌面集成测试：

```sh
flutter drive --driver=test_driver/integration_test.dart --target=integration_test/native_bridge_test.dart --profile -d windows
```

此方式避免覆盖开发者正在运行的 Debug 目录。Windows 上 integration_test 会提示未检测到原生结果插件，driver 已通过 VM service 收集到全部测试结果，成功进程退出码为 0。

## 本轮构建产物

Windows 完整运行包：`build/releases/Hedone-1.0.1-windows-x64.zip`。解压后运行 `hedone.exe`，保留同目录 DLL 和 data。

SHA-256：`E1D2E3FB0A6C748829CE3429EA65B65906375BBB70444504838069D9F7038D33`。

Android ARM64 调试包：`build/releases/Hedone-1.0.1-android-arm64-debug.apk`，使用调试签名，不作为正式签名发布包。

SHA-256：`3E5537431806321B87456AC6B5112A9AC0462D8D5D12D6B1DF2B28A5914EF967`。

Web 输出：`build/web`。构建报告 CupertinoIcons 字体引用但未包含字体的提示；应用代码未使用 CupertinoIcons，本轮未据此宣称 Web 运行时已完成验收。

## 历史记录：迁移前的 Courierust 回归（2026-11-11）

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
flutter test integration_test/native_bridge_test.dart -d <Android设备ID> --dart-define=HEDONE_LIVE_BASE=https://huangguoai.com --dart-define=HEDONE_DEVICE_ROTATION=true
```

不提供 `HEDONE_LIVE_BASE` 时仅检查原生库加载、本地线路选择和网络边界。提供后使用独立临时数据目录，从真实列表选择内容，静音播放并检查首帧、进度、旋转及单播放器复用。测试结束应恢复普通应用 APK；测试包不能作为日常应用分发。

媒体单独联调需要 `HEDONE_TEST_VIDEO_ID`，运行 `media::tests::live_play_chain` 或 `transport::tests::live_manifest_can_reopen_same_origin` 的 ignored 测试。日志不打印带签名的媒体地址。上游不可用时测试失败，不用演示内容替换为假成功。

传输限制、证书路径与代理行为见 [依赖边界](dependencies.md)。单请求完整缓冲和新连接握手仍会影响首帧等待；不能把布局回归通过描述为全平台流畅播放或渲染性能已经达标。
