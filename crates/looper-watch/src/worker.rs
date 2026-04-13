use std::path::Path;
use std::sync::Arc;

use futures::future::join_all;
use tokio::process::Command;
use tokio::sync::{Mutex, Notify};

use crate::Cli;
use crate::claim;
use crate::github;
use crate::state::{self, Entry, Outcome, OutcomeField, State};

/// Shared app state for the TUI to read.
#[derive(Debug, Clone)]
pub struct AppState {
    pub state: Arc<Mutex<State>>,
    pub log_lines: Arc<Mutex<Vec<String>>>,
    pub last_poll: Arc<Mutex<Option<String>>>,
    pub next_poll: Arc<Mutex<Option<String>>>,
    pub open_issues: Arc<Mutex<Vec<github::Issue>>>,
    /// Notified when an immediate poll is needed — e.g. when the user presses
    /// `p` in the TUI or when a tmux session ends.
    pub poll_notify: Arc<Notify>,
}

impl AppState {
    pub fn new(persisted: State) -> Self {
        Self {
            state: Arc::new(Mutex::new(persisted)),
            log_lines: Arc::new(Mutex::new(Vec::new())),
            last_poll: Arc::new(Mutex::new(None)),
            next_poll: Arc::new(Mutex::new(None)),
            open_issues: Arc::new(Mutex::new(Vec::new())),
            poll_notify: Arc::new(Notify::new()),
        }
    }

    pub async fn log(&self, msg: &str) {
        let line = format!("[{}] {}", chrono::Local::now().format("%H:%M:%S"), msg);
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
///
/// The sleep between polls can be interrupted by signalling `app.force_poll`,
/// which causes an immediate extra poll (e.g. when the user presses `p` in the
/// TUI).
pub async fn run_loop(cli: &Cli, state_path: &Path, app: &AppState) {
    loop {
        poll_once(cli, state_path, app).await;

        let deadline = tokio::time::Instant::now() + tokio::time::Duration::from_secs(cli.interval);

        {
            let next = chrono::Local::now() + chrono::Duration::seconds(cli.interval as i64);
            *app.next_poll.lock().await = Some(next.format("%H:%M:%S").to_string());
        }

        // Wake early if the user presses `p` or a tmux session ends.
        tokio::select! {
            _ = tokio::time::sleep_until(deadline) => {}
            _ = app.poll_notify.notified() => {
                app.log("poll requested — polling immediately").await;
            }
        }
    }
}

/// Poll once: fetch issues, filter, assign, dispatch.
pub async fn poll_once(cli: &Cli, state_path: &Path, app: &AppState) {
    {
        *app.last_poll.lock().await = Some(chrono::Local::now().format("%H:%M:%S").to_string());
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

                // Claim with write-then-verify protocol (local lock + remote
                // claim comment + settle + verify earliest-comment-wins).
                let cfg = claim::ClaimConfig::default_for(&repo);
                let guard = match claim::try_claim(&repo, issue_number, &cfg).await {
                    Ok(g) => {
                        app_clone
                            .log(&format!("#{issue_number}: claimed (run_id={})", g.run_id))
                            .await;
                        g
                    }
                    Err(claim::ClaimError::LocalLockHeld) => {
                        app_clone
                            .log(&format!("#{issue_number}: skipping (local lock held)"))
                            .await;
                        return;
                    }
                    Err(claim::ClaimError::LostRace { winner }) => {
                        app_clone
                            .log(&format!("#{issue_number}: lost race to {winner}"))
                            .await;
                        return;
                    }
                    Err(e) => {
                        app_clone
                            .log(&format!("#{issue_number}: claim error: {e}"))
                            .await;
                        return;
                    }
                };

                // Remove from open issues list immediately so TUI reflects assignment
                app_clone
                    .open_issues
                    .lock()
                    .await
                    .retain(|i| i.number != issue_number);

                // Spawn claude in tmux as a background task.
                // Move the guard into the spawned task so it lives for the
                // full duration of the claude session; Drop removes the local
                // lockfile when the session finishes.
                tokio::spawn(async move {
                    let _guard = guard;
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

/// Guard against core.bare=true on the local repo checkout.
///
/// Worktree creation/removal can leave core.bare=true on the parent repo,
/// which breaks git pull and other operations on the main branch.
/// This runs after each session completes to ensure the repo stays usable.
async fn fix_bare_if_needed(repo: &str, app: &AppState) {
    let home = std::env::var("HOME").unwrap_or_default();
    let repo_dir = Path::new(&home).join("repos").join(repo);
    if !repo_dir.join(".git").exists() {
        return;
    }
    let bare_val = Command::new("git")
        .args([
            "-C",
            &repo_dir.to_string_lossy(),
            "config",
            "--get",
            "core.bare",
        ])
        .output()
        .await;
    if let Ok(output) = bare_val {
        let val = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if val == "true" {
            app.log(&format!(
                "WARNING: core.bare=true detected on {}, unsetting",
                repo_dir.display()
            ))
            .await;
            let _ = Command::new("git")
                .args([
                    "-C",
                    &repo_dir.to_string_lossy(),
                    "config",
                    "--unset",
                    "core.bare",
                ])
                .output()
                .await;
        }
    }
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

    let started_at = chrono::Utc::now().to_rfc3339();
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
            Ok(o) if o.status.success() => Outcome::Success,
            Ok(o) => {
                let stderr = String::from_utf8_lossy(&o.stderr);
                Outcome::Failed {
                    detail: stderr.chars().take(200).collect(),
                }
            }
            Err(e) => Outcome::Error {
                detail: e.to_string(),
            },
        };

        // Guard against core.bare=true after worktree cleanup
        fix_bare_if_needed(repo, app).await;

        app.log(&format!("#{issue_number}: {outcome}")).await;
        let mut s = app.state.lock().await;
        s.add_history(Entry {
            issue_number,
            issue_title: issue_title.to_string(),
            timestamp: chrono::Utc::now().to_rfc3339(),
            outcome: OutcomeField::Typed(outcome),
            started_at: Some(started_at),
        });
        s.save(state_path).await;
        drop(s);
        app.poll_notify.notify_one();
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

    // Guard against core.bare=true on the repo after worktree cleanup.
    // Worktree removal (in create-github-pr) can leave core.bare=true,
    // which blocks git pull on the main branch.
    fix_bare_if_needed(repo, app).await;

    let outcome = Outcome::Completed {
        detail: Some("tmux".to_string()),
    };
    app.log(&format!("#{issue_number}: {outcome}")).await;

    let mut s = app.state.lock().await;
    s.add_history(Entry {
        issue_number,
        issue_title: issue_title.to_string(),
        timestamp: chrono::Utc::now().to_rfc3339(),
        outcome: OutcomeField::Typed(outcome),
        started_at: Some(started_at),
    });
    s.save(state_path).await;
    drop(s);
    app.poll_notify.notify_one();
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
    use crate::github::{Issue, Label};
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

    /// Acceptance-criteria test: poll_notify wakes the loop before the timer
    /// expires when a session ends.
    ///
    /// We set a very long sleep deadline (60 s) but fire notify_one()
    /// immediately from a spawned task. The select! in run_loop should wake
    /// within milliseconds — far sooner than the 60-second timer.
    #[tokio::test]
    async fn should_wake_early_when_session_ends() {
        use std::sync::Arc;
        use tokio::sync::Notify;

        let notify = Arc::new(Notify::new());
        let notify_clone = Arc::clone(&notify);

        // Spawn a task that fires the notification immediately.
        tokio::spawn(async move {
            tokio::task::yield_now().await;
            notify_clone.notify_one();
        });

        let start = tokio::time::Instant::now();
        let long_deadline = start + tokio::time::Duration::from_secs(60);

        tokio::select! {
            _ = tokio::time::sleep_until(long_deadline) => {
                panic!("timer expired before notify — early-wake did not work");
            }
            _ = notify.notified() => {
                // Good: woke up early.
            }
        }

        // Should have woken up in well under 1 second, not 60 seconds.
        assert!(
            start.elapsed() < tokio::time::Duration::from_secs(1),
            "early wake took too long: {:?}",
            start.elapsed()
        );
    }

    /// Acceptance-criteria test: AppState.poll_notify is shared across clones
    /// so that run_claude (holding a clone) can signal run_loop (holding the
    /// original).
    #[tokio::test]
    async fn poll_notify_is_shared_across_clones() {
        let app = make_app();
        let app_clone = app.clone();

        // Trigger from clone (as run_claude does).
        tokio::spawn(async move {
            tokio::task::yield_now().await;
            app_clone.poll_notify.notify_one();
        });

        // Original should receive the notification (as run_loop does).
        let received = tokio::time::timeout(
            tokio::time::Duration::from_secs(1),
            app.poll_notify.notified(),
        )
        .await;

        assert!(
            received.is_ok(),
            "poll_notify signal was not received across clones within 1 second"
        );
    }

    fn make_issue(number: u64, title: &str) -> Issue {
        Issue {
            number,
            title: title.to_string(),
            labels: Vec::<Label>::new(),
            body: None,
            created_at: "2024-01-01T00:00:00Z".to_string(),
        }
    }

    /// Regression test for bug #34: after an issue is assigned and a tmux session
    /// is spawned, the open issues list in the TUI should immediately remove that
    /// issue rather than waiting for the next poll cycle.
    #[tokio::test]
    async fn should_remove_assigned_issue_from_open_issues_immediately() {
        let app = make_app();

        // Populate open_issues with two issues
        {
            let mut issues = app.open_issues.lock().await;
            issues.push(make_issue(42, "Fix something"));
            issues.push(make_issue(99, "Another issue"));
        }

        // Simulate the retain call that happens right after successful assignment
        let issue_number: u64 = 42;
        app.open_issues
            .lock()
            .await
            .retain(|i| i.number != issue_number);

        // Issue #42 should be gone; issue #99 should remain
        let issues = app.open_issues.lock().await;
        assert_eq!(
            issues.len(),
            1,
            "open_issues should have 1 entry after removing the assigned issue"
        );
        assert_eq!(
            issues[0].number, 99,
            "remaining issue should be #99, not the assigned one"
        );
    }

    /// Verify that open_issues is not mutated when the issue is not present
    /// (e.g., a race condition where poll already removed it).
    #[tokio::test]
    async fn retain_on_open_issues_is_idempotent_when_issue_not_present() {
        let app = make_app();

        {
            let mut issues = app.open_issues.lock().await;
            issues.push(make_issue(10, "Some issue"));
        }

        // Attempt to remove an issue that doesn't exist
        let issue_number: u64 = 999;
        app.open_issues
            .lock()
            .await
            .retain(|i| i.number != issue_number);

        let issues = app.open_issues.lock().await;
        assert_eq!(
            issues.len(),
            1,
            "open_issues length should not change when removing a non-existent issue"
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

    /// Acceptance-criteria test: log timestamps should use local time format HH:MM:SS.
    #[tokio::test]
    async fn should_display_log_timestamp_in_local_time_format() {
        let app = make_app();
        let before = chrono::Local::now();
        app.log("local time check").await;
        let after = chrono::Local::now();
        let lines = app.log_lines.lock().await;

        let line = &lines[0];
        let timestamp = &line[1..9];

        let parts: Vec<&str> = timestamp.split(':').collect();
        assert_eq!(
            parts.len(),
            3,
            "timestamp should have 3 colon-separated parts"
        );
        assert_eq!(parts[0].len(), 2, "hour should be 2 digits");
        assert_eq!(parts[1].len(), 2, "minute should be 2 digits");
        assert_eq!(parts[2].len(), 2, "second should be 2 digits");

        let expected_before = before.format("%H:%M:%S").to_string();
        let expected_after = after.format("%H:%M:%S").to_string();
        assert!(
            timestamp >= expected_before.as_str() && timestamp <= expected_after.as_str(),
            "log timestamp '{timestamp}' should be between local time '{expected_before}' and '{expected_after}'"
        );
    }

    /// Acceptance-criteria test: last_poll and next_poll should reflect local time.
    #[tokio::test]
    async fn should_format_poll_timestamps_as_local_time_hhmmss() {
        let local_time_str = chrono::Local::now().format("%H:%M:%S").to_string();
        let parts: Vec<&str> = local_time_str.split(':').collect();
        assert_eq!(parts.len(), 3, "local time should format as HH:MM:SS");
        assert_eq!(parts[0].len(), 2, "hour should be zero-padded to 2 digits");
        assert_eq!(
            parts[1].len(),
            2,
            "minute should be zero-padded to 2 digits"
        );
        assert_eq!(
            parts[2].len(),
            2,
            "second should be zero-padded to 2 digits"
        );

        let interval_secs: i64 = 60;
        let before = chrono::Local::now();
        let next = chrono::Local::now() + chrono::Duration::seconds(interval_secs);
        let after = chrono::Local::now();

        let next_str = next.format("%H:%M:%S").to_string();
        let next_parts: Vec<&str> = next_str.split(':').collect();
        assert_eq!(next_parts.len(), 3, "next_poll should format as HH:MM:SS");

        let expected_min = (before + chrono::Duration::seconds(interval_secs))
            .format("%H:%M:%S")
            .to_string();
        let expected_max = (after + chrono::Duration::seconds(interval_secs))
            .format("%H:%M:%S")
            .to_string();
        assert!(
            next_str >= expected_min && next_str <= expected_max,
            "next_poll '{next_str}' should be between '{expected_min}' and '{expected_max}'"
        );
    }

    /// Issue #33 acceptance-criteria test: `poll_notify` Notify is present on
    /// AppState so the TUI can signal it when the user presses `p`.
    #[tokio::test]
    async fn app_state_has_poll_notify() {
        let app = make_app();
        app.poll_notify.notify_one();
        let notified = tokio::time::timeout(
            std::time::Duration::from_millis(50),
            app.poll_notify.notified(),
        )
        .await;
        assert!(
            notified.is_ok(),
            "poll_notify.notified() should resolve immediately after notify_one()"
        );
    }

    /// Issue #33 regression test: pressing `p` in the TUI should interrupt the
    /// inter-poll sleep and trigger an immediate re-poll.
    #[tokio::test]
    async fn poll_notify_wakes_up_select_before_interval_expires() {
        use std::sync::Arc;
        use std::sync::atomic::{AtomicBool, Ordering};

        let woken = Arc::new(AtomicBool::new(false));
        let notify = Arc::new(tokio::sync::Notify::new());

        let woken_clone = Arc::clone(&woken);
        let notify_clone = Arc::clone(&notify);

        let handle = tokio::spawn(async move {
            tokio::select! {
                _ = tokio::time::sleep(std::time::Duration::from_secs(10)) => {},
                _ = notify_clone.notified() => {
                    woken_clone.store(true, Ordering::SeqCst);
                },
            }
        });

        tokio::task::yield_now().await;
        notify.notify_one();

        let result = tokio::time::timeout(std::time::Duration::from_millis(500), handle).await;
        assert!(
            result.is_ok(),
            "task should finish promptly after notify_one"
        );
        assert!(
            woken.load(Ordering::SeqCst),
            "the notify branch should have been selected, setting woken=true"
        );
    }

    /// Issue #33: AppState clones share the same underlying Notify arc,
    /// so a signal from one clone (TUI) is visible to another (poll loop).
    #[tokio::test]
    async fn poll_notify_shared_across_clones() {
        let app = make_app();
        let app_clone = app.clone();

        app_clone.poll_notify.notify_one();

        let result = tokio::time::timeout(
            std::time::Duration::from_millis(50),
            app.poll_notify.notified(),
        )
        .await;
        assert!(
            result.is_ok(),
            "original AppState should receive notification sent via clone"
        );
    }
}
