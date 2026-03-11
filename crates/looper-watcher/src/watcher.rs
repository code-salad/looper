use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use tokio::task::JoinHandle;

use crate::log;

// ── Types ────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize)]
pub struct WatcherInfo {
    pub id: String,
    pub repo: String,
    pub interval_secs: u64,
    pub status: WatcherStatus,
    pub started_at: String,
    pub issues_processed: u64,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum WatcherStatus {
    Running,
    Stopped,
}

#[derive(Debug, Clone, Serialize)]
pub struct HistoryEntry {
    pub watcher_id: String,
    pub repo: String,
    pub issue_number: u64,
    pub issue_title: String,
    pub issue_url: String,
    pub timestamp: String,
    pub outcome: String,
}

#[derive(Debug, Deserialize)]
struct GhIssue {
    number: u64,
    title: String,
    labels: Vec<GhLabel>,
    body: Option<String>,
    #[serde(rename = "createdAt")]
    created_at: String,
}

#[derive(Debug, Deserialize)]
struct GhLabel {
    name: String,
}

// ── Shared state handle ──────────────────────────────────────────────────────

/// Shared state accessible from both the manager and watcher tasks.
/// Wrapped in Arc<tokio::sync::Mutex<_>> so watcher tasks can update it.
#[derive(Debug, Clone, Default)]
pub struct SharedState {
    pub history: Vec<HistoryEntry>,
    pub issues_processed: HashMap<String, u64>, // watcher_id -> count
}

type SharedStateHandle = std::sync::Arc<tokio::sync::Mutex<SharedState>>;

// ── Manager ──────────────────────────────────────────────────────────────────

struct ActiveWatcher {
    info: WatcherInfo,
    handle: JoinHandle<()>,
    cancel: tokio::sync::watch::Sender<bool>,
}

pub struct WatcherManager {
    watchers: HashMap<String, ActiveWatcher>,
    shared: SharedStateHandle,
}

impl WatcherManager {
    pub fn new() -> Self {
        Self {
            watchers: HashMap::new(),
            shared: std::sync::Arc::new(tokio::sync::Mutex::new(SharedState::default())),
        }
    }

    pub fn list_watchers(&self) -> Vec<WatcherInfo> {
        self.watchers
            .values()
            .map(|w| {
                let mut info = w.info.clone();
                // Update status based on whether the task is still running
                if w.handle.is_finished() {
                    info.status = WatcherStatus::Stopped;
                }
                info
            })
            .collect()
    }

    pub fn setup_watcher(&mut self, repo: String, interval_secs: u64) -> WatcherInfo {
        let id = uuid::Uuid::new_v4().to_string()[..8].to_string();
        let now = chrono::Utc::now().to_rfc3339();

        let info = WatcherInfo {
            id: id.clone(),
            repo: repo.clone(),
            interval_secs,
            status: WatcherStatus::Running,
            started_at: now,
            issues_processed: 0,
        };

        let (cancel_tx, cancel_rx) = tokio::sync::watch::channel(false);
        let shared = self.shared.clone();
        let watcher_id = id.clone();
        let watcher_repo = repo.clone();

        let handle = tokio::spawn(async move {
            watcher_loop(watcher_id, watcher_repo, interval_secs, cancel_rx, shared).await;
        });

        let active = ActiveWatcher {
            info: info.clone(),
            handle,
            cancel: cancel_tx,
        };

        self.watchers.insert(id, active);
        info
    }

    pub fn kill_all_watchers(&mut self) -> usize {
        let count = self.watchers.len();
        for (id, watcher) in self.watchers.drain() {
            log(&format!("Killing watcher {}", id));
            let _ = watcher.cancel.send(true);
            watcher.handle.abort();
        }
        count
    }

    pub fn get_history(&self, repo_filter: Option<&str>) -> Vec<HistoryEntry> {
        // We can't await here since this is called from a sync context within an async block,
        // but the caller already holds the manager lock. Use try_lock on shared state.
        let shared = self.shared.try_lock();
        match shared {
            Ok(state) => {
                let history = &state.history;
                match repo_filter {
                    Some(repo) => history.iter().filter(|e| e.repo == repo).cloned().collect(),
                    None => history.clone(),
                }
            }
            Err(_) => {
                // If we can't get the lock, return empty (shouldn't normally happen)
                vec![]
            }
        }
    }
}

// ── Watcher loop ─────────────────────────────────────────────────────────────

async fn watcher_loop(
    watcher_id: String,
    repo: String,
    interval_secs: u64,
    mut cancel_rx: tokio::sync::watch::Receiver<bool>,
    shared: SharedStateHandle,
) {
    log(&format!(
        "Watcher {} started for {} (interval: {}s)",
        watcher_id, repo, interval_secs
    ));

    loop {
        // Check for cancellation
        if *cancel_rx.borrow() {
            log(&format!("Watcher {} cancelled", watcher_id));
            break;
        }

        // Poll for issues
        match poll_and_process(&watcher_id, &repo, &shared).await {
            Ok(true) => {
                log(&format!("Watcher {} processed an issue", watcher_id));
            }
            Ok(false) => {
                log(&format!("Watcher {} found no eligible issues", watcher_id));
            }
            Err(e) => {
                log(&format!("Watcher {} error: {}", watcher_id, e));
            }
        }

        // Sleep with cancellation check
        tokio::select! {
            _ = tokio::time::sleep(tokio::time::Duration::from_secs(interval_secs)) => {}
            _ = cancel_rx.changed() => {
                log(&format!("Watcher {} cancelled during sleep", watcher_id));
                break;
            }
        }
    }
}

async fn poll_and_process(
    watcher_id: &str,
    repo: &str,
    shared: &SharedStateHandle,
) -> Result<bool, String> {
    // Fetch open unassigned issues
    let output = tokio::process::Command::new("gh")
        .args([
            "issue",
            "list",
            "--repo",
            repo,
            "--state",
            "open",
            "--search",
            "no:assignee",
            "--limit",
            "20",
            "--json",
            "number,title,labels,body,createdAt",
        ])
        .output()
        .await
        .map_err(|e| format!("Failed to run gh: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("gh issue list failed: {}", stderr));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let issues: Vec<GhIssue> =
        serde_json::from_str(&stdout).map_err(|e| format!("Failed to parse issues: {}", e))?;

    if issues.is_empty() {
        return Ok(false);
    }

    // Filter blocked issues
    let mut eligible: Vec<&GhIssue> = Vec::new();
    for issue in &issues {
        if is_blocked(issue, repo).await {
            continue;
        }
        eligible.push(issue);
    }

    if eligible.is_empty() {
        return Ok(false);
    }

    // Sort by created_at ascending (oldest first) — already sorted by gh, but be explicit
    eligible.sort_by(|a, b| a.created_at.cmp(&b.created_at));

    let issue = eligible[0];
    let issue_url = format!("https://github.com/{}/issues/{}", repo, issue.number);

    log(&format!(
        "Watcher {} claiming issue #{}: {}",
        watcher_id, issue.number, issue.title
    ));

    // Assign to current user
    let assign_output = tokio::process::Command::new("gh")
        .args([
            "issue",
            "edit",
            &issue.number.to_string(),
            "--repo",
            repo,
            "--add-assignee",
            "@me",
        ])
        .output()
        .await;

    match assign_output {
        Ok(o) if o.status.success() => {
            log(&format!("Assigned issue #{} to current user", issue.number));
        }
        Ok(o) => {
            let stderr = String::from_utf8_lossy(&o.stderr);
            log(&format!(
                "Warning: could not assign issue #{}: {}",
                issue.number, stderr
            ));
        }
        Err(e) => {
            log(&format!(
                "Warning: could not assign issue #{}: {}",
                issue.number, e
            ));
        }
    }

    // Feed to claude -p '/looper-ee <issue_url>'
    let prompt = format!("/looper-ee {}", issue_url);
    log(&format!("Running: claude -p '{}'", prompt));

    let claude_output = tokio::process::Command::new("claude")
        .args(["-p", &prompt, "--allowedTools", "Bash,Read,Write,Edit,Grep,Glob,Agent,Skill"])
        .output()
        .await;

    let outcome = match claude_output {
        Ok(o) if o.status.success() => "success".to_string(),
        Ok(o) => {
            let stderr = String::from_utf8_lossy(&o.stderr);
            format!("failed: {}", stderr.chars().take(200).collect::<String>())
        }
        Err(e) => format!("error: {}", e),
    };

    // Record history
    let entry = HistoryEntry {
        watcher_id: watcher_id.to_string(),
        repo: repo.to_string(),
        issue_number: issue.number,
        issue_title: issue.title.clone(),
        issue_url,
        timestamp: chrono::Utc::now().to_rfc3339(),
        outcome,
    };

    {
        let mut state = shared.lock().await;
        state.history.push(entry);
        *state.issues_processed.entry(watcher_id.to_string()).or_insert(0) += 1;
    }

    Ok(true)
}

async fn is_blocked(issue: &GhIssue, repo: &str) -> bool {
    // Label-based blocking
    for label in &issue.labels {
        let name_lower = label.name.to_lowercase();
        if name_lower.contains("blocked") || name_lower.contains("dependencies") {
            return true;
        }
    }

    let body = match &issue.body {
        Some(b) => b,
        None => return false,
    };

    // Task-list dependency references: "- [ ] Depends on #N" or "- [ ] #N"
    // Blocked by references: "Blocked by #N"
    let re_patterns = [
        r"- \[ \] Depends on #(\d+)",
        r"- \[ \] #(\d+)",
        r"(?i)Blocked by #(\d+)",
    ];

    for pattern in &re_patterns {
        // Simple regex-free extraction: find #N patterns in relevant lines
        for line in body.lines() {
            let matches = match *pattern {
                r"- \[ \] Depends on #(\d+)" => {
                    line.contains("- [ ] Depends on #") || line.contains("- [ ] depends on #")
                }
                r"- \[ \] #(\d+)" => line.starts_with("- [ ] #"),
                _ => line.to_lowercase().contains("blocked by #"),
            };

            if matches {
                // Extract issue numbers from this line
                let numbers = extract_issue_numbers(line);
                for num in numbers {
                    if is_issue_open(num, repo).await {
                        return true;
                    }
                }
            }
        }
    }

    false
}

fn extract_issue_numbers(line: &str) -> Vec<u64> {
    let mut numbers = Vec::new();
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '#' {
            let mut num_str = String::new();
            while let Some(&d) = chars.peek() {
                if d.is_ascii_digit() {
                    num_str.push(d);
                    chars.next();
                } else {
                    break;
                }
            }
            if let Ok(n) = num_str.parse::<u64>() {
                numbers.push(n);
            }
        }
    }
    numbers
}

async fn is_issue_open(number: u64, repo: &str) -> bool {
    let output = tokio::process::Command::new("gh")
        .args([
            "issue",
            "view",
            &number.to_string(),
            "--repo",
            repo,
            "--json",
            "state",
            "--jq",
            ".state",
        ])
        .output()
        .await;

    match output {
        Ok(o) if o.status.success() => {
            let state = String::from_utf8_lossy(&o.stdout).trim().to_string();
            state == "OPEN"
        }
        _ => false, // If we can't check, assume not blocking
    }
}
