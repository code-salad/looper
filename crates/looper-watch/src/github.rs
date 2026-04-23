use serde::Deserialize;
use std::time::Duration;
use tokio::process::Command;

#[derive(Debug, Clone, Deserialize)]
pub struct Issue {
    pub number: u64,
    pub title: String,
    pub labels: Vec<Label>,
    // body is fetched from GitHub but not read by is_blocked (kept for future TUI use)
    #[allow(dead_code)]
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DepState {
    Open,
    Closed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DepSource {
    BlockedBy,
    SubIssue,
}

// Private Serde helpers for GraphQL JSON decoding.
#[derive(Deserialize)]
struct GqlResp {
    data: Option<GqlData>,
    errors: Option<serde_json::Value>,
}
#[derive(Deserialize)]
struct GqlData {
    repository: Option<GqlRepo>,
}
#[derive(Deserialize)]
struct GqlRepo {
    issue: Option<GqlIssue>,
}
#[derive(Deserialize)]
struct GqlIssue {
    #[serde(rename = "blockedBy")]
    blocked_by: Option<GqlConn>,
    #[serde(rename = "subIssues")]
    sub_issues: Option<GqlConn>,
}
#[derive(Deserialize)]
struct GqlConn {
    nodes: Vec<GqlDepNode>,
}
#[derive(Deserialize)]
struct GqlDepNode {
    number: u64,
    state: String,
    repository: GqlDepRepo,
}
#[derive(Deserialize)]
struct GqlDepRepo {
    #[serde(rename = "nameWithOwner")]
    name_with_owner: String,
}

/// Parse a GraphQL response body into a flat Dependency list.
/// Empty response (missing repo/issue, or dep graph feature disabled)
/// returns `Ok(vec![])` — callers fall through to label-based blocking.
pub fn parse_dependencies_json(json: &str) -> Result<Vec<Dependency>, String> {
    let resp: GqlResp =
        serde_json::from_str(json).map_err(|e| format!("graphql parse error: {e}"))?;
    if let Some(errs) = resp.errors {
        return Err(format!("graphql errors: {errs}"));
    }
    let issue = match resp.data.and_then(|d| d.repository).and_then(|r| r.issue) {
        Some(i) => i,
        None => return Ok(Vec::new()),
    };
    let mut deps = Vec::new();
    for n in issue.blocked_by.into_iter().flat_map(|c| c.nodes) {
        deps.push(Dependency {
            number: n.number,
            repo: n.repository.name_with_owner,
            state: parse_state(&n.state),
            source: DepSource::BlockedBy,
        });
    }
    for n in issue.sub_issues.into_iter().flat_map(|c| c.nodes) {
        deps.push(Dependency {
            number: n.number,
            repo: n.repository.name_with_owner,
            state: parse_state(&n.state),
            source: DepSource::SubIssue,
        });
    }
    Ok(deps)
}

fn parse_state(s: &str) -> DepState {
    if s.eq_ignore_ascii_case("OPEN") {
        DepState::Open
    } else {
        DepState::Closed
    }
}

/// Returns the matching label name if any label indicates this issue is
/// blocked via manual override (label names containing "blocked" or
/// "dependencies", case-insensitive).
pub fn label_blocks(issue: &Issue) -> Option<String> {
    for label in &issue.labels {
        let lower = label.name.to_lowercase();
        if lower.contains("blocked") || lower.contains("dependencies") {
            return Some(label.name.clone());
        }
    }
    None
}

/// Returns true if any dependency in the list is currently OPEN.
pub fn any_open(deps: &[Dependency]) -> bool {
    deps.iter().any(|d| d.state == DepState::Open)
}

/// Render a Dependency list for the log line — includes source so the reader
/// can distinguish native "Depends on" edges from sub-issue edges.
///   []                                                         when empty
///   [blocked-by owner/repo#5(open), sub-issue owner/repo#9(closed)]
pub fn format_deps_summary(deps: &[Dependency]) -> String {
    if deps.is_empty() {
        return "[]".to_string();
    }
    let parts: Vec<String> = deps
        .iter()
        .map(|d| {
            let src = match d.source {
                DepSource::BlockedBy => "blocked-by",
                DepSource::SubIssue => "sub-issue",
            };
            let state = match d.state {
                DepState::Open => "open",
                DepState::Closed => "closed",
            };
            format!("{} {}#{}({})", src, d.repo, d.number, state)
        })
        .collect();
    format!("[{}]", parts.join(", "))
}

/// Fetch tracked dependencies for an issue via GitHub GraphQL.
///
/// * Empty vec → issue has no deps, or the repo/org does not expose the
///   dep-graph feature (caller treats as "not blocked by deps").
/// * Err → gh invocation failure or GraphQL-level errors.
///
/// Note: we cap each connection at `first: 50`. Issues with more than 50
/// direct deps are pathological for a dev-workflow watcher; add pagination
/// later if this becomes a problem.
pub async fn fetch_dependencies(repo: &str, number: u64) -> Result<Vec<Dependency>, String> {
    let (owner, name) = match repo.split_once('/') {
        Some((o, n)) if !o.is_empty() && !n.is_empty() => (o, n),
        _ => return Err(format!("invalid repo format: {repo}")),
    };
    let query = format!(
        r#"query {{ repository(owner: "{owner}", name: "{name}") {{ issue(number: {number}) {{ blockedBy(first: 50) {{ nodes {{ number state repository {{ nameWithOwner }} }} }} subIssues(first: 50) {{ nodes {{ number state repository {{ nameWithOwner }} }} }} }} }} }}"#
    );
    let output = Command::new("gh")
        .args(["api", "graphql", "-f", &format!("query={query}")])
        .output()
        .await
        .map_err(|e| format!("failed to run gh: {e}"))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("gh api graphql failed: {stderr}"));
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    parse_dependencies_json(&stdout)
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

/// Check if an issue is blocked by labels (manual override) or by any open
/// GitHub-tracked dependency (`blockedBy` + `subIssues`).
pub async fn is_blocked(issue: &Issue, repo: &str) -> bool {
    // 1. Label-based manual override (single source of truth: label_blocks).
    if let Some(name) = label_blocks(issue) {
        eprintln!("#{}: blocked by label '{}'", issue.number, name);
        return true;
    }

    // 2. Native GitHub dependency graph.
    match fetch_dependencies(repo, issue.number).await {
        Ok(deps) => {
            let summary = format_deps_summary(&deps);
            let blocked = any_open(&deps);
            eprintln!(
                "#{}: deps={} -> {}",
                issue.number,
                summary,
                if blocked { "blocked" } else { "not blocked" }
            );
            blocked
        }
        Err(e) => {
            eprintln!(
                "#{}: dep-graph query failed ({}); treating as not blocked",
                issue.number, e
            );
            false
        }
    }
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
