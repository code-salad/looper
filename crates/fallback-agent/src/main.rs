mod agent_discovery;
mod task_runner;
mod tool_definitions;
mod types;

use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::Write as IoWrite;
use std::sync::Arc;

use rmcp::model::{
    CallToolRequestParams, CallToolResult, Content, Implementation, ListToolsResult,
    PaginatedRequestParams, ProgressToken, RequestParamsMeta, ServerCapabilities, ServerInfo,
};
use rmcp::service::{Peer, RequestContext, RoleServer};
use rmcp::{ErrorData as McpError, ServerHandler, ServiceExt};
use tokio::sync::Mutex;

use crate::agent_discovery::{compute_effective_disallowed_tools, discover_agents};
use crate::task_runner::{format_task_result, run_task};
use crate::tool_definitions::build_list_tools_result;
use crate::types::{
    AgentDefinition, BackgroundTask, BackgroundTaskStatus, RunTaskConfig, TaskInput,
};

// ── Debug Logging ────────────────────────────────────────────────────────────

fn log_file() -> String {
    format!("/tmp/fallback-agent-debug-{}.log", std::process::id())
}

pub fn log(message: &str) {
    let timestamp = simple_timestamp();
    let log_line = format!("[{}] {}\n", timestamp, message);
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(log_file()) {
        let _ = file.write_all(log_line.as_bytes());
    }
}

fn simple_timestamp() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let duration = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let secs = duration.as_secs();
    let millis = duration.subsec_millis();
    format!("{}.{:03}", secs, millis)
}

fn init_log() {
    if let Ok(mut file) = fs::File::create(log_file()) {
        let _ = writeln!(file, "=== Fallback Agent MCP Server Started (Rust, pid {}) ===", std::process::id());
        let _ = writeln!(
            file,
            "CLAUDE_PLUGIN_ROOT={}",
            std::env::var("CLAUDE_PLUGIN_ROOT").unwrap_or_else(|_| "(not set)".to_string())
        );
    }
}

// ── Server ───────────────────────────────────────────────────────────────────

#[derive(Clone)]
struct FallbackAgentServer {
    agents: Arc<HashMap<String, AgentDefinition>>,
    background_tasks: Arc<Mutex<HashMap<String, BackgroundTask>>>,
    active_processes: Arc<Mutex<HashMap<String, tokio::process::Child>>>,
}

impl FallbackAgentServer {
    fn new(agents: HashMap<String, AgentDefinition>) -> Self {
        Self {
            agents: Arc::new(agents),
            background_tasks: Arc::new(Mutex::new(HashMap::new())),
            active_processes: Arc::new(Mutex::new(HashMap::new())),
        }
    }
}

impl ServerHandler for FallbackAgentServer {
    fn get_info(&self) -> ServerInfo {
        ServerInfo {
            protocol_version: Default::default(),
            capabilities: ServerCapabilities::builder().enable_tools().build(),
            server_info: Implementation {
                name: "fallback-agent".to_string(),
                title: None,
                version: env!("CARGO_PKG_VERSION").to_string(),
                description: None,
                icons: None,
                website_url: None,
            },
            instructions: None,
        }
    }

    fn list_tools(
        &self,
        _request: Option<PaginatedRequestParams>,
        _context: RequestContext<RoleServer>,
    ) -> impl std::future::Future<Output = Result<ListToolsResult, McpError>> + Send + '_ {
        let result = build_list_tools_result(&self.agents);
        std::future::ready(Ok(result))
    }

    fn call_tool(
        &self,
        request: CallToolRequestParams,
        context: RequestContext<RoleServer>,
    ) -> impl std::future::Future<Output = Result<CallToolResult, McpError>> + Send + '_ {
        let agents = self.agents.clone();
        let background_tasks = self.background_tasks.clone();
        let active_processes = self.active_processes.clone();
        let peer = context.peer.clone();

        async move {
            log(&format!("Tool called: {}", request.name));

            // ── AgentFallbackStatus tool ──
            if request.name == "AgentFallbackStatus" {
                return handle_task_status(&request, &background_tasks).await;
            }

            // ── AgentFallback tool ──
            if request.name != "AgentFallback" {
                return Ok(CallToolResult::error(vec![Content::text(format!(
                    "Unknown tool: {}",
                    request.name
                ))]));
            }

            handle_task(request, agents, background_tasks, active_processes, peer).await
        }
    }
}

/// Handle the TaskStatus tool call.
async fn handle_task_status(
    request: &CallToolRequestParams,
    background_tasks: &Arc<Mutex<HashMap<String, BackgroundTask>>>,
) -> Result<CallToolResult, McpError> {
    let args = request.arguments.as_ref();
    let task_id = args
        .and_then(|a| a.get("taskId"))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());

    let task_id = match task_id {
        Some(id) => id,
        None => {
            return Ok(CallToolResult::error(vec![Content::text(
                "Error: taskId is required",
            )]));
        }
    };

    let tasks = background_tasks.lock().await;
    let entry = match tasks.get(&task_id) {
        Some(e) => e,
        None => {
            return Ok(CallToolResult::error(vec![Content::text(format!(
                "Error: unknown taskId \"{}\"",
                task_id
            ))]));
        }
    };

    if entry.status == BackgroundTaskStatus::Running {
        let json = serde_json::json!({ "taskId": task_id, "status": "running" });
        return Ok(CallToolResult::success(vec![Content::text(
            json.to_string(),
        )]));
    }

    // Completed or error
    if let Some(result) = &entry.result {
        let text = format_task_result(result);
        if result.success {
            Ok(CallToolResult::success(vec![Content::text(text)]))
        } else {
            Ok(CallToolResult::error(vec![Content::text(text)]))
        }
    } else {
        Ok(CallToolResult::error(vec![Content::text(
            "Error: task result not available",
        )]))
    }
}

/// Handle the AgentFallback tool call.
async fn handle_task(
    request: CallToolRequestParams,
    agents: Arc<HashMap<String, AgentDefinition>>,
    background_tasks: Arc<Mutex<HashMap<String, BackgroundTask>>>,
    active_processes: Arc<Mutex<HashMap<String, tokio::process::Child>>>,
    peer: Peer<RoleServer>,
) -> Result<CallToolResult, McpError> {
    // Extract progress token from request meta
    let progress_token: Option<ProgressToken> = request.progress_token();

    // Parse input from request arguments
    let input: TaskInput = match &request.arguments {
        Some(args) => {
            serde_json::from_value(serde_json::Value::Object(args.clone())).unwrap_or_default()
        }
        None => TaskInput::default(),
    };

    log(&format!(
        "Prompt: {}...",
        input
            .prompt
            .as_deref()
            .unwrap_or("")
            .chars()
            .take(100)
            .collect::<String>()
    ));
    log(&format!(
        "Model: {:?}, mode: {:?}, name: {:?}",
        input.model, input.mode, input.name
    ));

    let prompt = match &input.prompt {
        Some(p) if !p.is_empty() => p.clone(),
        _ => {
            return Ok(CallToolResult::error(vec![Content::text(
                "Error: prompt is required",
            )]));
        }
    };

    // Build internal config with defaults
    let mut config = RunTaskConfig {
        prompt,
        name: input.name.clone(),
        model: input.model.clone().unwrap_or_else(|| "sonnet".to_string()),
        mode: input.mode.clone(),
        isolation: input.isolation.clone(),
        resume: input.resume.clone(),
        max_turns: input.max_turns,
        system_prompt: None,
        disallowed_tools: None,
        working_dir: std::env::current_dir()
            .unwrap_or_else(|_| std::path::PathBuf::from("/"))
            .to_string_lossy()
            .to_string(),
        timeout_ms: 600_000,
    };

    // Apply agent definition defaults when subagent_type is specified
    if let Some(subagent_type) = &input.subagent_type {
        let agent = match agents.get(subagent_type) {
            Some(a) => a,
            None => {
                let available = if agents.is_empty() {
                    "(none discovered)".to_string()
                } else {
                    agents.keys().cloned().collect::<Vec<_>>().join(", ")
                };
                return Ok(CallToolResult::error(vec![Content::text(format!(
                    "Error: unknown subagent_type \"{}\". Available: {}",
                    subagent_type, available
                ))]));
            }
        };

        log(&format!(
            "Applying agent definition: {} (model={:?})",
            agent.qualified_name, agent.model
        ));

        // Agent markdown body → system prompt
        if !agent.system_prompt.is_empty() {
            config.system_prompt = Some(agent.system_prompt.clone());
        }

        // Agent model as default (explicit input.model takes precedence)
        if input.model.is_none() {
            if let Some(model) = &agent.model {
                config.model = model.clone();
            }
        }

        // Compute and apply disallowed tools from agent definition
        let effective = compute_effective_disallowed_tools(agent);
        if !effective.is_empty() {
            log(&format!(
                "Applied disallowed tools: {}",
                effective.join(", ")
            ));
            config.disallowed_tools = Some(effective);
        }
    }

    // Handle background execution
    if input.run_in_background == Some(true) {
        let task_id = format!(
            "task-{}-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis(),
            std::process::id()
        );

        let entry = BackgroundTask {
            task_id: task_id.clone(),
            status: BackgroundTaskStatus::Running,
            result: None,
        };

        {
            let mut tasks = background_tasks.lock().await;
            tasks.insert(task_id.clone(), entry);
        }

        let bg_tasks = background_tasks.clone();
        let bg_active = active_processes.clone();
        let bg_task_id = task_id.clone();
        let bg_progress_token = progress_token.clone();
        let bg_peer = peer.clone();

        tokio::spawn(async move {
            let result = run_task(config, bg_progress_token, bg_peer, bg_active).await;
            let mut tasks = bg_tasks.lock().await;
            if let Some(entry) = tasks.get_mut(&bg_task_id) {
                entry.status = if result.success {
                    BackgroundTaskStatus::Completed
                } else {
                    BackgroundTaskStatus::Error
                };
                entry.result = Some(result);
            }
        });

        let json = serde_json::json!({ "taskId": task_id, "status": "running" });
        return Ok(CallToolResult::success(vec![Content::text(
            json.to_string(),
        )]));
    }

    // Synchronous execution
    let result = run_task(config, progress_token, peer, active_processes).await;
    log(&format!(
        "Result: success={}, error={:?}",
        result.success, result.error
    ));

    let text = format_task_result(&result);
    if result.success {
        Ok(CallToolResult::success(vec![Content::text(text)]))
    } else {
        Ok(CallToolResult::error(vec![Content::text(text)]))
    }
}

// ── Main ─────────────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() {
    // Initialize debug log
    init_log();

    // Initialize tracing to stderr only for errors
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("error")),
        )
        .init();

    // Discover agents at startup
    let agents = discover_agents();
    log(&format!(
        "Discovered {} agent definition(s): {}",
        agents.len(),
        if agents.is_empty() {
            "(none)".to_string()
        } else {
            agents.keys().cloned().collect::<Vec<_>>().join(", ")
        }
    ));

    let server = FallbackAgentServer::new(agents);

    // Handle signals for graceful shutdown
    let active_processes = server.active_processes.clone();
    tokio::spawn(async move {
        #[cfg(unix)]
        {
            use tokio::signal::unix::{signal, SignalKind};
            let mut sigterm = signal(SignalKind::terminate()).unwrap();
            let mut sigint = signal(SignalKind::interrupt()).unwrap();

            tokio::select! {
                _ = sigterm.recv() => {
                    log("Received SIGTERM, killing active processes");
                    kill_active_processes(&active_processes).await;
                    std::process::exit(0);
                }
                _ = sigint.recv() => {
                    log("Received SIGINT, killing active processes");
                    kill_active_processes(&active_processes).await;
                    std::process::exit(0);
                }
            }
        }
        #[cfg(not(unix))]
        {
            let _ = tokio::signal::ctrl_c().await;
            kill_active_processes(&active_processes).await;
            std::process::exit(0);
        }
    });

    eprintln!("Fallback Agent MCP Server v{} (Rust) running on stdio", env!("CARGO_PKG_VERSION"));

    // Create stdio transport and serve
    let transport = rmcp::transport::stdio();
    let service = match server.serve(transport).await {
        Ok(s) => s,
        Err(e) => {
            eprintln!("Server error: {}", e);
            std::process::exit(1);
        }
    };

    // Keep the server alive until the client disconnects
    if let Err(e) = service.waiting().await {
        eprintln!("Service error: {}", e);
        std::process::exit(1);
    }
}

async fn kill_active_processes(
    active_processes: &Arc<Mutex<HashMap<String, tokio::process::Child>>>,
) {
    let process_ids: Vec<String> = {
        let procs = active_processes.lock().await;
        procs.keys().cloned().collect()
    };

    for id in process_ids {
        let mut procs = active_processes.lock().await;
        if let Some(child) = procs.get_mut(&id) {
            let _ = child.kill().await;
        }
    }
}
