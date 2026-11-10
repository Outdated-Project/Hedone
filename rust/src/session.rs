//! Rust 仅持有内存会话；持久化交给 Flutter 的系统安全存储。

use serde::{Deserialize, Serialize};
use std::sync::Mutex;

#[derive(Clone, Serialize, Deserialize, Default)]
pub struct Session {
    // 旧版本没有 origin：不能推断其 token 属于哪个镜像，升级后必须重新登录。
    #[serde(default)]
    pub origin: String,
    #[serde(default)]
    pub token: String,
    #[serde(default)]
    pub user: serde_json::Value,
}

pub struct SessionStore {
    pub current: Mutex<Session>,
}

impl SessionStore {
    pub fn new() -> Self {
        Self {
            current: Mutex::new(Session::default()),
        }
    }

    pub fn restore(&self, text: &str) -> Result<(), String> {
        if text.len() > 256 * 1024 {
            return Err("会话数据过大".into());
        }
        let session: Session =
            serde_json::from_str(text).map_err(|_| "会话数据损坏，请重新登录")?;
        if !crate::net::trusted_auth_origin(&session.origin) || session.token.len() > 16384 {
            return Err("会话来源无效，请重新登录".into());
        }
        *self.current.lock().map_err(|_| "会话锁失败")? = session;
        Ok(())
    }

    pub fn snapshot(&self) -> Result<String, String> {
        let current = self.current.lock().map_err(|_| "会话锁失败")?;
        serde_json::to_string(&*current).map_err(|_| "会话编码失败".into())
    }

    pub fn token(&self, origin: &str) -> Option<String> {
        let cur = self.current.lock().unwrap();
        (cur.origin == origin && !cur.token.is_empty()).then(|| cur.token.clone())
    }

    pub fn user(&self, origin: &str) -> serde_json::Value {
        let cur = self.current.lock().unwrap();
        if cur.origin == origin && !cur.token.is_empty() {
            cur.user.clone()
        } else {
            serde_json::Value::Null
        }
    }

    pub fn set(&self, origin: &str, token: String, user: serde_json::Value) {
        {
            let mut cur = self.current.lock().unwrap();
            cur.origin = origin.to_string();
            cur.token = token;
            cur.user = user;
        }
    }

    pub fn clear(&self) {
        {
            let mut cur = self.current.lock().unwrap();
            cur.token.clear();
            cur.origin.clear();
            cur.user = serde_json::Value::Null;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn credentials_are_bound_to_origin() {
        let store = SessionStore::new();
        store.set(
            "https://huangguoai.com",
            "secret-token".into(),
            json!({"id": 1}),
        );
        assert_eq!(
            store.token("https://huangguoai.com").as_deref(),
            Some("secret-token")
        );
        assert_eq!(store.token("https://huangguoai.ai"), None);
        assert_eq!(store.token("https://evil.example"), None);
        assert!(store.user("https://evil.example").is_null());
        store.clear();
        assert_eq!(store.token("https://huangguoai.com"), None);
    }

    #[test]
    fn legacy_sessions_are_not_assigned_to_current_line() {
        let store = SessionStore::new();
        *store.current.lock().unwrap() =
            serde_json::from_str(r#"{"token":"legacy","user":{"id":1}}"#).unwrap();
        assert_eq!(store.token("https://huangguoai.com"), None);
        assert!(store.user("https://huangguoai.com").is_null());
    }
}
