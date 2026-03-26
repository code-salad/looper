use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::path::Path;
use tokio::process::Command;

/// Maximum number of history entries to retain. Older entries are pruned on save.
const MAX_HISTORY: usize = 500;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum Outcome {
    Success,
    Completed { detail: Option<String> },
    Failed { detail: String },
    Error { detail: String },
}

impl Outcome {
    /// Returns `true` for outcomes that represent successful completion.
    pub fn is_done(&self) -> bool {
        matches!(self, Outcome::Success | Outcome::Completed { .. })
    }
}

impl std::fmt::Display for Outcome {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Outcome::Success => write!(f, "success"),
            Outcome::Completed { detail: Some(d) } => write!(f, "completed ({d})"),
            Outcome::Completed { detail: None } => write!(f, "completed"),
            Outcome::Failed { detail } => write!(f, "failed: {detail}"),
            Outcome::Error { detail } => write!(f, "error: {detail}"),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Entry {
    pub issue_number: u64,
    pub issue_title: String,
    pub timestamp: String,
    /// Outcome of the run. Legacy JSON with a plain string is migrated on load.
    #[serde(flatten)]
    pub outcome: OutcomeField,
    #[serde(default)]
    pub started_at: Option<String>,
}

/// Wrapper that deserializes both the new tagged `Outcome` and legacy plain strings.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum OutcomeField {
    Typed(Outcome),
    /// Legacy: plain `"outcome": "success"` strings from older state files.
    Legacy {
        outcome: String,
    },
}

impl OutcomeField {
    pub fn as_outcome(&self) -> Outcome {
        match self {
            OutcomeField::Typed(o) => o.clone(),
            OutcomeField::Legacy { outcome } => {
                if outcome.starts_with("success") {
                    Outcome::Success
                } else if outcome.starts_with("completed") {
                    let detail = outcome
                        .strip_prefix("completed")
                        .map(|s| {
                            s.trim()
                                .trim_start_matches('(')
                                .trim_end_matches(')')
                                .to_string()
                        })
                        .filter(|s| !s.is_empty());
                    Outcome::Completed { detail }
                } else if outcome.starts_with("failed") {
                    Outcome::Failed {
                        detail: outcome
                            .strip_prefix("failed:")
                            .unwrap_or(outcome)
                            .trim()
                            .to_string(),
                    }
                } else {
                    Outcome::Error {
                        detail: outcome
                            .strip_prefix("error:")
                            .unwrap_or(outcome)
                            .trim()
                            .to_string(),
                    }
                }
            }
        }
    }

    pub fn is_done(&self) -> bool {
        self.as_outcome().is_done()
    }
}

/// Persisted state — history only. Live in-progress state comes from tmux.
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct State {
    pub history: Vec<Entry>,
}

impl State {
    pub async fn load(path: &Path) -> Self {
        match tokio::fs::read_to_string(path).await {
            Ok(data) => match serde_json::from_str(&data) {
                Ok(state) => state,
                Err(e) => {
                    eprintln!(
                        "  warn: corrupt state file {}: {e} — starting with empty state",
                        path.display()
                    );
                    // Backup the corrupt file so the operator can inspect it
                    let backup = path.with_extension("json.bak");
                    if let Err(be) = tokio::fs::copy(path, &backup).await {
                        eprintln!("  warn: failed to backup corrupt state: {be}");
                    }
                    Self::default()
                }
            },
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Self::default(),
            Err(e) => {
                eprintln!("  warn: failed to read state file {}: {e}", path.display());
                Self::default()
            }
        }
    }

    /// Atomic save: write to a temp file then rename into place.
    pub async fn save(&self, path: &Path) {
        let data = match serde_json::to_string_pretty(self) {
            Ok(d) => d,
            Err(e) => {
                eprintln!("  warn: failed to serialize state: {e}");
                return;
            }
        };

        let tmp = path.with_extension("json.tmp");
        if let Err(e) = tokio::fs::write(&tmp, &data).await {
            eprintln!("  warn: failed to write temp state file: {e}");
            return;
        }
        if let Err(e) = tokio::fs::rename(&tmp, path).await {
            eprintln!("  warn: failed to rename state file into place: {e}");
            // Clean up the temp file on failure
            let _ = tokio::fs::remove_file(&tmp).await;
        }
    }

    pub fn add_history(&mut self, entry: Entry) {
        self.history.push(entry);
        // Prune oldest entries if history exceeds the cap
        if self.history.len() > MAX_HISTORY {
            let excess = self.history.len() - MAX_HISTORY;
            self.history.drain(..excess);
        }
    }
}

/// Tmux session namespace: `looper-<sanitized_repo>-<issue_number>`
pub fn session_name(repo: &str, issue_number: u64) -> String {
    let sanitized = repo.replace('/', "-");
    format!("looper-{sanitized}-{issue_number}")
}

/// Prefix for all sessions belonging to a repo.
fn session_prefix(repo: &str) -> String {
    let sanitized = repo.replace('/', "-");
    format!("looper-{sanitized}-")
}

/// Parse issue number from a session name.
pub fn issue_from_session(repo: &str, session: &str) -> Option<u64> {
    session.strip_prefix(&session_prefix(repo))?.parse().ok()
}

/// Get the set of in-progress issue numbers by listing live tmux sessions.
pub async fn in_progress_issues(repo: &str) -> HashSet<u64> {
    let sessions = list_repo_sessions(repo).await;
    sessions
        .iter()
        .filter_map(|s| issue_from_session(repo, s))
        .collect()
}

/// List all tmux sessions for this repo.
pub async fn list_repo_sessions(repo: &str) -> Vec<String> {
    let prefix = session_prefix(repo);
    let output = Command::new("tmux")
        .args(["list-sessions", "-F", "#{session_name}"])
        .output()
        .await;

    match output {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout)
            .lines()
            .filter(|l| l.starts_with(&prefix))
            .map(|l| l.to_string())
            .collect(),
        _ => vec![],
    }
}

/// List all tmux sessions for this repo, paired with their Unix creation timestamps.
pub async fn list_repo_sessions_with_age(repo: &str) -> Vec<(String, Option<i64>)> {
    let prefix = session_prefix(repo);
    let output = Command::new("tmux")
        .args(["list-sessions", "-F", "#{session_name}:#{session_created}"])
        .output()
        .await;

    match output {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout)
            .lines()
            .filter(|l| l.starts_with(&prefix))
            .map(|l| {
                if let Some((name, ts)) = l.split_once(':') {
                    let created = ts.trim().parse::<i64>().ok();
                    (name.to_string(), created)
                } else {
                    (l.to_string(), None)
                }
            })
            .collect(),
        _ => vec![],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_entry(issue_number: u64, outcome: Outcome) -> Entry {
        Entry {
            issue_number,
            issue_title: format!("Issue #{issue_number}"),
            timestamp: "2024-01-01T00:00:00Z".to_string(),
            outcome: OutcomeField::Typed(outcome),
            started_at: None,
        }
    }

    // ── Legacy JSON backward compatibility ───────────────────────────

    #[test]
    fn entry_deserializes_legacy_outcome_string() {
        let json = r#"{
            "issue_number": 42,
            "issue_title": "Fix the bug",
            "timestamp": "2024-01-01T00:00:00Z",
            "outcome": "completed (tmux)"
        }"#;
        let entry: Entry = serde_json::from_str(json).expect("should deserialize legacy format");
        assert_eq!(entry.issue_number, 42);
        assert_eq!(entry.started_at, None);
        assert!(entry.outcome.is_done(), "completed should be done");
        assert_eq!(
            entry.outcome.as_outcome(),
            Outcome::Completed {
                detail: Some("tmux".to_string())
            }
        );
    }

    #[test]
    fn entry_deserializes_legacy_success_string() {
        let json = r#"{
            "issue_number": 7,
            "issue_title": "New feature",
            "timestamp": "2024-06-15T12:00:00Z",
            "outcome": "success",
            "started_at": "2024-06-15T11:50:00Z"
        }"#;
        let entry: Entry = serde_json::from_str(json).expect("should deserialize");
        assert_eq!(entry.started_at, Some("2024-06-15T11:50:00Z".to_string()));
        assert!(entry.outcome.is_done());
    }

    #[test]
    fn entry_deserializes_legacy_failed_string() {
        let json = r#"{
            "issue_number": 3,
            "issue_title": "Broken",
            "timestamp": "2024-01-01T00:00:00Z",
            "outcome": "failed: some error"
        }"#;
        let entry: Entry = serde_json::from_str(json).unwrap();
        assert!(!entry.outcome.is_done());
        assert_eq!(
            entry.outcome.as_outcome(),
            Outcome::Failed {
                detail: "some error".to_string()
            }
        );
    }

    #[test]
    fn entry_serializes_new_typed_outcome() {
        let entry = make_entry(1, Outcome::Success);
        let json = serde_json::to_string(&entry).unwrap();
        assert!(json.contains("\"status\":\"success\""), "json: {json}");
    }

    // ── Outcome enum ─────────────────────────────────────────────────

    #[test]
    fn outcome_is_done_for_success_and_completed() {
        assert!(Outcome::Success.is_done());
        assert!(Outcome::Completed { detail: None }.is_done());
        assert!(
            Outcome::Completed {
                detail: Some("tmux".into())
            }
            .is_done()
        );
        assert!(
            !Outcome::Failed {
                detail: "err".into()
            }
            .is_done()
        );
        assert!(
            !Outcome::Error {
                detail: "err".into()
            }
            .is_done()
        );
    }

    #[test]
    fn outcome_display_formats_correctly() {
        assert_eq!(Outcome::Success.to_string(), "success");
        assert_eq!(
            Outcome::Completed {
                detail: Some("tmux".into())
            }
            .to_string(),
            "completed (tmux)"
        );
        assert_eq!(Outcome::Completed { detail: None }.to_string(), "completed");
        assert_eq!(
            Outcome::Failed {
                detail: "oops".into()
            }
            .to_string(),
            "failed: oops"
        );
    }

    // ── Session naming ───────────────────────────────────────────────

    #[test]
    fn session_name_uses_repo_with_slash_sanitized() {
        assert_eq!(session_name("owner/repo", 42), "looper-owner-repo-42");
    }

    #[test]
    fn issue_from_session_parses_correctly() {
        assert_eq!(
            issue_from_session("owner/repo", "looper-owner-repo-42"),
            Some(42)
        );
    }

    #[test]
    fn issue_from_session_returns_none_for_different_repo() {
        assert_eq!(
            issue_from_session("owner/repo", "looper-other-repo-42"),
            None
        );
    }

    #[test]
    fn session_name_sanitizes_slash_in_repo() {
        assert_eq!(session_name("my-org/my-repo", 1), "looper-my-org-my-repo-1");
    }

    #[test]
    fn issue_from_session_returns_none_for_non_numeric_suffix() {
        assert_eq!(
            issue_from_session("owner/repo", "looper-owner-repo-abc"),
            None
        );
    }

    #[test]
    fn issue_from_session_returns_none_for_empty_session() {
        assert_eq!(issue_from_session("owner/repo", ""), None);
    }

    // ── State operations ─────────────────────────────────────────────

    #[test]
    fn state_add_history_accumulates_entries() {
        let mut state = State::default();
        assert!(state.history.is_empty());

        state.add_history(make_entry(1, Outcome::Success));
        state.add_history(make_entry(
            2,
            Outcome::Failed {
                detail: "err".into(),
            },
        ));

        assert_eq!(state.history.len(), 2);
        assert_eq!(state.history[0].issue_number, 1);
        assert_eq!(state.history[1].issue_number, 2);
    }

    #[test]
    fn state_add_history_prunes_oldest_when_over_cap() {
        let mut state = State::default();
        for i in 0..(MAX_HISTORY + 50) {
            state.add_history(make_entry(i as u64, Outcome::Success));
        }
        assert_eq!(state.history.len(), MAX_HISTORY);
        // Oldest entries should have been pruned
        assert_eq!(state.history[0].issue_number, 50);
    }

    // ── State persistence ────────────────────────────────────────────

    #[tokio::test]
    async fn state_save_load_roundtrip() {
        let dir = std::env::temp_dir().join("looper-watch-test-state");
        tokio::fs::create_dir_all(&dir).await.unwrap();
        let path = dir.join(format!("roundtrip-{}.json", std::process::id()));

        let mut state = State::default();
        state.add_history(make_entry(42, Outcome::Success));
        state.add_history(make_entry(
            99,
            Outcome::Completed {
                detail: Some("tmux".into()),
            },
        ));
        state.save(&path).await;

        let loaded = State::load(&path).await;
        assert_eq!(loaded.history.len(), 2);
        assert_eq!(loaded.history[0].issue_number, 42);
        assert!(loaded.history[0].outcome.is_done());
        assert_eq!(loaded.history[1].issue_number, 99);

        let _ = tokio::fs::remove_file(&path).await;
    }

    #[tokio::test]
    async fn state_load_returns_default_for_missing_file() {
        let path = std::env::temp_dir().join("looper-watch-test-state/nonexistent.json");
        let state = State::load(&path).await;
        assert!(state.history.is_empty());
    }

    #[tokio::test]
    async fn state_load_handles_corrupt_json_with_backup() {
        let dir = std::env::temp_dir().join("looper-watch-test-state");
        tokio::fs::create_dir_all(&dir).await.unwrap();
        let path = dir.join(format!("corrupt-{}.json", std::process::id()));
        let backup = path.with_extension("json.bak");

        // Write corrupt JSON
        tokio::fs::write(&path, "{ not valid json !!!")
            .await
            .unwrap();

        let state = State::load(&path).await;
        assert!(state.history.is_empty(), "should return empty state");
        assert!(backup.exists(), "should create backup of corrupt file");

        let _ = tokio::fs::remove_file(&path).await;
        let _ = tokio::fs::remove_file(&backup).await;
    }

    #[tokio::test]
    async fn state_save_is_atomic_via_rename() {
        let dir = std::env::temp_dir().join("looper-watch-test-state");
        tokio::fs::create_dir_all(&dir).await.unwrap();
        let path = dir.join(format!("atomic-{}.json", std::process::id()));
        let tmp = path.with_extension("json.tmp");

        let mut state = State::default();
        state.add_history(make_entry(1, Outcome::Success));
        state.save(&path).await;

        // Temp file should NOT exist after successful save (rename removes it)
        assert!(
            !tmp.exists(),
            "temp file should be gone after atomic rename"
        );
        assert!(path.exists(), "final file should exist");

        let _ = tokio::fs::remove_file(&path).await;
    }

    #[tokio::test]
    async fn state_load_with_legacy_full_state_file() {
        let dir = std::env::temp_dir().join("looper-watch-test-state");
        tokio::fs::create_dir_all(&dir).await.unwrap();
        let path = dir.join(format!("legacy-{}.json", std::process::id()));

        // Simulate a legacy state file with plain outcome strings
        let legacy_json = r#"{
            "history": [
                {
                    "issue_number": 1,
                    "issue_title": "Legacy success",
                    "timestamp": "2024-01-01T00:00:00Z",
                    "outcome": "success"
                },
                {
                    "issue_number": 2,
                    "issue_title": "Legacy completed",
                    "timestamp": "2024-01-01T00:01:00Z",
                    "outcome": "completed (tmux)"
                },
                {
                    "issue_number": 3,
                    "issue_title": "Legacy failed",
                    "timestamp": "2024-01-01T00:02:00Z",
                    "outcome": "failed: something broke"
                }
            ]
        }"#;
        tokio::fs::write(&path, legacy_json).await.unwrap();

        let state = State::load(&path).await;
        assert_eq!(state.history.len(), 3);
        assert!(state.history[0].outcome.is_done());
        assert!(state.history[1].outcome.is_done());
        assert!(!state.history[2].outcome.is_done());

        let _ = tokio::fs::remove_file(&path).await;
    }
}

/// Kill all tmux sessions for this repo.
pub async fn kill_all_repo_sessions(repo: &str) -> usize {
    let sessions = list_repo_sessions(repo).await;
    for s in &sessions {
        let _ = Command::new("tmux")
            .args(["kill-session", "-t", s.as_str()])
            .output()
            .await;
    }
    sessions.len()
}
