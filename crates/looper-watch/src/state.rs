use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::path::Path;
use tokio::process::Command;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Entry {
    pub issue_number: u64,
    pub issue_title: String,
    pub timestamp: String,
    pub outcome: String,
}

/// Persisted state — history only. Live in-progress state comes from tmux.
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct State {
    pub history: Vec<Entry>,
}

impl State {
    pub async fn load(path: &Path) -> Self {
        match tokio::fs::read_to_string(path).await {
            Ok(data) => serde_json::from_str(&data).unwrap_or_default(),
            Err(_) => Self::default(),
        }
    }

    pub async fn save(&self, path: &Path) {
        let data = serde_json::to_string_pretty(self).unwrap_or_default();
        if let Err(e) = tokio::fs::write(path, data).await {
            eprintln!("  warn: failed to write state: {e}");
        }
    }

    pub fn add_history(&mut self, entry: Entry) {
        self.history.push(entry);
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_name_formats_correctly() {
        assert_eq!(session_name("owner/repo", 42), "looper-owner-repo-42");
    }

    #[test]
    fn session_name_sanitizes_slash_in_repo() {
        assert_eq!(session_name("my-org/my-repo", 1), "looper-my-org-my-repo-1");
    }

    #[test]
    fn issue_from_session_parses_valid_session() {
        assert_eq!(
            issue_from_session("owner/repo", "looper-owner-repo-99"),
            Some(99)
        );
    }

    #[test]
    fn issue_from_session_returns_none_for_wrong_prefix() {
        assert_eq!(
            issue_from_session("owner/repo", "other-owner-repo-99"),
            None
        );
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

    #[test]
    fn state_add_history_accumulates_entries() {
        let mut state = State::default();
        assert!(state.history.is_empty());

        state.add_history(Entry {
            issue_number: 1,
            issue_title: "First issue".to_string(),
            timestamp: "2024-01-01T00:00:00Z".to_string(),
            outcome: "success".to_string(),
        });
        state.add_history(Entry {
            issue_number: 2,
            issue_title: "Second issue".to_string(),
            timestamp: "2024-01-01T00:01:00Z".to_string(),
            outcome: "failed".to_string(),
        });

        assert_eq!(state.history.len(), 2);
        assert_eq!(state.history[0].issue_number, 1);
        assert_eq!(state.history[1].issue_number, 2);
    }
}
