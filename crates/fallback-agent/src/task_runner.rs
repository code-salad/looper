use std::collections::HashMap;
use std::sync::Arc;

use rmcp::model::{ProgressNotificationParam, ProgressToken};
use rmcp::service::Peer;
use rmcp::service::RoleServer;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;
use tokio::sync::{oneshot, Mutex};

use crate::types::{ProgressState, RunTaskConfig, StreamMessage, TaskResult, ToolOutput};

/// Format a number with K/M suffixes.
pub fn format_number(num: u64) -> String {
    if num >= 1_000_000 {
        format!("{:.1}M", num as f64 / 1_000_000.0)
    } else if num >= 1_000 {
        format!("{:.1}k", num as f64 / 1_000.0)
    } else {
        num.to_string()
    }
}

/// Format a duration in milliseconds.
pub fn format_duration(ms: u64) -> String {
    if ms < 1000 {
        format!("{}ms", ms)
    } else {
        format!("{}s", ms / 1000)
    }
}

/// Format a TaskResult into display text.
pub fn format_task_result(result: &TaskResult) -> String {
    if !result.success {
        let mut parts = vec![format!(
            "Error: {}",
            result.error.as_deref().unwrap_or("unknown error")
        )];
        if let Some(session_id) = &result.session_id {
            parts.push(format!("session_id: {}", session_id));
        }
        return parts.join("\n");
    }

    let tool_use_text = if result.tool_use_count == 1 {
        "1 tool use".to_string()
    } else {
        format!("{} tool uses", result.tool_use_count)
    };
    let tokens_text = format!("{} tokens", format_number(result.tokens));
    let duration_text = format_duration(result.duration_ms);
    let summary = format!(
        "Done ({} · {} · {})",
        tool_use_text, tokens_text, duration_text
    );

    let tool_outputs_text = if !result.tool_outputs.is_empty() {
        result
            .tool_outputs
            .iter()
            .map(|to| format!("[{}]\n{}", to.tool, to.output))
            .collect::<Vec<_>>()
            .join("\n\n")
    } else {
        String::new()
    };

    let mut parts: Vec<String> = Vec::new();
    if !tool_outputs_text.is_empty() {
        parts.push(tool_outputs_text);
    }
    if let Some(result_text) = &result.result {
        parts.push(result_text.clone());
    }
    if let Some(session_id) = &result.session_id {
        parts.push(format!("session_id: {}", session_id));
    }
    parts.push(summary);

    parts.join("\n\n")
}

/// Send a progress notification to the peer if a progress token is available.
async fn send_progress(
    peer: &Peer<RoleServer>,
    progress_token: &Option<ProgressToken>,
    progress: f64,
    total: Option<f64>,
    message: &str,
) {
    if let Some(token) = progress_token {
        let _ = peer
            .notify_progress(ProgressNotificationParam {
                progress_token: token.clone(),
                progress,
                total,
                message: Some(message.to_string()),
            })
            .await;
    }
}

/// Spawns a nested task (fresh Claude process) with streaming output.
pub async fn run_task(
    config: RunTaskConfig,
    progress_token: Option<ProgressToken>,
    peer: Peer<RoleServer>,
    active_processes: Arc<Mutex<HashMap<String, tokio::process::Child>>>,
) -> TaskResult {
    let label = config.name.clone().unwrap_or_else(|| "task".to_string());

    // Build CLI arguments
    let mut args: Vec<String> = vec![
        "-p".to_string(),
        config.prompt.clone(),
        "--output-format".to_string(),
        "stream-json".to_string(),
        "--verbose".to_string(),
        "--model".to_string(),
        config.model.clone(),
    ];

    // Permission mode
    if let Some(mode) = &config.mode {
        args.push("--permission-mode".to_string());
        args.push(mode.clone());
    }

    // Isolation via worktree
    if config.isolation.as_deref() == Some("worktree") {
        args.push("--worktree".to_string());
    }

    // Resume session or disable persistence
    if let Some(resume) = &config.resume {
        args.push("--resume".to_string());
        args.push(resume.clone());
    } else {
        args.push("--no-session-persistence".to_string());
    }

    // System prompt (from agent definitions — not user-facing)
    if let Some(system_prompt) = &config.system_prompt {
        args.push("--system-prompt".to_string());
        args.push(system_prompt.clone());
    }

    // Tool restrictions (from agent definitions — not user-facing)
    if let Some(disallowed) = &config.disallowed_tools {
        if !disallowed.is_empty() {
            args.push("--disallowed-tools".to_string());
            for tool in disallowed {
                args.push(tool.clone());
            }
        }
    }

    // Pass plugin directory so spawned process has access to the same plugins
    let plugin_root = std::env::var("CLAUDE_PLUGIN_ROOT").ok();
    if let Some(plugin_dir) = &plugin_root {
        args.push("--plugin-dir".to_string());
        args.push(plugin_dir.clone());
    }

    crate::log(&format!(
        "[{}] CLAUDE_PLUGIN_ROOT={}",
        label,
        plugin_root.as_deref().unwrap_or("(not set)")
    ));
    crate::log(&format!(
        "[{}] Spawning claude with args: {:?}",
        label, args
    ));
    crate::log(&format!("[{}] Working dir: {}", label, config.working_dir));

    // Generate unique process ID
    let process_id = format!(
        "{}-{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis(),
        std::process::id()
    );

    // Spawn Claude CLI
    let mut child = match Command::new("claude")
        .args(&args)
        .current_dir(&config.working_dir)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => {
            return TaskResult {
                success: false,
                result: None,
                error: Some(format!("Failed to spawn claude: {}", e)),
                session_id: None,
                usage: None,
                tool_use_count: 0,
                duration_ms: 0,
                tokens: 0,
                tool_outputs: Vec::new(),
            };
        }
    };

    crate::log(&format!(
        "[{}] Process spawned with PID: {:?}",
        label,
        child.id()
    ));

    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();

    // Track process for abort
    {
        let mut procs = active_processes.lock().await;
        procs.insert(process_id.clone(), child);
    }

    // Spawn stderr reader
    let (stderr_tx, stderr_rx) = oneshot::channel::<String>();
    tokio::spawn(async move {
        let mut reader = BufReader::new(stderr);
        let mut stderr_buf = String::new();
        use tokio::io::AsyncReadExt;
        let _ = reader.read_to_string(&mut stderr_buf).await;
        let _ = stderr_tx.send(stderr_buf);
    });

    // Parse streaming JSON output line by line
    let mut state = ProgressState::new();
    let mut last_result: Option<StreamMessage> = None;
    let mut timed_out = false;
    let mut max_turns_reached = false;
    let timeout_ms = config.timeout_ms;
    let max_turns = config.max_turns;

    let mut lines = BufReader::new(stdout).lines();

    // Use timeout for the whole streaming loop
    let result = tokio::time::timeout(std::time::Duration::from_millis(timeout_ms), async {
        while let Ok(Some(line)) = lines.next_line().await {
            let line = line.trim().to_string();
            crate::log(&format!(
                "[{}] STDOUT line: {}{}",
                label,
                &line[..line.len().min(200)],
                if line.len() > 200 { "..." } else { "" }
            ));

            if line.is_empty() {
                continue;
            }

            let msg: StreamMessage = match serde_json::from_str(&line) {
                Ok(m) => m,
                Err(_) => continue,
            };

            match msg.msg_type.as_str() {
                "system" => {
                    if let Some(sid) = &msg.session_id {
                        state.session_id = Some(sid.clone());
                    }
                    send_progress(
                        &peer,
                        &progress_token,
                        0.0,
                        None,
                        &format!(
                            "Session initialized ({}...)",
                            msg.session_id
                                .as_deref()
                                .unwrap_or("")
                                .chars()
                                .take(8)
                                .collect::<String>()
                        ),
                    )
                    .await;
                }
                "assistant" => {
                    state.assistant_turn_count += 1;

                    // Check max_turns limit
                    if let Some(max) = max_turns {
                        if state.assistant_turn_count > max {
                            crate::log(&format!(
                                "[{}] max_turns ({}) exceeded at turn {}, stopping",
                                label, max, state.assistant_turn_count
                            ));
                            max_turns_reached = true;
                            break;
                        }
                    }

                    if let Some(body) = &msg.message {
                        if let Some(content) = &body.content {
                            for block in content {
                                if block.block_type == "tool_use" {
                                    if let Some(name) = &block.name {
                                        state.tool_use_count += 1;
                                        state.current_tool_use = Some(name.clone());

                                        let input_preview = block
                                            .input
                                            .as_ref()
                                            .map(|i| {
                                                let s =
                                                    serde_json::to_string(i).unwrap_or_default();
                                                format!(" ({}...)", &s[..s.len().min(50)])
                                            })
                                            .unwrap_or_default();

                                        send_progress(
                                            &peer,
                                            &progress_token,
                                            state.tool_use_count as f64,
                                            None,
                                            &format!("Tool: {}{}", name, input_preview),
                                        )
                                        .await;
                                    }
                                } else if block.block_type == "text" {
                                    if let Some(text) = &block.text {
                                        send_progress(
                                            &peer,
                                            &progress_token,
                                            state.tool_use_count as f64,
                                            None,
                                            &format!(
                                                "Response: {}{}",
                                                &text[..text.len().min(100)],
                                                if text.len() > 100 { "..." } else { "" }
                                            ),
                                        )
                                        .await;
                                    }
                                }
                            }
                        }
                    }
                }
                "user" => {
                    if let Some(tool_result) = &msg.tool_use_result {
                        let stdout_text = tool_result.stdout.as_deref().unwrap_or("");
                        if !stdout_text.is_empty() {
                            if let Some(current_tool) = &state.current_tool_use {
                                state.tool_outputs.push(ToolOutput {
                                    tool: current_tool.clone(),
                                    output: stdout_text.to_string(),
                                });
                            }
                        }
                        let result_preview = if stdout_text.is_empty() {
                            "(no output)".to_string()
                        } else {
                            format!(
                                "{}{}",
                                &stdout_text[..stdout_text.len().min(50)],
                                if stdout_text.len() > 50 { "..." } else { "" }
                            )
                        };
                        send_progress(
                            &peer,
                            &progress_token,
                            state.tool_use_count as f64,
                            None,
                            &format!("Result: {}", result_preview),
                        )
                        .await;
                    }
                }
                "result" => {
                    last_result = Some(msg);
                }
                _ => {}
            }
        }
    })
    .await;

    if result.is_err() {
        timed_out = true;
        // Kill the process on timeout
        let mut procs = active_processes.lock().await;
        if let Some(child) = procs.get_mut(&process_id) {
            let _ = child.kill().await;
        }
    }

    // Kill process if max turns reached
    if max_turns_reached {
        let mut procs = active_processes.lock().await;
        if let Some(child) = procs.get_mut(&process_id) {
            let _ = child.kill().await;
        }
    }

    // Wait for process to finish and get exit code
    let exit_code = {
        let mut map = active_processes.lock().await;
        if let Some(mut child) = map.remove(&process_id) {
            drop(map);
            tokio::time::timeout(std::time::Duration::from_secs(10), child.wait())
                .await
                .ok()
                .and_then(|r| r.ok())
                .and_then(|s| s.code())
        } else {
            None
        }
    };

    let duration_ms = state.elapsed_ms();
    let stderr_text = stderr_rx.await.unwrap_or_default();

    crate::log(&format!(
        "[{}] Process closed with code: {:?}, duration: {}ms, timedOut: {}, maxTurnsReached: {}, hasResult: {}",
        label, exit_code, duration_ms, timed_out, max_turns_reached, last_result.is_some()
    ));

    if timed_out {
        return TaskResult {
            success: false,
            result: None,
            error: Some(format!("Task timed out after {}ms", timeout_ms)),
            session_id: state.session_id,
            usage: None,
            tool_use_count: state.tool_use_count,
            duration_ms,
            tokens: 0,
            tool_outputs: state.tool_outputs,
        };
    }

    if max_turns_reached {
        let total_tokens = last_result
            .as_ref()
            .and_then(|r| r.usage.as_ref())
            .map(|u| u.total_tokens())
            .unwrap_or(0);
        let result_text = last_result
            .as_ref()
            .and_then(|r| r.result.clone())
            .unwrap_or_else(|| format!("(stopped after {} turns)", max_turns.unwrap_or(0)));

        return TaskResult {
            success: true,
            result: Some(result_text),
            error: None,
            session_id: state.session_id,
            usage: last_result.and_then(|r| r.usage),
            tool_use_count: state.tool_use_count,
            duration_ms,
            tokens: total_tokens,
            tool_outputs: state.tool_outputs,
        };
    }

    if let Some(last) = last_result {
        let total_tokens = last.usage.as_ref().map(|u| u.total_tokens()).unwrap_or(0);

        // Emit final progress
        send_progress(
            &peer,
            &progress_token,
            state.tool_use_count as f64,
            Some(state.tool_use_count as f64),
            &format!(
                "Done ({} tool uses, {}ms, ${})",
                state.tool_use_count,
                duration_ms,
                last.total_cost_usd
                    .map(|c| format!("{:.4}", c))
                    .as_deref()
                    .unwrap_or("?")
            ),
        )
        .await;

        TaskResult {
            success: !last.is_error.unwrap_or(false),
            result: last.result,
            error: None,
            session_id: state.session_id,
            usage: last.usage,
            tool_use_count: state.tool_use_count,
            duration_ms,
            tokens: total_tokens,
            tool_outputs: state.tool_outputs,
        }
    } else if exit_code == Some(0) {
        TaskResult {
            success: true,
            result: Some("(completed with no output)".to_string()),
            error: None,
            session_id: state.session_id,
            usage: None,
            tool_use_count: state.tool_use_count,
            duration_ms,
            tokens: 0,
            tool_outputs: state.tool_outputs,
        }
    } else {
        TaskResult {
            success: false,
            result: None,
            error: Some(if !stderr_text.trim().is_empty() {
                stderr_text.trim().to_string()
            } else {
                format!("Process exited with code {:?}", exit_code)
            }),
            session_id: state.session_id,
            usage: None,
            tool_use_count: state.tool_use_count,
            duration_ms,
            tokens: 0,
            tool_outputs: state.tool_outputs,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_format_number() {
        assert_eq!(format_number(0), "0");
        assert_eq!(format_number(999), "999");
        assert_eq!(format_number(1000), "1.0k");
        assert_eq!(format_number(1500), "1.5k");
        assert_eq!(format_number(1_000_000), "1.0M");
        assert_eq!(format_number(2_500_000), "2.5M");
    }

    #[test]
    fn test_format_duration() {
        assert_eq!(format_duration(0), "0ms");
        assert_eq!(format_duration(999), "999ms");
        assert_eq!(format_duration(1000), "1s");
        assert_eq!(format_duration(5000), "5s");
    }

    #[test]
    fn test_format_task_result_success() {
        let result = TaskResult {
            success: true,
            result: Some("The answer is 42.".to_string()),
            error: None,
            session_id: Some("abc123".to_string()),
            usage: None,
            tool_use_count: 3,
            duration_ms: 5000,
            tokens: 1500,
            tool_outputs: Vec::new(),
        };
        let text = format_task_result(&result);
        assert!(text.contains("The answer is 42."));
        assert!(text.contains("session_id: abc123"));
        assert!(text.contains("3 tool uses"));
        assert!(text.contains("1.5k tokens"));
        assert!(text.contains("5s"));
    }

    #[test]
    fn test_format_task_result_error() {
        let result = TaskResult {
            success: false,
            result: None,
            error: Some("Something went wrong".to_string()),
            session_id: Some("abc123".to_string()),
            usage: None,
            tool_use_count: 0,
            duration_ms: 0,
            tokens: 0,
            tool_outputs: Vec::new(),
        };
        let text = format_task_result(&result);
        assert!(text.contains("Error: Something went wrong"));
        assert!(text.contains("session_id: abc123"));
    }

    #[test]
    fn test_format_task_result_with_tool_outputs() {
        let result = TaskResult {
            success: true,
            result: Some("Done.".to_string()),
            error: None,
            session_id: None,
            usage: None,
            tool_use_count: 1,
            duration_ms: 1000,
            tokens: 100,
            tool_outputs: vec![ToolOutput {
                tool: "Read".to_string(),
                output: "file contents".to_string(),
            }],
        };
        let text = format_task_result(&result);
        assert!(text.contains("[Read]"));
        assert!(text.contains("file contents"));
    }

    #[test]
    fn test_format_task_result_single_tool_use() {
        let result = TaskResult {
            success: true,
            result: None,
            error: None,
            session_id: None,
            usage: None,
            tool_use_count: 1,
            duration_ms: 100,
            tokens: 0,
            tool_outputs: Vec::new(),
        };
        let text = format_task_result(&result);
        assert!(text.contains("1 tool use"));
        assert!(!text.contains("1 tool uses"));
    }
}
