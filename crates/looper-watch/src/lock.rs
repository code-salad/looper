use std::path::Path;

/// Try to acquire an exclusive lock for this repo.
/// Returns Ok(guard) on success, Err with the other PID on failure.
pub async fn acquire(lock_path: &Path) -> Result<LockGuard, String> {
    // Check if an existing lock is stale
    if let Ok(contents) = tokio::fs::read_to_string(lock_path).await
        && let Ok(pid) = contents.trim().parse::<u32>()
    {
        if is_pid_alive(pid) {
            return Err(format!(
                "another instance is already running (pid {pid}). \
                 If this is stale, remove {}",
                lock_path.display()
            ));
        }
        // Stale lock — remove it
        let _ = tokio::fs::remove_file(lock_path).await;
    }

    let pid = std::process::id();
    tokio::fs::write(lock_path, pid.to_string())
        .await
        .map_err(|e| format!("failed to write lock file: {e}"))?;

    Ok(LockGuard {
        path: lock_path.to_path_buf(),
    })
}

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
