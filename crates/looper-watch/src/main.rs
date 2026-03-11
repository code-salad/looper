mod github;
mod state;
mod tui;
mod worker;

use std::path::PathBuf;

use clap::Parser;

use crate::state::State;
use crate::worker::AppState;

/// Standalone GitHub issue watcher — polls for unassigned issues and dispatches
/// them to `claude` in tmux sessions. Includes a real-time TUI dashboard.
#[derive(Parser, Debug)]
#[command(name = "looper-watch", version)]
pub struct Cli {
    /// GitHub repository in owner/repo format
    #[arg(short, long)]
    pub repo: String,

    /// Poll interval in seconds
    #[arg(short, long, default_value_t = 600)]
    pub interval: u64,

    /// Maximum concurrent claude processes
    #[arg(short, long, default_value_t = 1)]
    pub concurrency: usize,

    /// State file path (defaults to ~/.local/share/looper-watch/<owner>-<repo>.json)
    #[arg(short, long)]
    pub state_file: Option<PathBuf>,

    /// Max retries for GitHub API calls
    #[arg(long, default_value_t = 3)]
    pub retries: u32,

    /// Run once and exit (useful for cron)
    #[arg(long)]
    pub once: bool,

    /// Allowed tools for claude (comma-separated)
    #[arg(long, default_value = "Bash,Read,Write,Edit,Grep,Glob,Agent,Skill")]
    pub allowed_tools: String,

    /// Dry run — poll and log but don't assign or spawn claude
    #[arg(long)]
    pub dry_run: bool,

    /// Disable TUI and run in headless mode (log to stderr)
    #[arg(long)]
    pub headless: bool,
}

fn default_state_path(repo: &str) -> PathBuf {
    let sanitized = repo.replace('/', "-");
    let base = dirs::data_local_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join("looper-watch");
    base.join(format!("{sanitized}.json"))
}

#[tokio::main]
async fn main() {
    let cli = Cli::parse();

    let state_path = cli
        .state_file
        .clone()
        .unwrap_or_else(|| default_state_path(&cli.repo));

    // Ensure state directory exists
    if let Some(parent) = state_path.parent() {
        let _ = tokio::fs::create_dir_all(parent).await;
    }

    let persisted = State::load(&state_path).await;
    let app = AppState::new(persisted);

    if cli.once {
        worker::poll_once(&cli, &state_path, &app).await;
        return;
    }

    if cli.headless {
        eprintln!(
            "looper-watch: repo={} interval={}s concurrency={} state={}",
            cli.repo, cli.interval, cli.concurrency, state_path.display()
        );
        worker::run_loop(&cli, &state_path, &app).await;
    } else {
        // Run poll loop in background, TUI in foreground
        let poll_app = app.clone();
        let poll_cli_repo = cli.repo.clone();
        let poll_cli_interval = cli.interval;
        let poll_cli_concurrency = cli.concurrency;
        let poll_cli_retries = cli.retries;
        let poll_cli_allowed_tools = cli.allowed_tools.clone();
        let poll_cli_dry_run = cli.dry_run;
        let poll_cli_once = cli.once;
        let poll_state_path = state_path.clone();

        // Clone cli fields into a new Cli for the background task
        let bg_cli = Cli {
            repo: poll_cli_repo,
            interval: poll_cli_interval,
            concurrency: poll_cli_concurrency,
            state_file: Some(poll_state_path.clone()),
            retries: poll_cli_retries,
            once: poll_cli_once,
            allowed_tools: poll_cli_allowed_tools,
            dry_run: poll_cli_dry_run,
            headless: true,
        };

        tokio::spawn(async move {
            worker::run_loop(&bg_cli, &poll_state_path, &poll_app).await;
        });

        if let Err(e) = tui::run_tui(app, &cli.repo).await {
            eprintln!("TUI error: {e}");
        }
    }
}
