# Rust 回归测试

离线测试位于各模块的 `#[cfg(test)]` 区块，直接使用 `cargo test --features server`。
网络测试通过 `#[ignore]` 隔离，避免上游故障掩盖本地回归。实时媒体测试用 `HEDONE_TEST_VIDEO_ID` 指定有权访问的内容编号；测试不输出播放地址、令牌或正文。
