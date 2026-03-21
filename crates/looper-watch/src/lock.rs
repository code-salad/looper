use std::fs::OpenOptions;
use std::io::Write;
use std::path::Path;

/// Try to acquire an exclusive lock for this repo.
/// Returns Ok(guard) on success, Err with a message on failure.
///
/// Uses O_CREAT|O_EXCL for atomic creation — no TOCTOU race between
/// "does the file exist?" and "write my PID".
pub async fn acquire(lock_path: &Path) -> Result<LockGuard, String> {
    let path = lock_path.to_path_buf();
    let pid = std::process::id();

    // Try atomic exclusive create first
    match try_exclusive_create(&path, pid) {
        Ok(()) => {
            return Ok(LockGuard { path });
        }
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
            // Lock file exists — check if the holder is still alive
        }
        Err(e) => {
            return Err(format!("failed to create lock file: {e}"));
        }
    }

    // Read existing lock to check staleness
    let contents = tokio::fs::read_to_string(&path)
        .await
        .map_err(|e| format!("failed to read lock file: {e}"))?;

    let existing_pid = contents
        .trim()
        .parse::<u32>()
        .map_err(|_| format!("lock file contains invalid PID: {contents:?}"))?;

    if is_pid_alive(existing_pid) {
        return Err(format!(
            "another instance is already running (pid {existing_pid}). \
             If this is stale, remove {}",
            lock_path.display()
        ));
    }

    // Stale lock — remove and retry with exclusive create
    let _ = tokio::fs::remove_file(&path).await;

    try_exclusive_create(&path, pid).map_err(|e| {
        if e.kind() == std::io::ErrorKind::AlreadyExists {
            "another instance acquired the lock between stale removal and re-creation".to_string()
        } else {
            format!("failed to create lock file: {e}")
        }
    })?;

    Ok(LockGuard { path })
}

/// Atomically create the lock file with O_CREAT|O_EXCL and write our PID.
fn try_exclusive_create(path: &Path, pid: u32) -> std::io::Result<()> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true) // O_CREAT | O_EXCL
        .open(path)?;
    write!(file, "{pid}")?;
    Ok(())
}

#[derive(Debug)]
pub struct LockGuard {
    path: std::path::PathBuf,
}

impl Drop for LockGuard {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

fn is_pid_alive(pid: u32) -> bool {
    #[cfg(unix)]
    {
        // kill(pid, 0) checks if process exists without sending a signal
        unsafe { libc::kill(pid as i32, 0) == 0 }
    }
    #[cfg(not(unix))]
    {
        let _ = pid;
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    static TEST_COUNTER: AtomicU64 = AtomicU64::new(0);

    /// Each test gets its own unique lock file to avoid interference.
    fn tmp_lock_path(label: &str) -> PathBuf {
        let n = TEST_COUNTER.fetch_add(1, Ordering::SeqCst);
        let dir = std::env::temp_dir().join("looper-watch-test-locks");
        std::fs::create_dir_all(&dir).unwrap();
        dir.join(format!("{label}-{}-{n}.lock", std::process::id()))
    }

    #[tokio::test]
    async fn acquire_creates_lock_file_with_current_pid() {
        let path = tmp_lock_path("create");

        let guard = acquire(&path).await.expect("should acquire lock");
        let contents = std::fs::read_to_string(&path).unwrap();
        assert_eq!(contents, std::process::id().to_string());

        drop(guard);
        assert!(!path.exists(), "lock file should be removed on drop");
    }

    #[tokio::test]
    async fn acquire_fails_when_lock_held_by_live_process() {
        let path = tmp_lock_path("held");

        let _guard = acquire(&path).await.expect("first acquire should succeed");

        let result = acquire(&path).await;
        assert!(result.is_err(), "second acquire should fail");
        assert!(
            result.unwrap_err().contains("already running"),
            "error should mention already running"
        );
    }

    #[tokio::test]
    async fn acquire_reclaims_stale_lock_from_dead_pid() {
        let path = tmp_lock_path("stale");

        // Write a lock file with a PID that almost certainly doesn't exist
        std::fs::write(&path, "999999999").unwrap();

        let guard = acquire(&path).await.expect("should reclaim stale lock");
        let contents = std::fs::read_to_string(&path).unwrap();
        assert_eq!(contents, std::process::id().to_string());
        drop(guard);
    }

    #[tokio::test]
    async fn lock_guard_removes_file_on_drop() {
        let path = tmp_lock_path("drop");

        {
            let _guard = acquire(&path).await.unwrap();
            assert!(path.exists());
        }
        assert!(!path.exists());
    }
}
