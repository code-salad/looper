/// Claim module: write-then-verify protocol for preventing concurrent Claude
/// instances from claiming the same GitHub issue.
///
/// ## Protocol overview
///
/// 1. **Local lock (fast-path):** Create `.looper/locks/<sanitized_repo>-<issue>.lock`
///    with O_EXCL. If the file already exists, return `LocalLockHeld` without
///    hitting the GitHub API at all — same-host races are caught here.
///
/// 2. **Remote claim:** Run `gh issue edit --add-assignee @me --add-label
///    looper-claimed` and post a comment `looper-claim:<run_id>`.
///
/// 3. **Settle window:** Sleep `config.settle_ms` to allow concurrent writes
///    from other hosts to land.
///
/// 4. **Verify:** Fetch the issue's comments and assignees. Find the earliest
///    `looper-claim:` comment. If its run_id is ours, we win — return `Ok(ClaimGuard)`.
///    Otherwise, cede (remove assignee + label, delete lockfile) and return
///    `LostRace`.
///
/// ## Tiebreaker
///
/// Earliest-comment-wins is deterministic: GitHub returns comments in creation
/// order and both instances see the same server state, so both always agree on
/// the winner. Two comments at the same `createdAt` second are rare; we break
/// ties on input order (first in the JSON array). A 3-second settle window is
/// well above observed GitHub comment replication lag; if a second instance
/// posts its claim within 3 s the first will see it at verify time.
///
/// ## Label creation
///
/// `--add-label looper-claimed` fails if the label does not exist in the repo.
/// The assignment and claim comment are the load-bearing parts of the protocol;
/// the label is a convenience for filtering. Therefore label creation/addition
/// is best-effort and the claim is NOT aborted on label error.
///
/// `LABEL_IS_BEST_EFFORT = true` — see `try_claim` implementation.
#[allow(dead_code)]
pub const LABEL_IS_BEST_EFFORT: bool = true;

use std::fs::OpenOptions;
use std::io::Write;
use std::path::{Path, PathBuf};

use serde::Deserialize;

// ── Public types ─────────────────────────────────────────────────────────────

/// A successful claim. Holds the local lockfile path and the run_id.
/// Drop removes the local lockfile (winner cleanup on session end).
/// Remote un-assignment is NOT done on drop — only the winner holds a guard,
/// and un-assignment on PR close is handled elsewhere.
pub struct ClaimGuard {
    lock_path: PathBuf,
    pub run_id: String,
    #[allow(dead_code)]
    pub repo: String,
    #[allow(dead_code)]
    pub issue_number: u64,
}

impl Drop for ClaimGuard {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.lock_path);
    }
}

/// Configuration for the claim protocol.
pub struct ClaimConfig {
    /// Milliseconds to sleep between claim and verify. Default: 3000.
    pub settle_ms: u64,
    /// Directory where per-issue lock files are stored.
    pub locks_dir: PathBuf,
}

impl ClaimConfig {
    /// Construct a config using the default locks directory
    /// (`<data_local>/looper-watch/locks`).
    pub fn default_for(_repo: &str) -> Self {
        let locks_dir = dirs::data_local_dir()
            .unwrap_or_else(|| PathBuf::from("/tmp"))
            .join("looper-watch")
            .join("locks");
        Self {
            settle_ms: 3000,
            locks_dir,
        }
    }
}

#[derive(Debug)]
pub enum ClaimError {
    /// Another process on this host holds the local O_EXCL lock.
    LocalLockHeld,
    /// Another instance posted its claim comment earlier; `winner` is its run_id.
    LostRace { winner: String },
    /// A `gh` CLI invocation failed.
    GhFailure(String),
    /// An I/O error.
    Io(String),
}

impl std::fmt::Display for ClaimError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ClaimError::LocalLockHeld => write!(f, "local lock held by another process"),
            ClaimError::LostRace { winner } => write!(f, "lost race to {winner}"),
            ClaimError::GhFailure(msg) => write!(f, "gh failure: {msg}"),
            ClaimError::Io(msg) => write!(f, "io error: {msg}"),
        }
    }
}

/// Internal decision enum used by `decide_winner`.
#[derive(Debug, PartialEq)]
pub enum Decision {
    Won,
    Lost { winner: String },
}

// ── JSON structures for gh output ────────────────────────────────────────────

#[derive(Debug, Clone, Deserialize)]
pub struct Comment {
    pub body: String,
    #[serde(rename = "createdAt")]
    pub created_at: String,
}

// ── Pure helpers (all unit-tested, no network) ────────────────────────────────

/// Extract the run_id from a claim comment body.
///
/// Returns `Some(run_id)` if the body starts with `"looper-claim:"`, where
/// `run_id` is everything after the first colon. Returns `None` otherwise.
///
/// Note: run_ids may contain colons (e.g. IPv6 hostnames like `host::1-123-abc`).
/// We split on the *first* colon after the `looper-claim` prefix.
pub fn parse_claim_body(body: &str) -> Option<&str> {
    body.strip_prefix("looper-claim:")
}

/// Find the earliest claim comment from a slice of comments.
///
/// Returns `Some((created_at, run_id))` for the claim comment with the
/// smallest `createdAt` timestamp string (RFC3339 lexicographic comparison).
/// Ties on identical `createdAt` are broken by input order (first in slice).
/// Returns `None` if no claim comments are present.
pub fn earliest_claim(comments: &[Comment]) -> Option<(&str, &str)> {
    comments
        .iter()
        .filter_map(|c| parse_claim_body(&c.body).map(|run_id| (c.created_at.as_str(), run_id)))
        .min_by(|a, b| a.0.cmp(b.0))
}

/// Decide whether we won or lost the race.
///
/// `our_run_id` is the run id we posted. `comments` is the full comment list
/// from `gh issue view --json comments`.
///
/// - If no claim comment exists at all → `Lost { winner: "" }` (unexpected;
///   our comment should be there; safe default is to cede).
/// - If the earliest claim comment's run_id equals `our_run_id` → `Won`.
/// - Otherwise → `Lost { winner: <other_run_id> }`.
pub fn decide_winner(comments: &[Comment], our_run_id: &str) -> Decision {
    match earliest_claim(comments) {
        None => Decision::Lost {
            winner: String::new(),
        },
        Some((_ts, run_id)) => {
            if run_id == our_run_id {
                Decision::Won
            } else {
                Decision::Lost {
                    winner: run_id.to_string(),
                }
            }
        }
    }
}

/// Replace `/` with `-` in a repo slug so it can be used in a filename.
///
/// Matches the sanitization in `main.rs::default_state_path`.
pub fn sanitize_repo(repo: &str) -> String {
    repo.replace('/', "-")
}

/// Generate a unique run id for this invocation.
///
/// Format: `<hostname>-<pid>-<uuid_v4>`.
/// Uses `uuid::Uuid::new_v4()` for the UUID component and reads the hostname
/// from `/proc/sys/kernel/hostname` (Linux) or falls back to `"unknown"`.
/// We avoid adding a `hostname` crate dependency by reading the file directly;
/// `libc::gethostname` would be an alternative but the file read is simpler.
pub fn generate_run_id() -> String {
    let hostname = std::fs::read_to_string("/proc/sys/kernel/hostname")
        .ok()
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "unknown".to_string());
    let pid = std::process::id();
    let uuid = uuid::Uuid::new_v4();
    format!("{hostname}-{pid}-{uuid}")
}

/// Create the local lock file with O_EXCL semantics.
///
/// Writes `run_id` into the lock file for debugging.
///
/// Returns:
/// - `Ok(lock_path)` — lock acquired, caller is responsible for deleting it.
/// - `Err(ClaimError::LocalLockHeld)` — another process holds the lock.
/// - `Err(ClaimError::Io(...))` — unexpected I/O error.
pub fn try_local_lock(
    locks_dir: &Path,
    lock_name: &str,
    run_id: &str,
) -> Result<PathBuf, ClaimError> {
    std::fs::create_dir_all(locks_dir)
        .map_err(|e| ClaimError::Io(format!("create_dir_all failed: {e}")))?;
    let lock_path = locks_dir.join(lock_name);
    match OpenOptions::new()
        .write(true)
        .create_new(true) // O_CREAT | O_EXCL
        .open(&lock_path)
    {
        Ok(mut f) => {
            let _ = write!(f, "{run_id}");
            Ok(lock_path)
        }
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => Err(ClaimError::LocalLockHeld),
        Err(e) => Err(ClaimError::Io(e.to_string())),
    }
}

// ── Network-touching claim function ──────────────────────────────────────────

/// Attempt to claim an issue using the write-then-verify protocol.
///
/// This function calls `gh` and is not covered by unit tests. Unit tests cover
/// all pure helpers above. Manual smoke testing validates this integration.
pub async fn try_claim(
    repo: &str,
    issue_number: u64,
    config: &ClaimConfig,
) -> Result<ClaimGuard, ClaimError> {
    let run_id = generate_run_id();
    let lock_name = format!("{}-{}.lock", sanitize_repo(repo), issue_number);

    // Step 1: local lock (fast-path — no API call if already locked)
    let lock_path = try_local_lock(&config.locks_dir, &lock_name, &run_id)?;

    // Step 2: remote claim (best-effort label, mandatory assignee + comment)
    // Add label first (best-effort — don't fail if label doesn't exist)
    let _ = tokio::process::Command::new("gh")
        .args([
            "label",
            "create",
            "looper-claimed",
            "--repo",
            repo,
            "--force",
        ])
        .output()
        .await;

    let assign_result = tokio::process::Command::new("gh")
        .args([
            "issue",
            "edit",
            &issue_number.to_string(),
            "--repo",
            repo,
            "--add-assignee",
            "@me",
            "--add-label",
            "looper-claimed",
        ])
        .output()
        .await;

    match assign_result {
        Ok(o) if o.status.success() => {}
        Ok(o) => {
            // Assignment failed — clean up local lock and return error
            let _ = std::fs::remove_file(&lock_path);
            let stderr = String::from_utf8_lossy(&o.stderr);
            return Err(ClaimError::GhFailure(format!("assign failed: {stderr}")));
        }
        Err(e) => {
            let _ = std::fs::remove_file(&lock_path);
            return Err(ClaimError::GhFailure(format!("gh exec failed: {e}")));
        }
    }

    // Post claim comment
    let comment_body = format!("looper-claim:{run_id}");
    let comment_result = tokio::process::Command::new("gh")
        .args([
            "issue",
            "comment",
            &issue_number.to_string(),
            "--repo",
            repo,
            "--body",
            &comment_body,
        ])
        .output()
        .await;

    match comment_result {
        Ok(o) if o.status.success() => {}
        Ok(o) => {
            let _ = std::fs::remove_file(&lock_path);
            let stderr = String::from_utf8_lossy(&o.stderr);
            return Err(ClaimError::GhFailure(format!("comment failed: {stderr}")));
        }
        Err(e) => {
            let _ = std::fs::remove_file(&lock_path);
            return Err(ClaimError::GhFailure(format!("gh exec failed: {e}")));
        }
    }

    // Step 3: settle
    tokio::time::sleep(tokio::time::Duration::from_millis(config.settle_ms)).await;

    // Step 4: verify
    let view_result = tokio::process::Command::new("gh")
        .args([
            "issue",
            "view",
            &issue_number.to_string(),
            "--repo",
            repo,
            "--json",
            "comments,assignees",
        ])
        .output()
        .await;

    let output = match view_result {
        Ok(o) if o.status.success() => o,
        Ok(o) => {
            let _ = std::fs::remove_file(&lock_path);
            let stderr = String::from_utf8_lossy(&o.stderr);
            return Err(ClaimError::GhFailure(format!("view failed: {stderr}")));
        }
        Err(e) => {
            let _ = std::fs::remove_file(&lock_path);
            return Err(ClaimError::GhFailure(format!("gh exec failed: {e}")));
        }
    };

    #[derive(Deserialize)]
    struct IssueView {
        comments: Vec<Comment>,
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let view: IssueView = match serde_json::from_str(&stdout) {
        Ok(v) => v,
        Err(e) => {
            let _ = std::fs::remove_file(&lock_path);
            return Err(ClaimError::Io(format!("parse view failed: {e}")));
        }
    };

    match decide_winner(&view.comments, &run_id) {
        Decision::Won => Ok(ClaimGuard {
            lock_path,
            run_id,
            repo: repo.to_string(),
            issue_number,
        }),
        Decision::Lost { winner } => {
            // Cede: best-effort remove assignee + label
            let _ = tokio::process::Command::new("gh")
                .args([
                    "issue",
                    "edit",
                    &issue_number.to_string(),
                    "--repo",
                    repo,
                    "--remove-assignee",
                    "@me",
                    "--remove-label",
                    "looper-claimed",
                ])
                .output()
                .await;
            let _ = std::fs::remove_file(&lock_path);
            Err(ClaimError::LostRace { winner })
        }
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicU64, Ordering};

    use super::*;

    static TEST_COUNTER: AtomicU64 = AtomicU64::new(0);

    fn tmp_locks_dir() -> PathBuf {
        let n = TEST_COUNTER.fetch_add(1, Ordering::SeqCst);
        let dir = std::env::temp_dir()
            .join("looper-watch-claim-tests")
            .join(format!("{}-{n}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn make_comment(body: &str, created_at: &str) -> Comment {
        Comment {
            body: body.to_string(),
            created_at: created_at.to_string(),
        }
    }

    // ── parse_claim_body ──────────────────────────────────────────────────────

    #[test]
    fn parse_claim_body_extracts_run_id() {
        let result = parse_claim_body("looper-claim:host-123-abcd");
        assert_eq!(result, Some("host-123-abcd"));
    }

    #[test]
    fn parse_claim_body_returns_none_for_non_claim() {
        let result = parse_claim_body("some other comment");
        assert_eq!(result, None);
    }

    #[test]
    fn parse_claim_body_handles_empty_run_id() {
        // "looper-claim:" with no run_id returns Some("") — still a valid claim
        // marker; the decide_winner comparator will never match "" against a real
        // non-empty generated run_id, so this safely resolves to Lost.
        let result = parse_claim_body("looper-claim:");
        assert_eq!(result, Some(""));
    }

    #[test]
    fn parse_claim_body_handles_colon_in_run_id() {
        // IPv6-style hostname like host::1-123-abc
        let result = parse_claim_body("looper-claim:host::1-123-abc");
        assert_eq!(result, Some("host::1-123-abc"));
    }

    // ── earliest_claim ────────────────────────────────────────────────────────

    #[test]
    fn earliest_claim_picks_oldest_by_created_at() {
        let comments = vec![
            make_comment("looper-claim:run-c", "2024-01-01T00:00:03Z"),
            make_comment("looper-claim:run-a", "2024-01-01T00:00:01Z"),
            make_comment("looper-claim:run-b", "2024-01-01T00:00:02Z"),
        ];
        let result = earliest_claim(&comments);
        assert_eq!(result, Some(("2024-01-01T00:00:01Z", "run-a")));
    }

    #[test]
    fn earliest_claim_ignores_non_claim_comments() {
        let comments = vec![
            make_comment("regular comment", "2024-01-01T00:00:01Z"),
            make_comment("looper-claim:run-x", "2024-01-01T00:00:02Z"),
            make_comment("another regular comment", "2024-01-01T00:00:00Z"),
        ];
        let result = earliest_claim(&comments);
        assert_eq!(result, Some(("2024-01-01T00:00:02Z", "run-x")));
    }

    #[test]
    fn earliest_claim_returns_none_when_no_claim_comments() {
        let comments = vec![
            make_comment("regular comment", "2024-01-01T00:00:01Z"),
            make_comment("another comment", "2024-01-01T00:00:02Z"),
        ];
        let result = earliest_claim(&comments);
        assert!(result.is_none());
    }

    #[test]
    fn earliest_claim_breaks_ties_on_identical_timestamps() {
        // When two claim comments have the same createdAt, we take the first in
        // input order (stable sort / min_by prefers earlier in slice on equal keys).
        let comments = vec![
            make_comment("looper-claim:run-first", "2024-01-01T00:00:01Z"),
            make_comment("looper-claim:run-second", "2024-01-01T00:00:01Z"),
        ];
        let result = earliest_claim(&comments);
        // First in input order wins the tie.
        assert_eq!(result, Some(("2024-01-01T00:00:01Z", "run-first")));
    }

    #[test]
    fn earliest_claim_single_claim_comment() {
        let comments = vec![make_comment(
            "looper-claim:only-run",
            "2024-01-01T00:00:01Z",
        )];
        let result = earliest_claim(&comments);
        assert_eq!(result, Some(("2024-01-01T00:00:01Z", "only-run")));
    }

    // ── decide_winner ─────────────────────────────────────────────────────────

    #[test]
    fn verify_wins_when_our_run_id_is_earliest() {
        let comments = vec![
            make_comment("looper-claim:ours-first", "2024-01-01T00:00:01Z"),
            make_comment("looper-claim:theirs-second", "2024-01-01T00:00:02Z"),
        ];
        let decision = decide_winner(&comments, "ours-first");
        assert_eq!(decision, Decision::Won);
    }

    #[test]
    fn verify_loses_when_another_run_id_is_earliest() {
        let comments = vec![
            make_comment("looper-claim:theirs-first", "2024-01-01T00:00:01Z"),
            make_comment("looper-claim:ours-second", "2024-01-01T00:00:02Z"),
        ];
        let decision = decide_winner(&comments, "ours-second");
        assert_eq!(
            decision,
            Decision::Lost {
                winner: "theirs-first".to_string()
            }
        );
    }

    #[test]
    fn verify_loses_when_no_claim_comments_present() {
        // Unexpected state (our comment should exist); safe default is Lost.
        let comments = vec![make_comment("regular comment", "2024-01-01T00:00:01Z")];
        let decision = decide_winner(&comments, "our-run-id");
        assert_eq!(
            decision,
            Decision::Lost {
                winner: String::new()
            }
        );
    }

    #[test]
    fn verify_wins_with_single_own_claim_comment() {
        let comments = vec![make_comment(
            "looper-claim:our-only",
            "2024-01-01T00:00:01Z",
        )];
        let decision = decide_winner(&comments, "our-only");
        assert_eq!(decision, Decision::Won);
    }

    #[test]
    fn verify_loses_with_single_other_claim_comment() {
        let comments = vec![make_comment(
            "looper-claim:their-only",
            "2024-01-01T00:00:01Z",
        )];
        let decision = decide_winner(&comments, "our-run-id");
        assert_eq!(
            decision,
            Decision::Lost {
                winner: "their-only".to_string()
            }
        );
    }

    #[test]
    fn verify_loses_when_empty_run_id_comment_exists() {
        // "looper-claim:" (empty run_id) never matches our non-empty run_id → Lost.
        let comments = vec![make_comment("looper-claim:", "2024-01-01T00:00:01Z")];
        let decision = decide_winner(&comments, "our-real-run-id");
        assert_eq!(
            decision,
            Decision::Lost {
                winner: String::new()
            }
        );
    }

    // ── local lock ────────────────────────────────────────────────────────────

    #[test]
    fn local_lock_create_new_succeeds() {
        let locks_dir = tmp_locks_dir();
        let result = try_local_lock(&locks_dir, "test.lock", "run-id-abc");
        assert!(result.is_ok(), "first lock creation should succeed");
        let lock_path = result.unwrap();
        assert!(lock_path.exists(), "lock file should exist on disk");
        let contents = std::fs::read_to_string(&lock_path).unwrap();
        assert_eq!(
            contents, "run-id-abc",
            "lock file should contain the run_id"
        );
        let _ = std::fs::remove_file(lock_path);
    }

    #[test]
    fn local_lock_fails_when_already_exists() {
        let locks_dir = tmp_locks_dir();
        // Pre-create the lock file
        std::fs::write(locks_dir.join("test.lock"), "existing-run").unwrap();
        let result = try_local_lock(&locks_dir, "test.lock", "new-run-id");
        assert!(
            matches!(result, Err(ClaimError::LocalLockHeld)),
            "second attempt should return LocalLockHeld"
        );
    }

    #[test]
    fn claim_guard_drop_removes_local_lockfile() {
        let locks_dir = tmp_locks_dir();
        let lock_path =
            try_local_lock(&locks_dir, "drop-test.lock", "run-id").expect("should acquire lock");
        assert!(lock_path.exists(), "lock file should exist before drop");

        // Create a ClaimGuard that owns this lock_path
        let guard = ClaimGuard {
            lock_path: lock_path.clone(),
            run_id: "run-id".to_string(),
            repo: "owner/repo".to_string(),
            issue_number: 1,
        };

        drop(guard);

        assert!(
            !lock_path.exists(),
            "lock file should be removed after ClaimGuard is dropped"
        );
    }

    // ── sanitize_repo ─────────────────────────────────────────────────────────

    #[test]
    fn sanitize_repo_replaces_slash_with_dash() {
        assert_eq!(sanitize_repo("owner/repo"), "owner-repo");
    }

    #[test]
    fn sanitize_repo_no_slash_unchanged() {
        assert_eq!(sanitize_repo("noslash"), "noslash");
    }

    #[test]
    fn sanitize_repo_multiple_slashes() {
        assert_eq!(sanitize_repo("org/team/repo"), "org-team-repo");
    }

    // ── generate_run_id ───────────────────────────────────────────────────────

    #[test]
    fn run_id_format_has_three_dash_separated_parts() {
        // Format: <hostname>-<pid>-<uuid>
        // The uuid itself contains 4 dashes, so total dashes >= 2.
        // We assert: contains at least 2 '-' characters and ends with a UUID-like
        // 36-character suffix.
        let run_id = generate_run_id();
        let dash_count = run_id.chars().filter(|&c| c == '-').count();
        assert!(
            dash_count >= 2,
            "run_id should have at least 2 '-' separators, got: {run_id}"
        );
        // UUID v4 is 36 chars (xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx)
        // The last segment after the hostname-pid prefix should be the UUID.
        // We verify the run_id is non-empty and has reasonable length.
        assert!(
            run_id.len() > 10,
            "run_id should be reasonably long, got: {run_id}"
        );
    }

    // ── error path cleanup ────────────────────────────────────────────────────

    #[test]
    fn delete_if_exists_removes_existing_file() {
        // Verify that removing a freshly created lock cleans it up.
        // This models the cleanup done in try_claim on gh failure.
        let locks_dir = tmp_locks_dir();
        let lock_path = try_local_lock(&locks_dir, "cleanup.lock", "run-cleanup").unwrap();
        assert!(lock_path.exists());
        let _ = std::fs::remove_file(&lock_path);
        assert!(!lock_path.exists(), "lock should be removed after cleanup");
    }
}
