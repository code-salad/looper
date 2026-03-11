mod tools;
mod watcher;

use std::sync::Arc;

use rmcp::model::{
    CallToolRequestParams, CallToolResult, Content, Implementation, ListToolsResult,
    PaginatedRequestParams, ServerCapabilities, ServerInfo,
};
use rmcp::service::{RequestContext, RoleServer};
use rmcp::{ErrorData as McpError, ServerHandler, ServiceExt};
use tokio::sync::Mutex;

use crate::tools::build_list_tools_result;
use crate::watcher::WatcherManager;

// ── Debug Logging ────────────────────────────────────────────────────────────

fn log_file() -> String {
    format!("/tmp/looper-watcher-debug-{}.log", std::process::id())
}

pub fn log(message: &str) {
    use std::fs::OpenOptions;
    use std::io::Write;
    let timestamp = {
        use std::time::{SystemTime, UNIX_EPOCH};
        let d = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default();
        format!("{}.{:03}", d.as_secs(), d.subsec_millis())
    };
    let log_line = format!("[{}] {}\n", timestamp, message);
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(&log_file()) {
        let _ = file.write_all(log_line.as_bytes());
    }
}

fn init_log() {
    use std::fs;
    use std::io::Write;
    if let Ok(mut file) = fs::File::create(&log_file()) {
        let _ = writeln!(file, "=== Looper Watcher MCP Server Started (pid {}) ===", std::process::id());
    }
}

// ── Server ───────────────────────────────────────────────────────────────────

#[derive(Clone)]
struct WatcherServer {
    manager: Arc<Mutex<WatcherManager>>,
}

impl ServerHandler for WatcherServer {
    fn get_info(&self) -> ServerInfo {
        ServerInfo {
            protocol_version: Default::default(),
            capabilities: ServerCapabilities::builder().enable_tools().build(),
            server_info: Implementation {
                name: "looper-watcher".to_string(),
                title: None,
                version: "0.1.0".to_string(),
                description: None,
                icons: None,
                website_url: None,
            },
            instructions: Some("Manages GitHub issue watchers that poll repos for open unassigned issues and feed them to looper-ee.".to_string()),
        }
    }

    fn list_tools(
        &self,
        _request: Option<PaginatedRequestParams>,
        _context: RequestContext<RoleServer>,
    ) -> impl std::future::Future<Output = Result<ListToolsResult, McpError>> + Send + '_ {
        std::future::ready(Ok(build_list_tools_result()))
    }

    fn call_tool(
        &self,
        request: CallToolRequestParams,
        _context: RequestContext<RoleServer>,
    ) -> impl std::future::Future<Output = Result<CallToolResult, McpError>> + Send + '_ {
        let manager = self.manager.clone();

        async move {
            log(&format!("Tool called: {}", request.name));

            let args = request.arguments.as_ref();

            match request.name.as_ref() {
                "list_watchers" => {
                    let mgr = manager.lock().await;
                    let watchers = mgr.list_watchers();
                    let json = serde_json::to_string_pretty(&watchers).unwrap_or_default();
                    Ok(CallToolResult::success(vec![Content::text(json)]))
                }

                "setup_watcher" => {
                    let repo = args
                        .and_then(|a| a.get("repo"))
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string());

                    let repo = match repo {
                        Some(r) => r,
                        None => {
                            return Ok(CallToolResult::error(vec![Content::text(
                                "Error: 'repo' parameter is required (e.g. 'owner/repo')",
                            )]));
                        }
                    };

                    let interval_secs = args
                        .and_then(|a| a.get("interval_minutes"))
                        .and_then(|v| v.as_f64())
                        .map(|m| (m * 60.0) as u64)
                        .unwrap_or(600); // default 10 minutes

                    let mut mgr = manager.lock().await;
                    let watcher = mgr.setup_watcher(repo, interval_secs);
                    let json = serde_json::to_string_pretty(&watcher).unwrap_or_default();
                    Ok(CallToolResult::success(vec![Content::text(json)]))
                }

                "kill_all_watchers" => {
                    let mut mgr = manager.lock().await;
                    let count = mgr.kill_all_watchers();
                    Ok(CallToolResult::success(vec![Content::text(format!(
                        "Killed {} watcher(s).",
                        count
                    ))]))
                }

                "get_watcher_history" => {
                    let repo_filter = args
                        .and_then(|a| a.get("repo"))
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string());

                    let mgr = manager.lock().await;
                    let history = mgr.get_history(repo_filter.as_deref());
                    let json = serde_json::to_string_pretty(&history).unwrap_or_default();
                    Ok(CallToolResult::success(vec![Content::text(json)]))
                }

                _ => Ok(CallToolResult::error(vec![Content::text(format!(
                    "Unknown tool: {}",
                    request.name
                ))])),
            }
        }
    }
}

// ── Main ─────────────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() {
    init_log();

    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("error")),
        )
        .init();

    let manager = Arc::new(Mutex::new(WatcherManager::new()));

    // Graceful shutdown: kill all watchers on SIGTERM/SIGINT
    let shutdown_manager = manager.clone();
    tokio::spawn(async move {
        #[cfg(unix)]
        {
            use tokio::signal::unix::{signal, SignalKind};
            let mut sigterm = signal(SignalKind::terminate()).unwrap();
            let mut sigint = signal(SignalKind::interrupt()).unwrap();
            tokio::select! {
                _ = sigterm.recv() => {
                    log("Received SIGTERM, killing all watchers");
                }
                _ = sigint.recv() => {
                    log("Received SIGINT, killing all watchers");
                }
            }
        }
        #[cfg(not(unix))]
        {
            let _ = tokio::signal::ctrl_c().await;
        }
        let mut mgr = shutdown_manager.lock().await;
        mgr.kill_all_watchers();
        std::process::exit(0);
    });

    let server = WatcherServer { manager };

    eprintln!("Looper Watcher MCP Server v0.1.0 running on stdio");

    let transport = rmcp::transport::stdio();
    let service = match server.serve(transport).await {
        Ok(s) => s,
        Err(e) => {
            eprintln!("Server error: {}", e);
            std::process::exit(1);
        }
    };

    if let Err(e) = service.waiting().await {
        eprintln!("Service error: {}", e);
        std::process::exit(1);
    }
}
