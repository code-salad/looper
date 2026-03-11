use serde::Deserialize;
use std::time::Duration;
use tokio::process::Command;

#[derive(Debug, Clone, Deserialize)]
pub struct Issue {
    pub number: u64,
    pub title: String,
    pub labels: Vec<Label>,
    pub body: Option<String>,
    #[serde(rename = "createdAt")]
    pub created_at: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Label {
    pub name: String,
}

/// Fetch open unassigned issues from a GitHub repo.
pub async fn fetch_open_unassigned(repo: &str, retries: u32) -> Result<Vec<Issue>, String> {
    retry(retries, || async {
        let output = Command::new("gh")
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
            .map_err(|e| format!("failed to run gh: {e}"))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!("gh issue list failed: {stderr}"));
        }

        let stdout = String::from_utf8_lossy(&output.stdout);
        serde_json::from_str(&stdout).map_err(|e| format!("failed to parse issues: {e}"))
    })
    .await
}

/// Assign an issue to the current user (@me).
pub async fn assign_to_me(repo: &str, issue_number: u64, retries: u32) -> Result<(), String> {
    retry(retries, || async {
        let output = Command::new("gh")
            .args([
                "issue",
                "edit",
                &issue_number.to_string(),
                "--repo",
                repo,
                "--add-assignee",
                "@me",
            ])
            .output()
            .await
            .map_err(|e| format!("failed to run gh: {e}"))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!("assign failed: {stderr}"));
        }

        Ok(())
    })
    .await
}

/// Check if a specific issue is open.
pub async fn is_issue_open(repo: &str, number: u64) -> bool {
    let output = Command::new("gh")
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
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim() == "OPEN",
        _ => false,
    }
}

/// Check if an issue is blocked by labels or body references.
pub async fn is_blocked(issue: &Issue, repo: &str) -> bool {
    // Label-based blocking
    for label in &issue.labels {
        let name = label.name.to_lowercase();
        if name.contains("blocked") || name.contains("dependencies") {
            return true;
        }
    }

    let body = match &issue.body {
        Some(b) => b,
        None => return false,
    };

    // Check for dependency references
    for line in body.lines() {
        let is_dep_line = line.contains("- [ ] Depends on #")
            || line.contains("- [ ] depends on #")
            || line.starts_with("- [ ] #")
            || line.to_lowercase().contains("blocked by #");

        if is_dep_line {
            for num in extract_issue_numbers(line) {
                if is_issue_open(repo, num).await {
                    return true;
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

/// Retry an async operation with exponential backoff.
async fn retry<F, Fut, T>(max_retries: u32, f: F) -> Result<T, String>
where
    F: Fn() -> Fut,
    Fut: std::future::Future<Output = Result<T, String>>,
{
    let mut last_err = String::new();
    for attempt in 0..max_retries {
        match f().await {
            Ok(v) => return Ok(v),
            Err(e) => {
                last_err = e;
                if attempt + 1 < max_retries {
                    let delay = Duration::from_secs(2u64.pow(attempt));
                    eprintln!(
                        "  retry {}/{} in {}s: {}",
                        attempt + 1,
                        max_retries,
                        delay.as_secs(),
                        last_err
                    );
                    tokio::time::sleep(delay).await;
                }
            }
        }
    }
    Err(last_err)
}
