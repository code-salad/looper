use std::path::{Path, PathBuf};
use std::sync::Arc;

use tokio::process::Command;
use tokio::sync::Mutex;

use crate::Cli;
use crate::github;
use crate::state::{Entry, State};

/// Shared app state for the TUI to read.
#[derive(Debug, Clone)]
pub struct AppState {
    pub state: Arc<Mutex<State>>,
    pub log_lines: Arc<Mutex<Vec<String>>>,
    pub last_poll: Arc<Mutex<Option<String>>>,
    pub next_poll: Arc<Mutex<Option<String>>>,
    pub open_issues: Arc<Mutex<Vec<github::Issue>>>,
}

impl AppState {
    pub fn new(state: State) -> Self {
        Self {
            state: Arc::new(Mutex::new(state)),
            log_lines: Arc::new(Mutex::new(Vec::new())),
            last_poll: Arc::new(Mutex::new(None)),
            next_poll: Arc::new(Mutex::new(None)),
            open_issues: Arc::new(Mutex::new(Vec::new())),
        }
    }

    pub async fn log(&self, msg: &str) {
        let line = format!("[{}] {}", chrono::Utc::now().format("%H:%M:%S"), msg);
        eprintln!("{line}");
        let mut lines = self.log_lines.lock().await;
        lines.push(line);
        // Keep last 200 lines
        if lines.len() > 200 {
            let excess = lines.len() - 200;
            lines.drain(..excess);
        }
    }
}

/// Run the poll loop indefinitely.
pub async fn run_loop(cli: &Cli, state_path: &Path, app: &AppState) {
    loop {
        poll_once(cli, state_path, app).await;

        {
            let next = chrono::Utc::now() + chrono::Duration::seconds(cli.interval as i64);
            *app.next_poll.lock().await = Some(next.format("%H:%M:%S").to_string());
        }

        tokio::time::sleep(tokio::time::Duration::from_secs(cli.interval)).await;
    }
}

/// Poll once: fetch issues, filter, assign, dispatch.
pub async fn poll_once(cli: &Cli, state_path: &Path, app: &AppState) {
    {
        *app.last_poll.lock().await = Some(chrono::Utc::now().format("%H:%M:%S").to_string());
    }

    app.log(&format!("polling {}...", cli.repo)).await;

    let issues = match github::fetch_open_unassigned(&cli.repo, cli.retries).await {
        Ok(issues) => issues,
        Err(e) => {
            app.log(&format!("error fetching issues: {e}")).await;
            return;
        }
    };

    // Update open issues for TUI
    {
        *app.open_issues.lock().await = issues.clone();
    }

    if issues.is_empty() {
        app.log("no open unassigned issues").await;
        return;
    }

    app.log(&format!("found {} open unassigned issue(s)", issues.len())).await;

    // Filter out blocked and already-in-progress issues
    let mut eligible = Vec::new();
    for issue in &issues {
        {
            let s: tokio::sync::MutexGuard<'_, State> = app.state.lock().await;
            if s.is_in_progress(issue.number) {
                app.log(&format!("#{}: skipping (in progress)", issue.number)).await;
                continue;
            }
        }

        if github::is_blocked(issue, &cli.repo).await {
            app.log(&format!("#{}: skipping (blocked)", issue.number)).await;
            continue;
        }

        eligible.push(issue);
    }

    if eligible.is_empty() {
        app.log("no eligible issues after filtering").await;
        return;
    }

    // Sort oldest first
    eligible.sort_by(|a, b| a.created_at.cmp(&b.created_at));

    // Determine available slots
    let in_progress_count = {
        let s: tokio::sync::MutexGuard<'_, State> = app.state.lock().await;
        s.in_progress.len()
    };
    let available_slots = cli.concurrency.saturating_sub(in_progress_count);
    if available_slots == 0 {
        app.log(&format!("max concurrency reached ({}/{})", in_progress_count, cli.concurrency)).await;
        return;
    }

    let to_process = &eligible[..eligible.len().min(available_slots)];

    for issue in to_process {
        app.log(&format!("#{}: {} — processing", issue.number, issue.title)).await;

        if cli.dry_run {
            app.log(&format!("#{}: dry run, skipping", issue.number)).await;
            continue;
        }

        // Assign with retries — bail if it fails
        if let Err(e) = github::assign_to_me(&cli.repo, issue.number, cli.retries).await {
            app.log(&format!("#{}: assign failed: {e}", issue.number)).await;
            continue;
        }
        app.log(&format!("#{}: assigned to @me", issue.number)).await;

        // Mark in progress and save
        {
            let mut s: tokio::sync::MutexGuard<'_, State> = app.state.lock().await;
            s.mark_in_progress(issue.number);
            s.save(state_path).await;
        }

        // Spawn claude in background
        let issue_url = format!("https://github.com/{}/issues/{}", cli.repo, issue.number);
        let allowed_tools = cli.allowed_tools.clone();
        let app_clone = app.clone();
        let state_path_clone = state_path.to_path_buf();
        let issue_number = issue.number;
        let issue_title = issue.title.clone();

        tokio::spawn(async move {
            run_claude(
                issue_number,
                &issue_title,
                &issue_url,
                &allowed_tools,
                &app_clone,
                &state_path_clone,
            )
            .await;
        });
    }
}

async fn run_claude(
    issue_number: u64,
    issue_title: &str,
    issue_url: &str,
    allowed_tools: &str,
    app: &AppState,
    state_path: &PathBuf,
) {
    let prompt = format!("/looper-ee {issue_url}");
    let session_name = format!("looper-{issue_number}");

    // Try tmux first, fall back to bare process
    let tmux_cmd = format!(
        "claude -p '{}' --allowedTools '{}'",
        prompt.replace('\'', "'\\''"),
        allowed_tools.replace('\'', "'\\''"),
    );

    app.log(&format!("#{issue_number}: spawning in tmux session '{session_name}'")).await;

    let tmux_result = Command::new("tmux")
        .args(["new-session", "-d", "-s", &session_name, &tmux_cmd])
        .output()
        .await;

    let use_tmux = match &tmux_result {
        Ok(o) if o.status.success() => true,
        _ => {
            app.log(&format!("#{issue_number}: tmux unavailable, using bare process")).await;
            false
        }
    };

    if use_tmux {
        // Wait for the tmux session to finish
        loop {
            tokio::time::sleep(tokio::time::Duration::from_secs(10)).await;
            let has = Command::new("tmux")
                .args(["has-session", "-t", &session_name])
                .output()
                .await;
            match has {
                Ok(o) if o.status.success() => continue, // still running
                _ => break,                               // session ended
            }
        }
        // tmux session ended — treat as success (we can't easily get exit code)
        let outcome = "completed (tmux)".to_string();
        app.log(&format!("#{issue_number}: {outcome}")).await;

        let entry = Entry {
            issue_number,
            issue_title: issue_title.to_string(),
            timestamp: chrono::Utc::now().to_rfc3339(),
            outcome,
            pid: None,
        };
        let mut s: tokio::sync::MutexGuard<'_, State> = app.state.lock().await;
        s.complete(entry);
        s.save(state_path).await;
    } else {
        // Bare process fallback
        let result = Command::new("claude")
            .args(["-p", &prompt, "--allowedTools", allowed_tools])
            .output()
            .await;

        let outcome = match &result {
            Ok(o) if o.status.success() => "success".to_string(),
            Ok(o) => {
                let stderr = String::from_utf8_lossy(&o.stderr);
                let truncated: String = stderr.chars().take(200).collect();
                format!("failed: {truncated}")
            }
            Err(e) => format!("error: {e}"),
        };

        app.log(&format!("#{issue_number}: {outcome}")).await;

        let entry = Entry {
            issue_number,
            issue_title: issue_title.to_string(),
            timestamp: chrono::Utc::now().to_rfc3339(),
            outcome,
            pid: None,
        };
        let mut s: tokio::sync::MutexGuard<'_, State> = app.state.lock().await;
        s.complete(entry);
        s.save(state_path).await;
    }
}
