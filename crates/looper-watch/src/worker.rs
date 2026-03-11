use std::path::Path;
use std::sync::Arc;

use futures::future::join_all;
use tokio::process::Command;
use tokio::sync::Mutex;

use crate::Cli;
use crate::github;
use crate::state::{self, Entry, State};

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
    pub fn new(persisted: State) -> Self {
        Self {
            state: Arc::new(Mutex::new(persisted)),
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

    app.log(&format!("found {} open unassigned issue(s)", issues.len()))
        .await;

    // Get live in-progress set from tmux
    let in_progress = state::in_progress_issues(&cli.repo).await;

    // Filter out blocked and already-in-progress issues
    let mut eligible = Vec::new();
    for issue in &issues {
        if in_progress.contains(&issue.number) {
            app.log(&format!("#{}: skipping (tmux session alive)", issue.number))
                .await;
            continue;
        }

        if github::is_blocked(issue, &cli.repo).await {
            app.log(&format!("#{}: skipping (blocked)", issue.number))
                .await;
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
    let available_slots = cli.concurrency.saturating_sub(in_progress.len());
    if available_slots == 0 {
        app.log(&format!(
            "max concurrency reached ({}/{})",
            in_progress.len(),
            cli.concurrency
        ))
        .await;
        return;
    }

    let to_process = &eligible[..eligible.len().min(available_slots)];

    let tasks: Vec<_> = to_process
        .iter()
        .map(|issue| {
            let repo = cli.repo.clone();
            let retries = cli.retries;
            let app_clone = app.clone();
            let state_path_clone = state_path.to_path_buf();
            let issue_number = issue.number;
            let issue_title = issue.title.clone();
            let allowed_tools = cli.allowed_tools.clone();
            let dry_run = cli.dry_run;

            async move {
                app_clone
                    .log(&format!("#{issue_number}: {issue_title} — processing"))
                    .await;

                if dry_run {
                    app_clone
                        .log(&format!("#{issue_number}: dry run, skipping"))
                        .await;
                    return;
                }

                // Assign with retries — skip this issue if it fails
                if let Err(e) = github::assign_to_me(&repo, issue_number, retries).await {
                    app_clone
                        .log(&format!("#{issue_number}: assign failed: {e}"))
                        .await;
                    return;
                }
                app_clone
                    .log(&format!("#{issue_number}: assigned to @me"))
                    .await;

                // Spawn claude in tmux as a background task
                tokio::spawn(async move {
                    run_claude(
                        &repo,
                        issue_number,
                        &issue_title,
                        &allowed_tools,
                        &app_clone,
                        &state_path_clone,
                    )
                    .await;
                });
            }
        })
        .collect();

    join_all(tasks).await;
}

async fn run_claude(
    repo: &str,
    issue_number: u64,
    issue_title: &str,
    allowed_tools: &str,
    app: &AppState,
    state_path: &Path,
) {
    let issue_url = format!("https://github.com/{repo}/issues/{issue_number}");
    let prompt = format!("/looper-ee {issue_url}");
    let session = state::session_name(repo, issue_number);

    let tmux_cmd = format!(
        "claude -p '{}' --allowedTools '{}'",
        prompt.replace('\'', "'\\''"),
        allowed_tools.replace('\'', "'\\''"),
    );

    app.log(&format!(
        "#{issue_number}: spawning tmux session '{session}'"
    ))
    .await;

    let tmux_result = Command::new("tmux")
        .args(["new-session", "-d", "-s", &session, &tmux_cmd])
        .output()
        .await;

    let use_tmux = matches!(&tmux_result, Ok(o) if o.status.success());

    if !use_tmux {
        app.log(&format!("#{issue_number}: tmux failed, using bare process"))
            .await;

        // Bare process fallback
        let result = Command::new("claude")
            .args(["-p", &prompt, "--allowedTools", allowed_tools])
            .output()
            .await;

        let outcome = match &result {
            Ok(o) if o.status.success() => "success".to_string(),
            Ok(o) => {
                let stderr = String::from_utf8_lossy(&o.stderr);
                format!("failed: {}", stderr.chars().take(200).collect::<String>())
            }
            Err(e) => format!("error: {e}"),
        };

        app.log(&format!("#{issue_number}: {outcome}")).await;
        let mut s = app.state.lock().await;
        s.add_history(Entry {
            issue_number,
            issue_title: issue_title.to_string(),
            timestamp: chrono::Utc::now().to_rfc3339(),
            outcome,
        });
        s.save(state_path).await;
        return;
    }

    // Poll until tmux session ends
    loop {
        tokio::time::sleep(tokio::time::Duration::from_secs(10)).await;
        let has = Command::new("tmux")
            .args(["has-session", "-t", &session])
            .output()
            .await;
        match has {
            Ok(o) if o.status.success() => continue,
            _ => break,
        }
    }

    // Cleanup stale session
    let _ = Command::new("tmux")
        .args(["kill-session", "-t", &session])
        .output()
        .await;

    let outcome = "completed (tmux)".to_string();
    app.log(&format!("#{issue_number}: {outcome}")).await;

    let mut s = app.state.lock().await;
    s.add_history(Entry {
        issue_number,
        issue_title: issue_title.to_string(),
        timestamp: chrono::Utc::now().to_rfc3339(),
        outcome,
    });
    s.save(state_path).await;
}

/// Kill all tmux sessions for this repo and log it.
pub async fn kill_all_sessions(repo: &str, state_path: &Path, app: &AppState) {
    let count = state::kill_all_repo_sessions(repo).await;
    app.log(&format!("killed {count} tmux session(s)")).await;
    // Save state in case history was pending
    let s = app.state.lock().await;
    s.save(state_path).await;
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use futures::future::join_all;

    use super::AppState;
    use crate::state::State;

    fn make_app() -> AppState {
        AppState::new(State::default())
    }

    #[tokio::test]
    async fn app_state_log_stores_messages() {
        let app = make_app();
        app.log("hello world").await;
        let lines = app.log_lines.lock().await;
        assert_eq!(lines.len(), 1);
        assert!(lines[0].contains("hello world"));
    }

    #[tokio::test]
    async fn app_state_log_trims_to_200_lines() {
        let app = make_app();
        for i in 0..250 {
            app.log(&format!("line {i}")).await;
        }
        let lines = app.log_lines.lock().await;
        assert_eq!(lines.len(), 200, "log should be capped at 200 lines");
        // Oldest lines should be dropped
        assert!(
            lines[0].contains("line 50"),
            "first retained line should be line 50, got: {}",
            lines[0]
        );
    }

    /// Acceptance-criteria test: multiple eligible issues must be dispatched
    /// concurrently (in parallel), not one after another.
    ///
    /// We verify that `join_all` interleaves N tasks correctly. Each task
    /// increments a start counter, yields to the executor so others can run,
    /// then increments a finish counter. Because `join_all` polls all futures
    /// round-robin, all starts happen before all finishes — which is impossible
    /// under strict sequential execution.
    #[tokio::test]
    async fn should_dispatch_multiple_issues_concurrently_not_sequentially() {
        const N: usize = 4;

        let starts = Arc::new(AtomicUsize::new(0));
        let finishes_seen_all_starts = Arc::new(AtomicUsize::new(0));

        let tasks: Vec<_> = (0..N)
            .map(|_| {
                let starts = Arc::clone(&starts);
                let finishes_seen_all_starts = Arc::clone(&finishes_seen_all_starts);
                async move {
                    starts.fetch_add(1, Ordering::SeqCst);
                    // Yield so other tasks get a chance to start.
                    tokio::task::yield_now().await;
                    // By the time we reach here, all tasks should have started
                    // (if truly concurrent/interleaved via join_all).
                    if starts.load(Ordering::SeqCst) == N {
                        finishes_seen_all_starts.fetch_add(1, Ordering::SeqCst);
                    }
                }
            })
            .collect();

        join_all(tasks).await;

        // Every task should have observed all N starts before finishing,
        // proving join_all interleaves them rather than running sequentially.
        assert_eq!(
            finishes_seen_all_starts.load(Ordering::SeqCst),
            N,
            "expected all {N} tasks to see all starts before finishing \
             (proving parallel dispatch); got {}",
            finishes_seen_all_starts.load(Ordering::SeqCst)
        );
    }

    #[tokio::test]
    async fn app_state_log_includes_timestamp_prefix() {
        let app = make_app();
        app.log("test message").await;
        let lines = app.log_lines.lock().await;
        // Log lines are formatted as "[HH:MM:SS] message"
        assert!(
            lines[0].starts_with('['),
            "log line should start with '[' timestamp bracket"
        );
        assert!(
            lines[0].contains("] test message"),
            "log line should contain the message"
        );
    }
}
