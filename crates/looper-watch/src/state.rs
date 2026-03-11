use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Entry {
    pub issue_number: u64,
    pub issue_title: String,
    pub timestamp: String,
    pub outcome: String,
    pub pid: Option<u32>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct State {
    /// Issues currently being processed (assigned + claude spawned).
    pub in_progress: HashSet<u64>,
    /// Completed history.
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

    pub fn is_in_progress(&self, issue_number: u64) -> bool {
        self.in_progress.contains(&issue_number)
    }

    pub fn mark_in_progress(&mut self, issue_number: u64) {
        self.in_progress.insert(issue_number);
    }

    pub fn complete(&mut self, entry: Entry) {
        self.in_progress.remove(&entry.issue_number);
        self.history.push(entry);
    }
}
