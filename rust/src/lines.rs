//! 线路（数据源）：固定线路 + 地址发布页上的镜像线路。
//!
//! 上游只是域名在变，请求链路与数据模型完全一致，所以「切线路」等价于换 `net::base()`。
//! 镜像地址来自 <https://huangguoai.pages.dev/>：那个页面本身是空壳，真正的清单在
//! `publish.js` 里（`var urls` 域名数组 + `var subdomains` 子域数组，页面自己随机拼）。

use nextjson::{Value, json};
use std::time::Duration;

/// 固定线路：写死在客户端里，不依赖任何外部页面。
pub const FIXED: [(&str, &str); 2] = [
    ("固定线路 1", "https://huangguoai.com"),
    ("固定线路 2", "https://huangguoai.ai"),
];

const PUBLISH_PAGE: &str = "https://huangguoai.pages.dev/";
const MIRROR_MAX: usize = 60;
const PROBE_TIMEOUT: Duration = Duration::from_secs(8);

pub fn fixed() -> Value {
    json!(
        FIXED
            .iter()
            .map(|(name, url)| json!({ "name": name, "url": url }))
            .collect::<Vec<_>>()
    )
}

/// 拉地址发布页 → 解析 publish.js → 拼出镜像地址。只在用户点开「线路」时调用。
pub async fn mirrors() -> Result<Value, String> {
    let html = get_text(PUBLISH_PAGE).await?;
    let js_rel = script_src(&html).unwrap_or_else(|| "publish.js".to_string());
    let js_url = absolute(PUBLISH_PAGE, &js_rel);
    let script = url::Url::parse(&js_url).map_err(|_| "镜像脚本地址无效")?;
    if script.origin()
        != url::Url::parse(PUBLISH_PAGE)
            .expect("static origin")
            .origin()
    {
        return Err("镜像脚本必须来自地址发布页的同一来源".into());
    }
    let js = get_text(&js_url).await?;

    let domains = js_array(&js, "var urls");
    let subs = js_array(&js, "var subdomains");
    if domains.is_empty() {
        return Err("地址发布页格式有变化：没找到镜像域名".to_string());
    }

    let mut items: Vec<Value> = Vec::new();
    let mut seen = std::collections::HashSet::new();
    'outer: for domain in domains {
        let domain = domain.trim_end_matches('/').to_string();
        if domain.is_empty() {
            continue;
        }
        let hosts: Vec<String> = if subs.is_empty() {
            vec![domain.clone()]
        } else {
            subs.iter().map(|s| format!("{s}.{domain}")).collect()
        };
        for host in hosts {
            let raw = format!("https://{host}");
            let Ok(candidate) = crate::network_policy::parse_target(&raw) else {
                continue;
            };
            if candidate.path() != "/"
                || candidate.query().is_some()
                || candidate.fragment().is_some()
                || candidate.port().is_some()
                || !matches!(candidate.host(), Some(url::Host::Domain(_)))
            {
                continue;
            }
            if !seen.insert(host.clone()) {
                continue;
            }
            items.push(json!({ "url": format!("https://{host}"), "host": host }));
            if items.len() >= MIRROR_MAX {
                break 'outer;
            }
        }
    }
    if items.is_empty() {
        return Err("地址发布页里没有可用的镜像地址".to_string());
    }

    Ok(json!({ "source": PUBLISH_PAGE, "script": js_url, "items": items }))
}

/// 可达性探测（并发 6 条一组）。只报结果，不做自动切换。
pub async fn probe(urls: Vec<String>) -> Value {
    let mut out: Vec<Value> = Vec::new();
    for chunk in urls.chunks(6) {
        let mut handles = Vec::new();
        for u in chunk {
            let u = u.clone();
            handles.push(tokio::spawn(async move { probe_one(u).await }));
        }
        for h in handles {
            if let Ok(v) = h.await {
                out.push(v);
            }
        }
    }
    json!(out)
}

async fn probe_one(url: String) -> Value {
    let mut report = crate::net::probe_content(&url, PROBE_TIMEOUT).await;
    report
        .as_object_mut()
        .expect("probe report is an object")
        .insert("url".into(), json!(url));
    report
}

async fn get_text(url: &str) -> Result<String, String> {
    let resp = crate::net::get(url, Duration::from_secs(12), None, None).await?;
    if !resp.status().is_success() {
        return Err(format!("HTTP {}", resp.status()));
    }
    String::from_utf8(crate::net::read_limited(resp, 2 * 1024 * 1024).await?)
        .map_err(|_| "The route publication page is not UTF-8".into())
}

/// 从 HTML 里挑出脚本地址（发布页只有一个 `publish.js?<版本>`）。
fn script_src(html: &str) -> Option<String> {
    for tag in html.split('<').filter(|tag| tag.starts_with("script")) {
        let tag = tag.split('>').next()?;
        let Some((_, attr)) = tag.split_once("src") else {
            continue;
        };
        let Some(value) = attr.trim_start().strip_prefix('=') else {
            continue;
        };
        let value = value.trim_start();
        let quote = value.chars().next()?;
        if quote != '\'' && quote != '"' {
            continue;
        }
        let Some(end) = value[1..].find(quote) else {
            continue;
        };
        let candidate = &value[1..end + 1];
        if candidate
            .split('?')
            .next()
            .is_some_and(|v| v.ends_with("publish.js"))
        {
            return Some(candidate.replace("&amp;", "&"));
        }
    }
    None
}

fn absolute(base: &str, rel: &str) -> String {
    url::Url::parse(base)
        .and_then(|url| url.join(rel))
        .map(|url| url.to_string())
        .unwrap_or_default()
}

/// 取 JS 里 `var <name> = [ ... ]` 的字符串数组（去掉行尾 `//` 注释，但保留字符串里的 `//`）。
fn js_array(src: &str, decl: &str) -> Vec<String> {
    let name = decl.strip_prefix("var ").unwrap_or(decl);
    let Some(rest) = ["var", "let", "const"].iter().find_map(|kind| {
        let declaration = format!("{kind} {name}");
        src.match_indices(&declaration)
            .find_map(|(at, _)| src[at + declaration.len()..].trim_start().strip_prefix('='))
    }) else {
        return Vec::new();
    };
    let Some(open) = rest.find('[') else {
        return Vec::new();
    };
    let Some(close) = rest[open..].find(']') else {
        return Vec::new();
    };
    strip_line_comments(&rest[open + 1..open + close])
        .split(',')
        .filter_map(|raw| {
            let raw = raw.trim();
            let quote = raw.chars().next()?;
            if !matches!(quote, '\'' | '"') || raw.len() < 2 || !raw.ends_with(quote) {
                return None;
            }
            let value = &raw[1..raw.len() - 1];
            // Publication lists are plain host labels, not executable JS.
            if value.chars().any(|c| c == quote || c == '\\') {
                return None;
            }
            Some(value.trim().to_owned())
        })
        .filter(|s| !s.is_empty())
        .collect()
}

/// 去掉 `//` 行尾注释（引号内的 `//` 是 URL，不能动）。
fn strip_line_comments(body: &str) -> String {
    let mut out = String::with_capacity(body.len());
    let mut quote: Option<char> = None;
    let mut chars = body.chars().peekable();
    while let Some(c) = chars.next() {
        match quote {
            Some(q) => {
                out.push(c);
                if c == q {
                    quote = None;
                }
            }
            None => {
                if c == '\'' || c == '"' {
                    quote = Some(c);
                    out.push(c);
                } else if c == '/' && chars.peek() == Some(&'/') {
                    for n in chars.by_ref() {
                        if n == '\n' {
                            out.push('\n');
                            break;
                        }
                    }
                } else {
                    out.push(c);
                }
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"
var subdomains = [
    'thu',  // 清华
    'pku',  // 北大
];
var urls=[
	'xxbgwypx.cc/',
];
var otherUrls = [
	'https://huangguoai.pages.dev',
];
var foreverUrls = [
	  'https://huangguoai.com',
	JumpPage,
	'https://huangguoai.ai',
];
"#;

    #[test]
    fn parses_publish_js_arrays() {
        assert_eq!(js_array(SAMPLE, "var urls"), vec!["xxbgwypx.cc/"]);
        assert_eq!(js_array(SAMPLE, "var subdomains"), vec!["thu", "pku"]);
        assert_eq!(
            js_array(SAMPLE, "var foreverUrls"),
            vec!["https://huangguoai.com", "https://huangguoai.ai"]
        );
    }

    #[test]
    fn resolves_relative_script() {
        assert_eq!(
            absolute("https://huangguoai.pages.dev/", "publish.js?20261103-2"),
            "https://huangguoai.pages.dev/publish.js?20261103-2"
        );
        assert_eq!(
            absolute("https://huangguoai.pages.dev/", "/a/b.js"),
            "https://huangguoai.pages.dev/a/b.js"
        );
    }

    #[test]
    fn picks_script_src() {
        let html = r#"<link rel="stylesheet" href="publish.css?1" /><script type="text/javascript" src="publish.js?20261103-2"></script>"#;
        assert_eq!(script_src(html).as_deref(), Some("publish.js?20261103-2"));
        assert_eq!(
            script_src(
                "<script src='metrics.js'></script><script src = 'publish.js?v=2&amp;x=3'></script>"
            )
            .as_deref(),
            Some("publish.js?v=2&x=3")
        );
        assert_eq!(
            js_array(
                "const urlsExtra=['wrong']; let urls = ['valid.example'];",
                "var urls"
            ),
            vec!["valid.example"]
        );
    }

    /// 手动跑：`cargo test --lib -- --ignored lines::tests::mirrors_live -- --nocapture`
    #[tokio::test]
    #[ignore = "联网测试：请求上游镜像列表，手动用 --ignored 运行"]
    async fn mirrors_live() {
        match mirrors().await {
            Ok(v) => println!("{}", nextjson::to_string_pretty(&v).expect("json")),
            Err(e) => panic!("mirrors failed: {e}"),
        }
    }

    /// 手动跑：`cargo test --lib -- --ignored lines::tests::probe_live -- --nocapture`
    #[tokio::test]
    #[ignore = "联网测试：探测上游线路连通性，手动用 --ignored 运行"]
    async fn probe_live() {
        let urls = vec![
            "https://huangguoai.com".to_string(),
            "https://huangguoai.ai".to_string(),
        ];
        println!(
            "{}",
            nextjson::to_string_pretty(&probe(urls).await).expect("json")
        );
    }
}
