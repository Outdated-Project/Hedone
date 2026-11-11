# Hedone

Flutter + Rust 黄果客户端。Android、iOS、Windows、macOS、Linux 共用 Flutter 界面与 Rust 核心；浏览器使用同源部署的 Rust 服务。

**NONCOMMERCIAL — 仅限非商业用途。** 当前代码采用 [PolyForm Noncommercial 1.0.0](LICENSE)。禁止销售、广告变现、卡密、VIP、付费解锁，以及作为收费产品或服务的一部分使用；授权范围以许可证全文为准。维护者不提供商业授权，不接受广告、推广或商务合作。

## 实现

- 原生端通过 `flutter_rust_bridge 2.13.0` 调用 Rust，Native Assets 负责构建与打包，不需要手工复制动态库。
- 界面采用 Material 3 Expressive、Google Sans、Google Sans Code 与 Noto Sans SC。窄屏底部导航，宽屏导航栏；卡片容器转场、统一页面动效、系统减少动态效果和后台动画停用贯穿应用。
- 列表、分类、榜单、搜索、详情、剧集、帖子、评论和账号操作接入真实 edge 协议。播放器支持 HLS、拖动、倍速、续播和切集；没有演示数据或伪造接口成功状态。
- 发现页提供沉浸观看入口，同一部剧内上下滑动切集。页面停稳才切换媒体，复用一个播放器；选集按需构建，临近片尾只预取下一集地址。
- 会话、网络策略、封面解密、HLS 重写和有界媒体缓存集中在 Rust。原生凭据写入系统安全存储；Web 凭据只保留在服务进程中。
- DNS 使用 RecurseX 0.2.6：自动模式保留 VPN FakeIP，普通域名优先使用经过 Courierust 1.1.2 验证的 DoH；不可用时才回退到安全的系统答案。NextJson 0.1.5 读取配置，RustBinary 0.1.10 支撑有界缓存快照。解析版本记录在 Cargo.lock 中。

`material_3_expressive` 是第三方组件实现，不冒称 Flutter 官方组件。Aurora 是应用的统一动效架构，使用 Flutter 自身的调度与渲染能力；仓库没有自研或修改 Flutter 渲染引擎。

业务 JSON 使用 NextJson，UTC 格式化使用 tzcraft。内容传输使用正式发布的 Reqwest / Rustls，保留地址校验、来源隔离和有界连接复用；代理按配置使用。DNS 使用 RecurseX。镜像从发布页自动发现，缓存最多保留七天；凭据只发往固定可信来源。依赖职责和实际限制见[依赖边界](docs/dependencies.md)。

“猜你喜欢”从随机探索开始，根据近期观看和搜索逐渐调整，保留探索位置与多样性。画像在本机按线路隔离，设置中可重置；候选召回会向当前线路发送单个近期关键词。权重与预算见[推荐设计](docs/recommendations.md)。

## 开发

环境：Flutter **3.47.9** / Dart **3.13.7**、Rust **1.99.1**，以及目标平台 SDK。锁文件必须保留。

```sh
flutter pub get --enforce-lockfile
flutter run -d windows
```

其他原生平台使用对应 Flutter device ID。Web 必须由 Rust 服务同源提供。完整命令、签名和环境变量见[构建与部署](docs/deployment.md)。

原有固定线路可能因上游调整而不可用。原生端在错误页选择“更换数据线路”，刷新发布页镜像并检测；镜像只用于游客浏览，不接收账号密码或令牌。Web 管理员在数据目录配置线路。不会把临时镜像硬编码成永久登录站点。

## 目录

| 路径 | 职责 |
| --- | --- |
| `lib/core/` | 应用状态、分页、播放生命周期、存储接口 |
| `lib/data/` | 业务模型、仓库与原生/Web 传输 |
| `lib/features/`、`lib/ui/` | 页面、Material 3 Expressive 与统一动效 |
| `lib/src/rust/` | FRB 生成绑定 |
| `rust/src/` | 业务服务、会话、网络与媒体网关 |
| `hook/` | 原生资产构建 |
| 各平台目录 | Flutter 必需的平台宿主 |
| `test/`、`integration_test/` | 状态、布局与真实桥接回归 |

旧的 Tauri、React、Node 包管理与前端构建链已移除。平台宿主中的 Kotlin、Swift、C++ 和 Web 引导文件属于 Flutter 工程要求，不承载另一套业务实现。

## 验证与维护

执行 `tool/check.ps1` 或 `bash tool/check.sh`。跨平台 CI 配置覆盖五个原生目标与 Web，但配置存在不代表这些目标已经在当前机器上通过。实际验证记录、联网回归方法和限制见[验证说明](docs/verification.md)。架构取舍见[架构](docs/architecture.md)，内存预算与实机验收方法见[性能设计](docs/performance.md)，信任边界见[安全设计](docs/security.md)。

社区问题和技术 PR 均可提交；维护者按时间与精力处理，不承诺第三方接口持续可用。项目不运营内容托管服务，与上游站点没有官方隶属或背书关系；软件许可证不授予第三方内容权利。正式权益通知可通过仓库 Issues 或平台渠道提出，维护者核实后在可控制的仓库范围内配合处理。

历史版本 v1.0.1 及更早版本曾以 MIT 许可证发布，已取得的相应授权不因后续换证而撤回；自 v1.1.0 起的新版本适用 PolyForm Noncommercial 1.0.0。字体和依赖保留各自许可证，不以本项目许可覆盖第三方权利。
