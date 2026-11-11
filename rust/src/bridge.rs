//! Small FFI surface. The upstream JSON envelope is decoded once in Dart's repository.
//! A closed request enum prevents callers from constructing arbitrary authenticated paths.
use crate::{api, gateway, media, net, playback_log};
use nextjson::NsonDeserialize as Deserialize;
use nextjson::{Value, json};
use std::path::PathBuf;
use tokio::sync::{OnceCell, RwLock};

pub(crate) struct Runtime {
    pub(crate) api: api::Api,
    pub(crate) gateway: gateway::Gateway,
    // Account changes wait for in-flight reads; stale responses cannot cross origins.
    pub(crate) identity: RwLock<()>,
}

static RUNTIME: OnceCell<Runtime> = OnceCell::const_new();

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

pub async fn initialize(data_dir: String, saved_session: Option<String>) -> Result<String, String> {
    let runtime = RUNTIME
        .get_or_try_init(|| async {
            let dir = PathBuf::from(data_dir);
            if !dir.is_absolute() {
                return Err("应用数据目录必须是绝对路径".to_string());
            }
            std::fs::create_dir_all(&dir).map_err(|_| "无法创建应用数据目录")?;
            net::bind_base(&dir);
            crate::dns::initialize(&dir).await?;
            crate::network_policy::set_strict_security(true)?;
            playback_log::bind(&dir);
            let api = api::Api::new();
            if let Some(saved) = saved_session {
                // Discard invalid/legacy credentials; Flutter removes the stale secure entry.
                let _ = api.session.restore(&saved);
            }
            Ok(Runtime {
                api,
                gateway: gateway::start().await?,
                identity: RwLock::new(()),
            })
        })
        .await?;
    encode(api::app_boot(&runtime.api).await?)
}

fn runtime() -> Result<&'static Runtime, String> {
    RUNTIME.get().ok_or_else(|| "Rust 服务尚未初始化".into())
}

fn encode(value: Value) -> Result<String, String> {
    nextjson::to_string(&value).map_err(|_| "响应编码失败".into())
}

#[derive(Deserialize)]
#[njson(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
enum Request {
    Boot,
    Feed {
        page: u32,
        size: u32,
    },
    Category {
        cate: String,
        page: u32,
        size: u32,
    },
    Rank {
        kind: String,
    },
    Search {
        q: String,
        page: u32,
        size: u32,
    },
    Posts {
        page: u32,
        size: u32,
    },
    Post {
        id: i64,
    },
    Video {
        id: i64,
    },
    Play {
        id: i64,
        ep: u32,
    },
    Comments {
        id: i64,
        ep: u32,
        page: u32,
        size: u32,
    },
    PostComments {
        id: i64,
        page: u32,
        size: u32,
    },
    CommentSend {
        id: i64,
        ep: u32,
        text: String,
        reply_id: Option<i64>,
    },
    Like {
        id: i64,
        ep: u32,
        on: bool,
    },
    Collect {
        id: i64,
        on: bool,
    },
    Follow {
        uid: i64,
        on: bool,
    },
    PostLike {
        id: i64,
        on: bool,
    },
    PostCollect {
        id: i64,
        on: bool,
    },
    Login {
        username: String,
        password: String,
    },
    Register {
        username: String,
        password: String,
        email: String,
    },
    Logout,
    Me,
    LineState,
    LineSet {
        url: String,
    },
    LineMirrors,
    LineProbe {
        urls: Vec<String>,
    },
    NetDiag,
    CheckUpdate,
    CacheClear,
    LogStatus,
    LogSet {
        enabled: bool,
    },
    LogRead,
    LogWrite {
        entries: Vec<playback_log::Entry>,
    },
}

impl Request {
    fn uses_identity(&self) -> bool {
        // These operations never read credentials. Diagnostics capture their
        // origin before awaiting; probes already carry explicit target URLs.
        !matches!(
            self,
            Self::LineMirrors | Self::LineProbe { .. } | Self::NetDiag | Self::CheckUpdate
        )
    }

    fn changes_identity(&self) -> bool {
        matches!(
            self,
            Self::Login { .. }
                | Self::Register { .. }
                | Self::Logout
                | Self::LineSet { .. }
                | Self::Me
        )
    }
    fn validate(&self) -> Result<(), String> {
        match self {
            Self::Feed { page, size }
            | Self::Category { page, size, .. }
            | Self::Search { page, size, .. }
            | Self::Posts { page, size }
            | Self::Comments { page, size, .. }
            | Self::PostComments { page, size, .. }
                if *page == 0 || *page > 100_000 || *size == 0 || *size > 60 =>
            {
                return Err("分页参数无效".into());
            }
            _ => {}
        }
        match self {
            Self::Category { cate, .. }
                if !["ai-duanju", "ai-manju", "ai-huanlian", "ai-mogai"]
                    .contains(&cate.as_str()) =>
            {
                Err("未知分类".into())
            }
            Self::Search { q, .. } if q.trim().is_empty() || q.chars().count() > 120 => {
                Err("搜索词应为 1–120 个字符".into())
            }
            Self::Video { id }
            | Self::Post { id }
            | Self::Play { id, .. }
            | Self::Comments { id, .. }
            | Self::PostComments { id, .. }
            | Self::CommentSend { id, .. }
            | Self::Like { id, .. }
            | Self::Collect { id, .. }
            | Self::PostLike { id, .. }
            | Self::PostCollect { id, .. }
                if *id <= 0 =>
            {
                Err("内容编号无效".into())
            }
            Self::Follow { uid, .. } if *uid <= 0 => Err("用户编号无效".into()),
            Self::Play { ep, .. }
            | Self::Like { ep, .. }
            | Self::Comments { ep, .. }
            | Self::CommentSend { ep, .. }
                if *ep == 0 || *ep > 100_000 =>
            {
                Err("集数无效".into())
            }
            Self::CommentSend { text, .. }
                if text.trim().is_empty() || text.chars().count() > 2000 =>
            {
                Err("评论应为 1–2000 个字符".into())
            }
            Self::Login { username, password }
            | Self::Register {
                username, password, ..
            } if username.trim().is_empty()
                || username.len() > 256
                || password.is_empty()
                || password.len() > 1024 =>
            {
                Err("账号或密码长度无效".into())
            }
            Self::LineProbe { urls } if urls.len() > 16 => Err("一次最多检测 16 条线路".into()),
            Self::LogWrite { entries } if entries.len() > 32 => Err("日志批次过大".into()),
            _ => Ok(()),
        }
    }
}

pub async fn request(payload: String) -> Result<String, String> {
    execute(runtime()?, &payload).await
}

pub(crate) async fn execute(rt: &Runtime, payload: &str) -> Result<String, String> {
    if payload.len() > 32768 {
        return Err("请求过大".into());
    }
    let request: Request = nextjson::from_str(payload).map_err(|_| "请求格式无效")?;
    request.validate()?;
    let (read, write);
    if request.changes_identity() {
        write = Some(rt.identity.write().await);
        read = None;
    } else if request.uses_identity() {
        read = Some(rt.identity.read().await);
        write = None;
    } else {
        read = None;
        write = None;
    }
    let a = &rt.api;
    let value = match request {
        Request::Boot => api::app_boot(a).await?,
        Request::Feed { page, size } => api::api_feed(a, page, size).await?,
        Request::Category { cate, page, size } => api::api_category(a, cate, page, size).await?,
        Request::Rank { kind } => api::api_rank(a, kind).await?,
        Request::Search { q, page, size } => api::api_search(a, q, page, size).await?,
        Request::Posts { page, size } => api::api_posts(a, page, size).await?,
        Request::Post { id } => api::api_post(a, id).await?,
        Request::Video { id } => api::api_video(a, id).await?,
        Request::Play { id, ep } => api::api_play(a, id, ep).await?,
        Request::Comments { id, ep, page, size } => {
            api::api_comments(a, id, ep, page, size).await?
        }
        Request::PostComments { id, page, size } => {
            api::api_post_comments(a, id, page, size).await?
        }
        Request::CommentSend {
            id,
            ep,
            text,
            reply_id,
        } => api::api_comment_send(a, id, ep, text, reply_id).await?,
        Request::Like { id, ep, on } => api::api_like(a, id, ep, on).await?,
        Request::Collect { id, on } => api::api_collect(a, id, on).await?,
        Request::Follow { uid, on } => api::api_follow(a, uid, on).await?,
        Request::PostLike { id, on } => api::api_post_like(a, id, on).await?,
        Request::PostCollect { id, on } => api::api_post_collect(a, id, on).await?,
        Request::Login { username, password } => api::api_login(a, username, password).await?,
        Request::Register {
            username,
            password,
            email,
        } => api::api_register(a, username, password, email).await?,
        Request::Logout => api::api_logout(a).await?,
        Request::Me => api::api_me(a).await?,
        Request::LineState => api::line_state().await?,
        Request::LineSet { url } => {
            let base = api::line_set(a, url).await?;
            media::clear_caches();
            json!({"base":base})
        }
        Request::LineMirrors => api::line_mirrors().await?,
        Request::LineProbe { urls } => api::line_probe(urls).await?,
        Request::NetDiag => api::net_diag().await?,
        Request::CheckUpdate => api::check_update().await?,
        Request::CacheClear => {
            api::cache_clear().await?;
            json!({"ok":true})
        }
        Request::LogStatus => nextjson::to_value(&playback_log::playback_log_status()?)
            .map_err(|_| "日志状态编码失败")?,
        Request::LogSet { enabled } => {
            nextjson::to_value(&playback_log::playback_log_set(enabled)?)
                .map_err(|_| "日志状态编码失败")?
        }
        Request::LogRead => json!({"text":playback_log::playback_log_read()?}),
        Request::LogWrite { entries } => {
            playback_log::playback_log_write(entries)?;
            json!({"ok":true})
        }
    };
    drop((read, write));
    encode(value)
}

pub async fn session_snapshot() -> Result<String, String> {
    let rt = runtime()?;
    let _guard = rt.identity.read().await;
    rt.api.session.snapshot()
}

pub async fn clear_session() -> Result<(), String> {
    let rt = runtime()?;
    let _guard = rt.identity.write().await;
    api::api_logout(&rt.api).await?;
    Ok(())
}

pub fn media_url(url: String, image: bool) -> Result<String, String> {
    crate::network_policy::parse_target(&url)?;
    if url.len() > 16384 {
        return Err("媒体地址过长".into());
    }
    let prefix = &runtime()?.gateway.origin;
    let route = if image { "img" } else { "stream" };
    Ok(crate::media::gateway_url(prefix, route, &url))
}

pub fn validate_external_url(url: String) -> Result<String, String> {
    Ok(crate::network_policy::parse_target(&url)?.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn connection_probes_do_not_contend_with_account_changes() {
        let rt = Runtime {
            api: api::Api::new(),
            // This request does not use the gateway or perform network I/O.
            gateway: gateway::Gateway {
                origin: String::new(),
            },
            identity: RwLock::new(()),
        };
        let _account_change = rt.identity.write().await;
        let result = tokio::time::timeout(
            std::time::Duration::from_secs(1),
            execute(&rt, r#"{"op":"line_probe","urls":[]}"#),
        )
        .await
        .expect("a diagnostic probe must not wait on the account lock")
        .unwrap();
        assert_eq!(nextjson::from_str::<Value>(&result).unwrap(), json!([]));
        assert!(Request::Feed { page: 1, size: 1 }.uses_identity());
        assert!(
            Request::LineSet {
                url: "https://huangguoai.com".into()
            }
            .changes_identity()
        );
    }

    #[test]
    fn bridge_rejects_unknown_operations_and_invalid_parameters() {
        assert!(nextjson::from_str::<Request>(r#"{"op":"exec","command":"anything"}"#).is_err());
        for raw in [
            r#"{"op":"feed","page":0,"size":20}"#,
            r#"{"op":"category","cate":"../../account","page":1,"size":20}"#,
            r#"{"op":"play","id":1,"ep":0}"#,
            r#"{"op":"search","q":" ","page":1,"size":20}"#,
        ] {
            assert!(
                nextjson::from_str::<Request>(raw)
                    .unwrap()
                    .validate()
                    .is_err()
            );
        }
    }
}
