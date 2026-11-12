//! ECH（Encrypted Client Hello）直连。
//!
//! # 与域名前置的区别
//!
//! - **前置**（`fronting.rs`）：URL 改写成 IP、**不发 SNI**，靠 `Host` 头路由。
//!   适合不依赖 SNI 的站点（如 e-hentai 的 Cloudflare 边缘）。
//! - **ECH**（本模块）：URL 保持域名、SNI 加密，外层 SNI 是 ECHConfig 里的
//!   `public_name`（Cloudflare 一般是 `cloudflare-ech.com`），边缘解密后按真实
//!   域名路由。适合「必须看 SNI」的 Cloudflare 站点（如哔咔的分流线路）。
//!
//! # 插件怎么用
//!
//! 通过公开的 `fronting.setEchHosts` 登记域名：
//!
//! ```json
//! { "picaapi.part26.art": { "ips": ["104.21.86.93"], "ech": "<base64>" } }
//! ```
//!
//! - `ips` / `ech` 都可以省略：省略时宿主用 DoH 查 `HTTPS`(type 65) 记录，
//!   从 `ipv4hint` / `ech` 参数补齐；
//! - IP 通过 `reqwest::ClientBuilder::resolve_to_addrs` 钉死，避免 DNS 污染；
//! - ECHConfig 缓存 [`ECH_CONFIG_TTL`]，过期后下一次请求重新拉取。
//!
//! 任何一步失败都返回 `None`，请求回退到普通链路——不会因为 ECH 拉不到就把请求打死。
//!
//! # 信任模型
//!
//! 与前置表一样按 runtime（插件）隔离；域名与 IP 在登记时校验（公网地址，
//! `allow_private_network` 打开时放行保留地址）。ECH 路径用 webpki 根证书校验，
//! 不跟随重定向，强制 HTTP/1.1（与前置客户端保持一致）。

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};

use anyhow::{Context as _, Result as AnyResult, anyhow};
use base64::Engine as _;
use reqwest::redirect::Policy;
use reqwest_middleware::ClientWithMiddleware;
use rustls::client::{EchConfig, EchMode};
use rustls::crypto::aws_lc_rs::hpke;
use rustls::pki_types::EchConfigListBytes;
use serde_json::{Value, json};

use super::fronting::validate_probe_ip;
use super::http::{HttpClientConfig, apply_proxy_config, worker_http_config, wrap_http_client};

/// ECHConfig 缓存时长。
const ECH_CONFIG_TTL: Duration = Duration::from_secs(3600);
/// DoH 请求超时。
const ECH_DOH_TIMEOUT: Duration = Duration::from_secs(8);
/// 单个域名最多钉几个 IP。
const ECH_MAX_IPS: usize = 8;
/// DoH 端点：先 Cloudflare（IP 字面量，不依赖 DNS），再 Google。
const ECH_DOH_ENDPOINTS: [&str; 2] = ["https://1.1.1.1/dns-query", "https://dns.google/resolve"];

/// 单个域名的 ECH 状态。
struct EchEntry {
    /// 登记时给的 IP（可为空，空则用 DoH 的 `ipv4hint`）。
    ips: Vec<String>,
    /// 登记时给的 ECHConfigList（base64），可为空。
    ech_b64: Option<String>,
    /// ECHConfig 是否由插件显式提供（提供时宿主不覆盖，只按 TTL 重建 client）。
    ech_from_plugin: bool,
    /// 最近一次成功构建 client 的时间。
    fetched_at: Option<Instant>,
    /// 用当前 ECHConfig + IP 构建好的 client。
    client: Option<ClientWithMiddleware>,
}

impl EchEntry {
    fn new(ips: Vec<String>, ech_b64: Option<String>) -> Self {
        Self {
            ips,
            ech_from_plugin: ech_b64.is_some(),
            ech_b64,
            fetched_at: None,
            client: None,
        }
    }

    fn is_fresh(&self, now: Instant) -> bool {
        self.client.is_some()
            && self
                .fetched_at
                .map(|at| now.duration_since(at) < ECH_CONFIG_TTL)
                .unwrap_or(false)
    }
}

/// 按 runtime（插件）隔离的 ECH 表。
static ECH_STATES: LazyLock<Mutex<HashMap<String, HashMap<String, EchEntry>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// 是否有任何插件登记过 ECH 域名；为空时热路径只做一次原子读。
static ECH_ACTIVE: AtomicBool = AtomicBool::new(false);

fn states() -> &'static Mutex<HashMap<String, HashMap<String, EchEntry>>> {
    &ECH_STATES
}

/// 规范化并校验 ECH 域名：只接受普通域名（拒绝 IP、端口、路径、空白）。
fn normalize_ech_host(raw: &str) -> Option<String> {
    let host = raw
        .trim()
        .trim_start_matches("https://")
        .trim_start_matches("http://")
        .trim_end_matches('/')
        .to_ascii_lowercase();
    if host.is_empty() || host.len() > 253 || !host.is_ascii() {
        return None;
    }
    if host.contains('/') || host.contains(':') || host.contains(char::is_whitespace) {
        return None;
    }
    if host.parse::<std::net::IpAddr>().is_ok() {
        return None;
    }
    if !host.contains('.') || host == "localhost" {
        return None;
    }
    Some(host)
}

/// 校验并去重 IP 列表。
fn normalize_ech_ips(raw: &[String], allow_private_network: bool) -> (Vec<String>, usize) {
    let mut ips = Vec::new();
    let mut rejected = 0usize;
    for candidate in raw {
        match validate_probe_ip(candidate, allow_private_network) {
            Some(ip) => {
                if !ips.contains(&ip) {
                    ips.push(ip);
                }
            }
            None => rejected += 1,
        }
    }
    ips.truncate(ECH_MAX_IPS);
    (ips, rejected)
}

/// 下发 ECH 域名表。`payload` 是 JSON 字符串：
///
/// - `{ "host": { "ips": ["1.2.3.4"], "ech": "<base64>" } }`
/// - 简写 `{ "host": ["1.2.3.4"] }`
///
/// 传空对象等于关闭 ECH。
pub fn set_ech_hosts(runtime: &str, payload: String) -> String {
    let parsed: Value = match serde_json::from_str(&payload) {
        Ok(value) => value,
        Err(error) => {
            return json!({
                "ok": false,
                "error": crate::tr!("failed-to-parse-front-hosts-json", e = error.to_string()),
            })
            .to_string();
        }
    };

    let allow_private_network = worker_http_config().allow_private_network;
    let mut table: HashMap<String, EchEntry> = HashMap::new();
    let mut rejected = 0usize;

    if let Value::Object(entries) = parsed {
        for (raw_host, raw_value) in entries {
            let Some(host) = normalize_ech_host(&raw_host) else {
                rejected += 1;
                continue;
            };

            let (raw_ips, ech_b64) = match raw_value {
                Value::Array(items) => (
                    items
                        .iter()
                        .filter_map(|item| item.as_str().map(str::to_string))
                        .collect::<Vec<_>>(),
                    None,
                ),
                Value::Object(fields) => {
                    let ips = fields
                        .get("ips")
                        .and_then(Value::as_array)
                        .map(|items| {
                            items
                                .iter()
                                .filter_map(|item| item.as_str().map(str::to_string))
                                .collect::<Vec<_>>()
                        })
                        .unwrap_or_default();
                    let ech = fields
                        .get("ech")
                        .and_then(Value::as_str)
                        .map(str::trim)
                        .filter(|value| !value.is_empty())
                        .map(str::to_string);
                    (ips, ech)
                }
                Value::Null => (Vec::new(), None),
                _ => {
                    rejected += 1;
                    continue;
                }
            };

            let (ips, ip_rejected) = normalize_ech_ips(&raw_ips, allow_private_network);
            rejected += ip_rejected;

            // ECHConfig 给了就先校验能不能解码；解不开直接拒绝该条，避免每次请求都失败。
            let ech_b64 = match ech_b64 {
                Some(value) => match base64::engine::general_purpose::STANDARD.decode(value.trim())
                {
                    Ok(_) => Some(value),
                    Err(_) => {
                        rejected += 1;
                        continue;
                    }
                },
                None => None,
            };

            table.insert(host, EchEntry::new(ips, ech_b64));
        }
    }

    let host_count = table.len();
    let ip_count: usize = table.values().map(|entry| entry.ips.len()).sum();

    let mut guard = match states().lock() {
        Ok(guard) => guard,
        Err(_) => {
            return json!({ "ok": false, "error": crate::tr!("front-host-state-lock-is-poisoned") })
                .to_string();
        }
    };
    if table.is_empty() {
        guard.remove(runtime);
    } else {
        guard.insert(runtime.to_string(), table);
    }
    ECH_ACTIVE.store(!guard.is_empty(), Ordering::Release);

    json!({
        "ok": true,
        "hosts": host_count,
        "ips": ip_count,
        "rejected": rejected,
        "allowPrivateNetwork": allow_private_network,
    })
    .to_string()
}

/// 读回当前 ECH 表（不含 client）。
pub fn get_ech_hosts(runtime: &str) -> String {
    let guard = match states().lock() {
        Ok(guard) => guard,
        Err(_) => {
            return json!({ "ok": false, "error": crate::tr!("front-host-state-lock-is-poisoned") })
                .to_string();
        }
    };
    let Some(table) = guard.get(runtime) else {
        return json!({ "ok": true, "hosts": {} }).to_string();
    };

    let now = Instant::now();
    let hosts: serde_json::Map<String, Value> = table
        .iter()
        .map(|(host, entry)| {
            (
                host.clone(),
                json!({
                    "ips": entry.ips,
                    "ech": entry.ech_b64.is_some(),
                    "fresh": entry.is_fresh(now),
                }),
            )
        })
        .collect();

    json!({ "ok": true, "hosts": Value::Object(hosts) }).to_string()
}

/// 清空当前插件的 ECH 表。
pub fn clear_ech_hosts(runtime: &str) -> String {
    if let Ok(mut guard) = states().lock() {
        guard.remove(runtime);
        ECH_ACTIVE.store(!guard.is_empty(), Ordering::Release);
    }
    json!({ "ok": true }).to_string()
}

/// 命中 ECH 表时返回专用 client；未登记 / 构建失败返回 `None`。
pub(crate) async fn ech_client_for(runtime: &str, url: &str) -> Option<ClientWithMiddleware> {
    if !ECH_ACTIVE.load(Ordering::Acquire) {
        return None;
    }
    let host = reqwest::Url::parse(url)
        .ok()?
        .host_str()?
        .to_ascii_lowercase();
    let config = worker_http_config();

    let (mut ips, mut ech_b64, ech_from_plugin) = {
        let guard = states().lock().ok()?;
        let entry = guard.get(runtime)?.get(&host)?;
        if entry.is_fresh(Instant::now()) {
            return entry.client.clone();
        }
        (
            entry.ips.clone(),
            entry.ech_b64.clone(),
            entry.ech_from_plugin,
        )
    };

    // 缺 ECHConfig / 缺 IP / 缓存过期时用 DoH 补（DoH 端点用 IP 字面量，不依赖系统 DNS）。
    // 插件显式给过 ECHConfig 时不覆盖它，只补 IP。
    let need_ech = !ech_from_plugin;
    let need_ips = ips.is_empty();
    if need_ech || need_ips {
        if let Some((doh_ech, doh_ips)) = fetch_doh_https(&host).await {
            if need_ech {
                ech_b64 = Some(doh_ech);
            }
            if need_ips {
                let (normalized, _) = normalize_ech_ips(&doh_ips, config.allow_private_network);
                ips = normalized;
            }
        }
    }

    let ech_b64 = ech_b64?;
    tracing::debug!(
        "ech: building client for {host} ips={:?} from_plugin={ech_from_plugin}",
        ips
    );
    let client = match build_ech_client(&host, &ips, &ech_b64, &config) {
        Ok(client) => client,
        Err(error) => {
            tracing::warn!("ech: failed to build client for {host}: {error:#}");
            return None;
        }
    };

    if let Ok(mut guard) = states().lock() {
        if let Some(entry) = guard
            .get_mut(runtime)
            .and_then(|table| table.get_mut(&host))
        {
            entry.ech_b64 = Some(ech_b64);
            if entry.ips.is_empty() {
                entry.ips = ips;
            }
            entry.fetched_at = Some(Instant::now());
            entry.client = Some(client.clone());
        }
    }
    Some(client)
}

/// 请求失败时丢掉缓存的 client，下一次重新拉 ECHConfig / 换 IP 重建。
///
/// `InvalidContentType` 这类 TLS 抖动通常是某次连接被中间设备打断；重建后
/// 大概率换到另一条 hint IP 或新的连接，重试即可恢复。
pub(crate) fn invalidate_ech_client(runtime: &str, url: &str) {
    let Some(host) = reqwest::Url::parse(url)
        .ok()
        .and_then(|parsed| parsed.host_str().map(str::to_ascii_lowercase))
    else {
        return;
    };
    if let Ok(mut guard) = states().lock() {
        if let Some(entry) = guard
            .get_mut(runtime)
            .and_then(|table| table.get_mut(&host))
        {
            entry.client = None;
            entry.fetched_at = None;
            tracing::debug!("ech: invalidated client for {host}");
        }
    }
}

/// DoH 查 `HTTPS`(type 65) 记录，返回 `(ech, ipv4hint)`。
async fn fetch_doh_https(host: &str) -> Option<(String, Vec<String>)> {
    let client = reqwest::Client::builder()
        .timeout(ECH_DOH_TIMEOUT)
        .build()
        .ok()?;

    for endpoint in ECH_DOH_ENDPOINTS {
        let url = format!("{endpoint}?name={host}&type=65");
        let response = match client
            .get(&url)
            .header("accept", "application/dns-json")
            .send()
            .await
        {
            Ok(response) => response,
            Err(error) => {
                tracing::debug!("ech: doh {endpoint} failed for {host}: {error}");
                continue;
            }
        };
        let json: Value = match response.json().await {
            Ok(json) => json,
            Err(_) => continue,
        };
        if let Some(parsed) = parse_https_rr(&json) {
            tracing::debug!(
                "ech: doh {host} via {endpoint} -> ips={:?} ech_len={}",
                parsed.1,
                parsed.0.len()
            );
            return Some(parsed);
        }
    }
    None
}

/// 从 DoH 的 HTTPS RR 里取 `ech=` 与 `ipv4hint=`。
fn parse_https_rr(json: &Value) -> Option<(String, Vec<String>)> {
    let answers = json.get("Answer")?.as_array()?;
    for answer in answers {
        let Some(data) = answer.get("data").and_then(Value::as_str) else {
            continue;
        };
        let mut ech = None;
        let mut ips = Vec::new();
        for token in data.split_whitespace() {
            if let Some(value) = token.strip_prefix("ech=") {
                if !value.is_empty() {
                    ech = Some(value.to_string());
                }
            } else if let Some(value) = token.strip_prefix("ipv4hint=") {
                ips.extend(
                    value
                        .split(',')
                        .map(str::trim)
                        .filter(|item| !item.is_empty())
                        .map(str::to_string),
                );
            }
        }
        if let Some(ech) = ech {
            return Some((ech, ips));
        }
    }
    None
}

/// 用 ECHConfig + 钉死的 IP 构建 reqwest client。
fn build_ech_client(
    host: &str,
    ips: &[String],
    ech_b64: &str,
    config: &HttpClientConfig,
) -> AnyResult<ClientWithMiddleware> {
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(ech_b64.trim())
        .context("invalid ech config base64")?;
    let ech = EchConfig::new(EchConfigListBytes::from(bytes), hpke::ALL_SUPPORTED_SUITES)
        .map_err(|error| anyhow!("invalid ech config: {error}"))?;

    let mut roots = rustls::RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());

    // `with_ech` 只挂在 `WantsVersions` 上，必须用 builder_with_provider 起链；
    // provider 与 reqwest 的 `rustls` feature 一致（aws-lc-rs），避免进程默认 provider 冲突。
    let provider = std::sync::Arc::new(rustls::crypto::aws_lc_rs::default_provider());
    let mut tls = rustls::ClientConfig::builder_with_provider(provider)
        .with_ech(EchMode::Enable(ech))
        .map_err(|error| anyhow!("enable ech failed: {error}"))?
        .with_root_certificates(roots)
        .with_no_client_auth();
    tls.alpn_protocols = vec![b"http/1.1".to_vec()];

    let mut builder = reqwest::Client::builder()
        .http1_only()
        .redirect(Policy::none())
        .pool_max_idle_per_host(0);

    let addrs: Vec<SocketAddr> = ips
        .iter()
        .filter_map(|ip| format!("{ip}:443").parse::<SocketAddr>().ok())
        .collect();
    if !addrs.is_empty() {
        builder = builder.resolve_to_addrs(host, &addrs);
    }

    builder = apply_proxy_config(builder, config)?;
    // 注意：`tls_backend_preconfigured` 内部会自己包一层 `Some`，这里传裸 ClientConfig。
    builder = builder.tls_backend_preconfigured(tls);

    let client = builder.build().context("build ech client failed")?;
    Ok(wrap_http_client(client))
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_RUNTIME: &str = "test-ech-runtime";

    fn with_serialized_state<T>(f: impl FnOnce() -> T) -> T {
        static LOCK: Mutex<()> = Mutex::new(());
        let _guard = LOCK.lock().unwrap_or_else(|error| error.into_inner());
        f()
    }

    #[test]
    fn normalizes_domains_and_rejects_ip_port_path() {
        assert_eq!(
            normalize_ech_host("https://PicaAPI.Part26.Art/"),
            Some("picaapi.part26.art".to_string())
        );
        for raw in [
            "1.2.3.4",
            "example.com:443",
            "example.com/path",
            "localhost",
            "example",
            "",
        ] {
            assert!(
                normalize_ech_host(raw).is_none(),
                "{raw} should be rejected"
            );
        }
    }

    #[test]
    fn parses_https_rr_from_real_doh_payload() {
        let json: Value = serde_json::from_str(
            r#"{"Answer":[{"name":"picaapi.part26.art","type":65,"TTL":300,
            "data":"1 . alpn=h3,h2 ipv4hint=104.21.86.93,172.67.217.104 ech=AEX+AAA= ipv6hint=2606:4700::1"}]}"#,
        )
        .expect("valid json");
        let (ech, ips) = parse_https_rr(&json).expect("should parse");
        assert_eq!(ech, "AEX+AAA=");
        assert_eq!(ips, vec!["104.21.86.93", "172.67.217.104"]);
    }

    #[test]
    fn set_get_clear_roundtrip() {
        with_serialized_state(|| {
            clear_ech_hosts(TEST_RUNTIME);
            let result = set_ech_hosts(
                TEST_RUNTIME,
                json!({
                    "picaapi.part26.art": ["104.21.86.93", "not-an-ip"],
                    "https://PicaAPI.Go2778.com/": { "ips": ["104.21.42.75"] },
                    "1.2.3.4": ["104.21.86.93"],
                })
                .to_string(),
            );
            let parsed: Value = serde_json::from_str(&result).expect("json");
            assert_eq!(parsed["ok"], json!(true));
            assert_eq!(parsed["hosts"], json!(2));
            assert_eq!(parsed["ips"], json!(2));
            // 非法 IP + 非法域名各计一次
            assert_eq!(parsed["rejected"], json!(2));

            let table: Value = serde_json::from_str(&get_ech_hosts(TEST_RUNTIME)).expect("json");
            assert_eq!(
                table["hosts"]["picaapi.part26.art"]["ips"],
                json!(["104.21.86.93"])
            );
            assert_eq!(table["hosts"]["picaapi.go2778.com"]["ech"], json!(false));

            clear_ech_hosts(TEST_RUNTIME);
            let cleared: Value = serde_json::from_str(&get_ech_hosts(TEST_RUNTIME)).expect("json");
            assert_eq!(cleared["hosts"], json!({}));
        });
    }

    #[test]
    fn rejects_invalid_ech_base64() {
        with_serialized_state(|| {
            clear_ech_hosts(TEST_RUNTIME);
            let result = set_ech_hosts(
                TEST_RUNTIME,
                json!({ "picaapi.part26.art": { "ech": "not base64!!" } }).to_string(),
            );
            let parsed: Value = serde_json::from_str(&result).expect("json");
            assert_eq!(parsed["ok"], json!(true));
            assert_eq!(parsed["hosts"], json!(0));
            assert_eq!(parsed["rejected"], json!(1));
            clear_ech_hosts(TEST_RUNTIME);
        });
    }

    #[test]
    fn ech_client_for_unknown_host_is_none() {
        with_serialized_state(|| {
            clear_ech_hosts(TEST_RUNTIME);
            let client =
                futures_lite_block_on(ech_client_for(TEST_RUNTIME, "https://example.com/"));
            assert!(client.is_none());
        });
    }

    /// 公开 API：`fronting.setEchHosts` / `getEchHosts` / `clearEchHosts` 走普通对象。
    #[cfg(feature = "host-fronting")]
    #[test]
    fn js_public_ech_api_roundtrip() {
        let script = r#"
            (() => {
              const set = fronting.setEchHosts({ "picaapi.part26.art": {} });
              const get = fronting.getEchHosts();
              const clear = fronting.clearEchHosts();
              return JSON.stringify({ set, get, clear });
            })()
        "#;
        let result = crate::tests::run_async_script(script).expect("script should run");
        let parsed: Value = serde_json::from_str(&result).expect("json");
        assert_eq!(parsed["set"]["ok"], json!(true));
        assert_eq!(parsed["set"]["hosts"], json!(1));
        assert_eq!(
            parsed["get"]["hosts"]["picaapi.part26.art"]["ech"],
            json!(false)
        );
        assert_eq!(parsed["clear"]["ok"], json!(true));
    }

    /// feature 关闭时公开 API 仍在，但统一返回 unsupported。
    #[cfg(not(feature = "host-fronting"))]
    #[test]
    fn js_public_ech_api_unsupported_without_feature() {
        let script = r#"
            (() => {
              const set = fronting.setEchHosts({ "picaapi.part26.art": {} });
              const get = fronting.getEchHosts();
              const clear = fronting.clearEchHosts();
              return JSON.stringify({ set, get, clear });
            })()
        "#;
        let result = crate::tests::run_async_script(script).expect("script should run");
        let parsed: Value = serde_json::from_str(&result).expect("json");
        assert_eq!(parsed["set"]["error"], json!("fronting-unsupported"));
        assert_eq!(parsed["get"]["error"], json!("fronting-unsupported"));
        assert_eq!(parsed["clear"]["error"], json!("fronting-unsupported"));
    }

    /// 全链路联网冒烟：JS 侧 `fronting.setEchHosts` + `fetch` 走 ECH。
    /// 手动跑：`cargo test --features host-fronting -- --ignored --nocapture js_ech_fetch_smoke`
    #[cfg(feature = "host-fronting")]
    #[test]
    #[ignore]
    fn js_ech_fetch_smoke() {
        let script = r#"
            (async () => {
              const set = fronting.setEchHosts({ "picaapi.part26.art": {} });
              const res = await fetch("https://picaapi.part26.art/");
              const body = await res.text();
              const meta = res.hostMeta;
              fronting.clearEchHosts();
              return JSON.stringify({ set, status: res.status, body, meta });
            })()
        "#;
        let result = crate::tests::run_async_script(script).expect("script should run");
        println!("{result}");
        let parsed: Value = serde_json::from_str(&result).expect("json");
        assert_eq!(parsed["set"]["ok"], json!(true));
        assert_eq!(parsed["status"], json!(400));
        assert!(
            parsed["body"]
                .as_str()
                .unwrap_or_default()
                .contains("\"code\"")
        );
    }

    /// 逐 IP 冒烟：每个 DoH hint 单独建 ECH client，连发 3 次，看是否有坏 IP。
    /// `cargo test --features host-fronting -- --ignored --nocapture ech_per_ip_smoke`
    #[tokio::test]
    #[ignore]
    async fn ech_per_ip_smoke() {
        let host = "picaapi.part26.art";
        let (ech, ips) = fetch_doh_https(host).await.expect("doh");
        let config = HttpClientConfig::default();
        for ip in &ips {
            for round in 0..3 {
                let client = build_ech_client(host, std::slice::from_ref(ip), &ech, &config)
                    .expect("build client");
                let result = client.get(format!("https://{host}/")).send().await;
                match result {
                    Ok(response) => println!("{ip} round{round} -> {}", response.status()),
                    Err(error) => println!("{ip} round{round} -> ERR {error}"),
                }
            }
        }
    }

    /// 联网冒烟：DoH 拿 ECHConfig → 建 client → GET `/` 应拿到真 API 的 400 JSON。
    /// 默认忽略，手动跑：
    /// `cargo test --features host-fronting -- --ignored --nocapture ech_live_smoke`
    #[tokio::test]
    #[ignore]
    async fn ech_live_smoke() {
        let host = "picaapi.part26.art";
        let (ech, ips) = fetch_doh_https(host).await.expect("doh should return ech");
        println!("ech={ech} ips={ips:?}");
        let config = HttpClientConfig::default();
        let client = build_ech_client(host, &ips, &ech, &config).expect("build ech client");
        let response = client
            .get(format!("https://{host}/"))
            .send()
            .await
            .expect("request should complete");
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        println!("status={status} body={body}");
        assert!(body.contains("\"code\""), "unexpected body: {body}");
    }

    /// 小工具：测试里同步等一个 future（不引入额外依赖）。
    fn futures_lite_block_on<F: std::future::Future>(future: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime")
            .block_on(future)
    }
}
