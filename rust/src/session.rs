//! Rust 仅持有内存会话；持久化交给 Flutter 的系统安全存储。

use nextjson::{NsonDeserialize as Deserialize, NsonSerialize as Serialize};
use std::sync::Mutex;

#[derive(Clone, Serialize, Deserialize)]
pub struct Session {
    // 旧版本没有 origin：不能推断其 token 属于哪个镜像，升级后必须重新登录。
    #[njson(default)]
    pub origin: String,
    #[njson(default)]
    pub token: String,
    #[njson(default = "null_user")]
    pub user: nextjson::Value,
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
        let session: Session = nextjson::from_str(text).map_err(|_| "会话数据损坏，请重新登录")?;
        if !crate::net::trusted_auth_origin(&session.origin) || session.token.len() > 16384 {
            return Err("会话来源无效，请重新登录".into());
        }
        *self.current.lock().map_err(|_| "会话锁失败")? = session;
        Ok(())
    }

    pub fn snapshot(&self) -> Result<String, String> {
        let current = self.current.lock().map_err(|_| "会话锁失败")?;
        nextjson::to_string(&*current).map_err(|_| "会话编码失败".into())
    }

    pub fn token(&self, origin: &str) -> Option<String> {
        let cur = self.current.lock().unwrap();
        (cur.origin == origin && !cur.token.is_empty()).then(|| cur.token.clone())
    }

    pub fn user(&self, origin: &str) -> nextjson::Value {
        let cur = self.current.lock().unwrap();
        if cur.origin == origin && !cur.token.is_empty() {
            cur.user.clone()
        } else {
            nextjson::Value::Null
        }
    }

    pub fn set(&self, origin: &str, token: String, user: nextjson::Value) {
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
            cur.user = nextjson::Value::Null;
        }
    }
}

fn null_user() -> nextjson::Value {
    nextjson::Value::Null
}
impl Default for Session {
    fn default() -> Self {
        Self {
            origin: String::new(),
            token: String::new(),
            user: null_user(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use nextjson::json;

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
            nextjson::from_str(r#"{"token":"legacy","user":{"id":1}}"#).unwrap();
        assert_eq!(store.token("https://huangguoai.com"), None);
        assert!(store.user("https://huangguoai.com").is_null());
    }
}
