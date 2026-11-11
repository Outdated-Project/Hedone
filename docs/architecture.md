# 架构

业务逻辑只有 Dart 和 Rust。Android、Apple、Windows、Linux 目录是 Flutter 必需的宿主工程，不包含第二套界面或业务实现。

## 数据边界

`Transport` 区分原生 FFI 与浏览器 HTTP。`Repository` 管理上游协议与短期媒体地址缓存；页面不接触令牌，也不拼接上游认证请求。Rust 的封闭请求枚举限制操作、分页、分类、文本长度和内容编号，再进入原有黄果 edge 信封接口。

上游返回 JSON 的结构可能增加字段，因此桥接层保留 JSON；Flutter 在仓库边界解析为 `VideoItem`、`VideoDetail`、`Episode` 等视图模型。FRB 绑定由 2.13.0 官方生成器生成，提交到仓库，不能手工改签名。

原生应用通过 Flutter Native Assets 构建和打包 Rust。Web 不加载本机动态库，也不伪装成浏览器能够直接访问原生 FFI：它连接同源 Rust 服务，复用同一业务实现。

## 动效与渲染

Aurora 是应用内动效与资源调度层，不是另造的 Flutter 引擎。全局时间、空间弹簧和效果曲线集中在 `ui/design.dart`；主导航共享单个控制器，由 `ui/aurora_scene.dart` 在绘制阶段提交变换。Material 3 Expressive 负责按钮形状与导航指示器，封面通过 Hero 连接详情。导航最多保留最近两个页面，媒体解码延后至入场结束。

Flutter 的 SchedulerBinding/Ticker 承担帧调度。未显示的页面通过 TickerMode 停止动画，应用进入后台时暂停播放。滚动网格按需构建，图片与视频有独立重绘边界；播放进度只刷新控制区，不每帧重建页面。减少动态效果同时遵循应用设置与系统设置。

字体随应用提供 Google Sans、Google Sans Code 和 Noto Sans SC，使用 M3E 的字号与强调层级；没有启动时字体请求。界面只使用 `material_ui` 和 `material_3_expressive`，媒体插件的内置控制条关闭。

`AppTheme` 生成完整的浅色和深色 Material 主题；Expressive tokens 从当前插值中的主题投影，页面底色、文字、卡片和弹窗使用同一份颜色。避免两个主题控制器分别切换，造成深色组件叠在浅色背景上。主导航保留页面状态；连续切换时从当前各页透明度继续混合，旧页面退出后停止绘制并排除交互、语义与动画。

## DNS

`dns.rs` 隔离解析器和业务网络层。自动模式最多等待系统 DNS 1.5 秒：完整答案安全且包含 FakeIP 时保留 VPN 路由；其余普通域名优先通过 RecurseX 并行查询 A/AAAA。系统返回受限地址时丢弃整个答案，不从混合答案中挑选地址；安全的普通系统答案只作为 DoH 不可用时的回退。一个地址族失败不会丢掉另一个成功的加密答案。系统阻塞任务最多 4 个，加密查询最多 8 个，异步取消不会提前释放仍在执行的工作许可。加密查询的排队与等待总计限制为 7 秒，每个 RecurseX 查询另有 5 秒工作预算。

NextJson 的派生类型读取最多 16 KiB 的 `dns.json`；Courierust 验证 DoH 证书与固定 IP 身份；RecurseX 维护 128/512/0 条热/温/冷缓存及 256 条负缓存，关闭过期答案和后台预取。RecurseX 使用 RustBinary/NextJson 序列化 `dns-cache.rxc`，读取限额 2 MiB，查询触发的快照写入间隔至少 60 秒，不启动空闲轮询线程。DNS 结果仍经过原有的全部地址校验与连接地址固定。

这些措施有明确代码路径，但不等于已经取得所有设备的帧率结论。性能验收必须使用目标设备的 profile/release 构建和 Flutter DevTools 帧时间数据。

## 播放

`PlaybackSession` 按需创建并独占一个播放器，单纯查看详情不创建解码器。切集使用请求代次和串行打开队列，过期结果不能覆盖新集；离开页面时取消监听、等待打开队列并调用播放器释放。原生资源最终释放时机由媒体插件管理。观看记录按线路保存，最多 100 条，周期写入并在退出时保存。

`EpisodePager` 只管理竖向分页与停稳选择，`PlaybackControls` 只展示播放状态，`PlaybackSession` 管理解码器生命周期，`Repository` 合并地址请求。分页器不拥有播放器；所有集共用同一个视频控制器，仅当前选中页挂载视频。相邻页展示封面，不启动第二个解码器。选集使用惰性网格，集号索引支持不连续的上游编号。

媒体缓存采用 HashMap 查找、BTreeMap 维护访问顺序，同时限制字节数、条数与 TTL。缓存命中更新最近使用顺序；淘汰不扫描全部条目。分片及图片使用引用计数 `Bytes`，HTTP Range 切片与缓存共用底层字节。预算与不计入预算的内存见[性能设计](performance.md)。

Rust 媒体服务只监听随机本机端口，原生 URL 带 256 位随机密钥。HLS 子列表、密钥、分片和初始化段全部重写回受控入口；分片支持单区间 Range，非 HLS 媒体按流传输。网络层验证目标、DNS 答案和每一跳重定向，禁止向镜像提交账号凭据。

浏览器的同源媒体入口额外要求有效服务会话。帖子正文转换成 Flutter 文本与图片，不执行 HTML、脚本或 iframe。

推荐模块与页面、存储、网络分离：画像处理有界事件和评分，候选模块调用 Repository，AppModel 负责按线路保存。协议与 UI 不依赖评分公式。详见[推荐设计](recommendations.md)。
