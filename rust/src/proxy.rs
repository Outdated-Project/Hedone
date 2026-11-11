//! Explicit proxy policy; never silently bypass a configured proxy.
pub(crate) fn for_url(target: &url::Url) -> Result<Option<String>, String> {
    let explicit = std::env::var("HEDONE_PROXY")
        .ok()
        .filter(|v| !v.trim().is_empty());
    if let Some(value) = explicit {
        return validate(value).map(Some);
    }
    let bypass = std::env::var("NO_PROXY")
        .or_else(|_| std::env::var("no_proxy"))
        .unwrap_or_default();
    if bypass
        .split(',')
        .any(|item| matches_host(item.trim(), target))
    {
        return Ok(None);
    }
    let names = if target.scheme() == "https" {
        ["HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"]
    } else {
        ["HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"]
    };
    for name in names {
        if let Ok(value) = std::env::var(name)
            && !value.trim().is_empty()
        {
            return validate(value).map(Some);
        }
    }
    system(target)
}
fn matches_host(rule: &str, target: &url::Url) -> bool {
    if rule == "*" {
        return true;
    }
    if rule.is_empty() {
        return false;
    }
    let rule = rule.to_ascii_lowercase();
    let host = target.host_str().unwrap_or("").to_ascii_lowercase();
    let exact = format!("{host}:{}", target.port_or_known_default().unwrap_or(0));
    let suffix = rule.trim_start_matches('.');
    host == suffix || exact == rule || host.ends_with(&format!(".{suffix}"))
}
fn validate(raw: String) -> Result<String, String> {
    let parsed = url::Url::parse(raw.trim()).map_err(|_| "代理 URL 无效")?;
    if !matches!(parsed.scheme(), "http" | "socks5" | "socks5h")
        || parsed.host_str().is_none()
        || parsed.query().is_some()
        || parsed.fragment().is_some()
    {
        return Err("代理必须使用 HTTP 或 SOCKS5；不支持 HTTPS 代理隧道嵌套".into());
    }
    Ok(raw.trim().to_owned())
}
#[cfg(not(windows))]
fn system(_: &url::Url) -> Result<Option<String>, String> {
    Ok(None)
}

#[cfg(windows)]
fn system(target: &url::Url) -> Result<Option<String>, String> {
    use std::os::windows::process::CommandExt;
    // reg.exe is invoked directly, with fixed arguments and no shell expansion.
    fn query(name: &str) -> Option<String> {
        let system_root = std::env::var_os("SystemRoot")?;
        let executable = std::path::PathBuf::from(system_root)
            .join("System32")
            .join("reg.exe");
        let output = std::process::Command::new(executable)
            .args([
                "query",
                r"HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings",
                "/v",
                name,
            ])
            .creation_flags(0x08000000)
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        let text = String::from_utf8_lossy(&output.stdout);
        for line in text.lines() {
            let parts: Vec<_> = line.split_whitespace().collect();
            if parts.first() == Some(&name) && parts.len() >= 3 {
                return Some(parts[2..].join(" "));
            }
        }
        None
    }
    if query("ProxyEnable").as_deref() != Some("0x1") {
        return Ok(None);
    }
    if let Some(bypass) = query("ProxyOverride")
        && bypass.split(';').any(|v| {
            matches_host(v.trim_start_matches("*."), target)
                || (v == "<local>" && !target.host_str().unwrap_or("").contains('.'))
        })
    {
        return Ok(None);
    }
    let raw = query("ProxyServer").ok_or("系统代理已启用但地址不可读取")?;
    let value = if raw.contains('=') {
        raw.split(';').find_map(|p| {
            p.split_once('=')
                .filter(|(s, _)| *s == target.scheme())
                .map(|(_, v)| v.to_owned())
        })
    } else {
        Some(raw)
    };
    value
        .map(|v| {
            validate(if v.contains("://") {
                v
            } else {
                format!("http://{v}")
            })
        })
        .transpose()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn bypass_obeys_host_boundaries_and_proxy_rejects_unsupported_schemes() {
        let target = url::Url::parse("https://a.example.com").unwrap();
        assert!(matches_host(".example.com", &target));
        assert!(!matches_host("ample.com", &target));
        assert!(validate("https://localhost:8080".into()).is_err());
        assert!(validate("socks5://localhost:1080".into()).is_ok());
    }
}
