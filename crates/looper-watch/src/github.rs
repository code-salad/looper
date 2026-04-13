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
/// Kept for potential direct use; claim::try_claim is the preferred entry point.
#[allow(dead_code)]
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

#[cfg(test)]
mod tests {
    use super::*;

    /// Extract just the label-based blocking decision (no network needed).
    fn is_blocked_by_labels(issue: &Issue) -> bool {
        issue.labels.iter().any(|l| {
            let name = l.name.to_lowercase();
            name.contains("blocked") || name.contains("dependencies")
        })
    }

    /// Check if the body contains dependency reference lines (without resolving them).
    fn dependency_refs_in_body(body: &str) -> Vec<u64> {
        let mut refs = Vec::new();
        for line in body.lines() {
            let is_dep_line = line.contains("- [ ] Depends on #")
                || line.contains("- [ ] depends on #")
                || line.starts_with("- [ ] #")
                || line.to_lowercase().contains("blocked by #");
            if is_dep_line {
                refs.extend(extract_issue_numbers(line));
            }
        }
        refs
    }

    fn make_issue_with_labels(labels: &[&str]) -> Issue {
        Issue {
            number: 1,
            title: "Test".to_string(),
            labels: labels
                .iter()
                .map(|n| Label {
                    name: n.to_string(),
                })
                .collect(),
            body: None,
            created_at: "2024-01-01T00:00:00Z".to_string(),
        }
    }

    // ── extract_issue_numbers ────────────────────────────────────────

    #[test]
    fn extract_single_issue_number() {
        assert_eq!(extract_issue_numbers("Depends on #42"), vec![42]);
    }

    #[test]
    fn extract_multiple_issue_numbers() {
        assert_eq!(
            extract_issue_numbers("- [ ] #10 and #20 and #30"),
            vec![10, 20, 30]
        );
    }

    #[test]
    fn extract_no_issue_numbers_from_plain_text() {
        assert!(extract_issue_numbers("no issues here").is_empty());
    }

    #[test]
    fn extract_ignores_hash_without_digits() {
        assert!(extract_issue_numbers("# Heading").is_empty());
    }

    #[test]
    fn extract_handles_hash_at_end_of_line() {
        assert!(extract_issue_numbers("trailing #").is_empty());
    }

    #[test]
    fn extract_adjacent_hashes() {
        assert_eq!(extract_issue_numbers("#1#2#3"), vec![1, 2, 3]);
    }

    // ── label-based blocking ─────────────────────────────────────────

    #[test]
    fn blocked_by_label_containing_blocked() {
        let issue = make_issue_with_labels(&["blocked"]);
        assert!(is_blocked_by_labels(&issue));
    }

    #[test]
    fn blocked_by_label_containing_dependencies() {
        let issue = make_issue_with_labels(&["dependencies"]);
        assert!(is_blocked_by_labels(&issue));
    }

    #[test]
    fn not_blocked_by_unrelated_labels() {
        let issue = make_issue_with_labels(&["bug", "enhancement", "priority:high"]);
        assert!(!is_blocked_by_labels(&issue));
    }

    #[test]
    fn blocked_label_is_case_insensitive() {
        let issue = make_issue_with_labels(&["BLOCKED"]);
        assert!(is_blocked_by_labels(&issue));
    }

    #[test]
    fn not_blocked_when_no_labels() {
        let issue = make_issue_with_labels(&[]);
        assert!(!is_blocked_by_labels(&issue));
    }

    // ── dependency reference detection ───────────────────────────────

    #[test]
    fn detects_depends_on_syntax() {
        let body = "Some context\n- [ ] Depends on #15\n- [x] Done";
        assert_eq!(dependency_refs_in_body(body), vec![15]);
    }

    #[test]
    fn detects_lowercase_depends_on() {
        let body = "- [ ] depends on #7";
        assert_eq!(dependency_refs_in_body(body), vec![7]);
    }

    #[test]
    fn detects_blocked_by_syntax() {
        let body = "Blocked by #3 and #4";
        assert_eq!(dependency_refs_in_body(body), vec![3, 4]);
    }

    #[test]
    fn detects_checkbox_issue_ref() {
        let body = "- [ ] #100\n- [x] #200";
        // Only unchecked checkboxes starting with "- [ ] #" are dependency lines
        assert_eq!(dependency_refs_in_body(body), vec![100]);
    }

    #[test]
    fn no_refs_in_plain_body() {
        let body = "This is a normal issue body with no dependencies.";
        assert!(dependency_refs_in_body(body).is_empty());
    }

    #[test]
    fn no_refs_when_body_empty() {
        assert!(dependency_refs_in_body("").is_empty());
    }

    // ── retry utility ────────────────────────────────────────────────

    #[tokio::test]
    async fn retry_returns_ok_on_first_success() {
        let result: Result<i32, String> = retry(3, || async { Ok(42) }).await;
        assert_eq!(result.unwrap(), 42);
    }

    #[tokio::test]
    async fn retry_returns_err_after_exhausting_retries() {
        let result: Result<i32, String> = retry(1, || async { Err("fail".to_string()) }).await;
        assert_eq!(result.unwrap_err(), "fail");
    }
}
