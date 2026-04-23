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

/// A dependency relationship surfaced by GitHub's native issue graph
/// (either a `blockedBy` edge or a `subIssues` edge).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Dependency {
    pub number: u64,
    pub repo: String,
    pub state: DepState,
    pub source: DepSource,
}

#[allow(dead_code)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DepState {
    Open,
    Closed,
}

#[allow(dead_code)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DepSource {
    BlockedBy,
    SubIssue,
}

// Private Serde helpers for GraphQL JSON decoding.
#[allow(dead_code)]
#[derive(Deserialize)]
struct GqlResp {
    data: Option<GqlData>,
    errors: Option<serde_json::Value>,
}
#[allow(dead_code)]
#[derive(Deserialize)]
struct GqlData {
    repository: Option<GqlRepo>,
}
#[allow(dead_code)]
#[derive(Deserialize)]
struct GqlRepo {
    issue: Option<GqlIssue>,
}
#[allow(dead_code)]
#[derive(Deserialize)]
struct GqlIssue {
    #[serde(rename = "blockedBy")]
    blocked_by: Option<GqlConn>,
    #[serde(rename = "subIssues")]
    sub_issues: Option<GqlConn>,
}
#[allow(dead_code)]
#[derive(Deserialize)]
struct GqlConn {
    nodes: Vec<GqlDepNode>,
}
#[allow(dead_code)]
#[derive(Deserialize)]
struct GqlDepNode {
    number: u64,
    state: String,
    repository: GqlDepRepo,
}
#[allow(dead_code)]
#[derive(Deserialize)]
struct GqlDepRepo {
    #[serde(rename = "nameWithOwner")]
    name_with_owner: String,
}

/// Stub: parse_dependencies_json — NOT YET IMPLEMENTED (RED phase stub)
#[allow(dead_code)]
pub fn parse_dependencies_json(_json: &str) -> Result<Vec<Dependency>, String> {
    panic!("not implemented")
}

/// Stub: label_blocks — NOT YET IMPLEMENTED (RED phase stub)
#[allow(dead_code)]
pub fn label_blocks(_issue: &Issue) -> Option<String> {
    panic!("not implemented")
}

/// Stub: any_open — NOT YET IMPLEMENTED (RED phase stub)
#[allow(dead_code)]
pub fn any_open(_deps: &[Dependency]) -> bool {
    panic!("not implemented")
}

/// Stub: format_deps_summary — NOT YET IMPLEMENTED (RED phase stub)
#[allow(dead_code)]
pub fn format_deps_summary(_deps: &[Dependency]) -> String {
    panic!("not implemented")
}

/// Stub: fetch_dependencies — NOT YET IMPLEMENTED (RED phase stub)
#[allow(dead_code)]
pub async fn fetch_dependencies(_repo: &str, _number: u64) -> Result<Vec<Dependency>, String> {
    panic!("not implemented")
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

    // ── parse_dependencies_json ──────────────────────────────────────

    #[test]
    fn parse_dependencies_json_empty_response() {
        let json = r#"{"data":{"repository":{"issue":{"blockedBy":{"nodes":[]},"subIssues":{"nodes":[]}}}}}"#;
        let deps = parse_dependencies_json(json).expect("should parse ok");
        assert!(deps.is_empty());
    }

    #[test]
    fn parse_dependencies_json_blocked_by_open() {
        let json = r#"{
            "data": {
                "repository": {
                    "issue": {
                        "blockedBy": {
                            "nodes": [
                                {
                                    "number": 5,
                                    "state": "OPEN",
                                    "repository": { "nameWithOwner": "code-salad/looper" }
                                }
                            ]
                        },
                        "subIssues": { "nodes": [] }
                    }
                }
            }
        }"#;
        let deps = parse_dependencies_json(json).expect("should parse ok");
        assert_eq!(deps.len(), 1);
        assert_eq!(deps[0].number, 5);
        assert_eq!(deps[0].repo, "code-salad/looper");
        assert_eq!(deps[0].state, DepState::Open);
        assert_eq!(deps[0].source, DepSource::BlockedBy);
    }

    #[test]
    fn parse_dependencies_json_sub_issue_closed() {
        let json = r#"{
            "data": {
                "repository": {
                    "issue": {
                        "blockedBy": { "nodes": [] },
                        "subIssues": {
                            "nodes": [
                                {
                                    "number": 9,
                                    "state": "CLOSED",
                                    "repository": { "nameWithOwner": "owner/repo" }
                                }
                            ]
                        }
                    }
                }
            }
        }"#;
        let deps = parse_dependencies_json(json).expect("should parse ok");
        assert_eq!(deps.len(), 1);
        assert_eq!(deps[0].number, 9);
        assert_eq!(deps[0].state, DepState::Closed);
        assert_eq!(deps[0].source, DepSource::SubIssue);
    }

    #[test]
    fn parse_dependencies_json_mixed_sources_and_cross_repo() {
        let json = r#"{
            "data": {
                "repository": {
                    "issue": {
                        "blockedBy": {
                            "nodes": [
                                {
                                    "number": 1,
                                    "state": "OPEN",
                                    "repository": { "nameWithOwner": "owner/a" }
                                },
                                {
                                    "number": 2,
                                    "state": "CLOSED",
                                    "repository": { "nameWithOwner": "owner/b" }
                                }
                            ]
                        },
                        "subIssues": {
                            "nodes": [
                                {
                                    "number": 3,
                                    "state": "OPEN",
                                    "repository": { "nameWithOwner": "other/c" }
                                }
                            ]
                        }
                    }
                }
            }
        }"#;
        let deps = parse_dependencies_json(json).expect("should parse ok");
        assert_eq!(deps.len(), 3);
        assert_eq!(deps[0].repo, "owner/a");
        assert_eq!(deps[0].source, DepSource::BlockedBy);
        assert_eq!(deps[1].repo, "owner/b");
        assert_eq!(deps[1].source, DepSource::BlockedBy);
        assert_eq!(deps[2].repo, "other/c");
        assert_eq!(deps[2].source, DepSource::SubIssue);
    }

    #[test]
    fn parse_dependencies_json_graphql_errors_returns_err() {
        let json = r#"{"errors":[{"message":"bad"}]}"#;
        let result = parse_dependencies_json(json);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(
            err.contains("graphql errors"),
            "expected 'graphql errors' in: {err}"
        );
    }

    #[test]
    fn parse_dependencies_json_missing_repo_returns_empty() {
        let json = r#"{"data":{"repository":null}}"#;
        let deps = parse_dependencies_json(json).expect("should return ok");
        assert!(deps.is_empty());
    }

    #[test]
    fn parse_dependencies_json_malformed_json_returns_err() {
        let result = parse_dependencies_json("not json");
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(
            err.contains("graphql parse error"),
            "expected 'graphql parse error' in: {err}"
        );
    }

    /// Regression test for the reported bug: GitHub's native sub-issue UI renders
    /// list items as `- [ ] [#123](https://...) Title`, which the old body-text
    /// parser missed because `[` before `#` breaks the prefix match.
    /// The new GraphQL-based approach doesn't parse body text at all — it reads
    /// the structured `subIssues` connection, so any sub-issue linked via the UI
    /// is correctly detected.
    #[test]
    fn parse_dependencies_json_native_sub_issue_ui_link_is_detected() {
        // This JSON represents what GitHub returns for a native sub-issue link
        // (the `- [ ] [#123](...) Title` rendered in the UI body)
        let json = r#"{
            "data": {
                "repository": {
                    "issue": {
                        "blockedBy": { "nodes": [] },
                        "subIssues": {
                            "nodes": [
                                {
                                    "number": 123,
                                    "state": "OPEN",
                                    "repository": { "nameWithOwner": "code-salad/looper" }
                                }
                            ]
                        }
                    }
                }
            }
        }"#;
        let deps = parse_dependencies_json(json).expect("should parse ok");
        assert_eq!(deps.len(), 1, "native sub-issue UI link should be detected");
        assert_eq!(deps[0].number, 123);
        assert_eq!(deps[0].state, DepState::Open);
        assert!(
            any_open(&deps),
            "issue with open native sub-issue link should be detected as blocked"
        );
    }

    // ── format_deps_summary ──────────────────────────────────────────

    #[test]
    fn format_deps_summary_empty_is_brackets() {
        assert_eq!(format_deps_summary(&[]), "[]");
    }

    #[test]
    fn format_deps_summary_renders_source_repo_number_state() {
        let deps = vec![
            Dependency {
                number: 5,
                repo: "owner/a".to_string(),
                state: DepState::Open,
                source: DepSource::BlockedBy,
            },
            Dependency {
                number: 9,
                repo: "owner/b".to_string(),
                state: DepState::Closed,
                source: DepSource::SubIssue,
            },
        ];
        let summary = format_deps_summary(&deps);
        assert!(
            summary.contains("blocked-by owner/a#5(open)"),
            "expected blocked-by entry in: {summary}"
        );
        assert!(
            summary.contains("sub-issue owner/b#9(closed)"),
            "expected sub-issue entry in: {summary}"
        );
    }

    // ── any_open ─────────────────────────────────────────────────────

    #[test]
    fn any_open_true_when_any_open() {
        let deps = vec![
            Dependency {
                number: 1,
                repo: "r/r".to_string(),
                state: DepState::Closed,
                source: DepSource::BlockedBy,
            },
            Dependency {
                number: 2,
                repo: "r/r".to_string(),
                state: DepState::Closed,
                source: DepSource::BlockedBy,
            },
            Dependency {
                number: 3,
                repo: "r/r".to_string(),
                state: DepState::Open,
                source: DepSource::BlockedBy,
            },
        ];
        assert!(any_open(&deps));
    }

    #[test]
    fn any_open_false_when_all_closed() {
        let deps = vec![
            Dependency {
                number: 1,
                repo: "r/r".to_string(),
                state: DepState::Closed,
                source: DepSource::BlockedBy,
            },
            Dependency {
                number: 2,
                repo: "r/r".to_string(),
                state: DepState::Closed,
                source: DepSource::BlockedBy,
            },
            Dependency {
                number: 3,
                repo: "r/r".to_string(),
                state: DepState::Closed,
                source: DepSource::BlockedBy,
            },
        ];
        assert!(!any_open(&deps));
    }

    #[test]
    fn any_open_false_when_empty() {
        assert!(!any_open(&[]));
    }

    // ── label_blocks ─────────────────────────────────────────────────

    #[test]
    fn label_blocks_detects_blocked() {
        let issue = make_issue_with_labels(&["blocked"]);
        assert_eq!(label_blocks(&issue), Some("blocked".to_string()));
    }

    #[test]
    fn label_blocks_detects_dependencies() {
        let issue = make_issue_with_labels(&["dependencies"]);
        assert_eq!(label_blocks(&issue), Some("dependencies".to_string()));
    }

    #[test]
    fn label_blocks_is_case_insensitive() {
        let issue = make_issue_with_labels(&["BLOCKED"]);
        // Returns the original un-lowercased label name
        assert_eq!(label_blocks(&issue), Some("BLOCKED".to_string()));
    }

    #[test]
    fn label_blocks_returns_none_for_unrelated() {
        let issue = make_issue_with_labels(&["bug", "enhancement", "priority:high"]);
        assert_eq!(label_blocks(&issue), None);
    }

    #[test]
    fn label_blocks_returns_none_when_empty() {
        let issue = make_issue_with_labels(&[]);
        assert_eq!(label_blocks(&issue), None);
    }

    // ── fetch_dependencies pre-spawn validation ──────────────────────

    #[tokio::test]
    async fn fetch_dependencies_rejects_malformed_repo() {
        let result = fetch_dependencies("badrepo", 1).await;
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(
            err.contains("invalid repo format"),
            "expected 'invalid repo format' in: {err}"
        );
    }

    #[tokio::test]
    async fn fetch_dependencies_rejects_empty_owner_or_name() {
        let result = fetch_dependencies("/foo", 1).await;
        assert!(result.is_err(), "empty owner should be rejected");
        let result2 = fetch_dependencies("foo/", 1).await;
        assert!(result2.is_err(), "empty name should be rejected");
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
