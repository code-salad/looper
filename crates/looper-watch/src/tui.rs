use std::io;
use std::path::Path;
use std::time::Duration;

use crossterm::event::{self, Event, KeyCode, KeyModifiers};
use crossterm::execute;
use crossterm::terminal::{
    EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode,
};
use ratatui::Terminal;
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Constraint, Direction, Layout};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Cell, Paragraph, Row, Table, Wrap};

use crate::state;
use crate::worker::{self, AppState};

/// Format a duration in seconds as a human-readable string.
/// - < 60s:    "Xs"        (e.g. "45s")
/// - < 3600s:  "Xm Ys"    (e.g. "12m 34s")
/// - >= 3600s: "Xh Ym Zs" (e.g. "1h 23m 45s")
pub fn format_elapsed(seconds: i64) -> String {
    let seconds = seconds.max(0) as u64;
    let h = seconds / 3600;
    let m = (seconds % 3600) / 60;
    let s = seconds % 60;
    if h > 0 {
        format!("{h}h {m}m {s}s")
    } else if m > 0 {
        format!("{m}m {s}s")
    } else {
        format!("{s}s")
    }
}

pub async fn run_tui(app: AppState, repo: &str, state_path: &Path) -> io::Result<()> {
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    let repo = repo.to_string();

    loop {
        // Snapshot state for rendering
        let log_lines = app.log_lines.lock().await.clone();
        let last_poll = app.last_poll.lock().await.clone();
        let next_poll = app.next_poll.lock().await.clone();
        let open_issues = app.open_issues.lock().await.clone();
        let history = {
            let s = app.state.lock().await;
            s.history.clone()
        };

        // Source of truth: live tmux sessions
        let in_progress = state::in_progress_issues(&repo).await;
        let tmux_sessions = state::list_repo_sessions_with_age(&repo).await;
        let now_ts = chrono::Utc::now().timestamp();

        terminal.draw(|f| {
            let chunks = Layout::default()
                .direction(Direction::Vertical)
                .constraints([
                    Constraint::Length(3),  // header
                    Constraint::Min(8),     // issues table
                    Constraint::Length(10), // tmux sessions
                    Constraint::Min(8),     // log
                    Constraint::Length(1),  // footer
                ])
                .split(f.area());

            // Header
            let poll_info = format!(
                " {} | last poll: {} | next poll: {} | active: {} ",
                repo,
                last_poll.as_deref().unwrap_or("—"),
                next_poll.as_deref().unwrap_or("—"),
                in_progress.len(),
            );
            let header = Paragraph::new(Line::from(vec![
                Span::styled(
                    "looper-watch",
                    Style::default()
                        .fg(Color::Cyan)
                        .add_modifier(Modifier::BOLD),
                ),
                Span::raw(poll_info),
            ]))
            .block(Block::default().borders(Borders::ALL));
            f.render_widget(header, chunks[0]);

            // Issues table
            let header_row = Row::new(["#", "Title", "Status", "Labels"]).style(
                Style::default()
                    .fg(Color::Yellow)
                    .add_modifier(Modifier::BOLD),
            );

            let rows: Vec<Row> = open_issues
                .iter()
                .map(|issue| {
                    let session = state::session_name(&repo, issue.number);
                    let status_text = if in_progress.contains(&issue.number) {
                        // Find the session's created timestamp from our snapshot
                        let elapsed_str = tmux_sessions
                            .iter()
                            .find(|(s, _)| s == &session)
                            .and_then(|(_, ts)| *ts)
                            .map(|ts| format!("  {}", format_elapsed(now_ts - ts)))
                            .unwrap_or_default();
                        let text = format!("⚙ running{elapsed_str}");
                        Span::styled(text, Style::default().fg(Color::Yellow))
                    } else if let Some(entry) = history.iter().find(|e| {
                        e.issue_number == issue.number
                            && (e.outcome.starts_with("success")
                                || e.outcome.starts_with("completed"))
                    }) {
                        // Compute duration from started_at to timestamp
                        let elapsed_str = entry
                            .started_at
                            .as_deref()
                            .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                            .and_then(|start| {
                                chrono::DateTime::parse_from_rfc3339(&entry.timestamp)
                                    .ok()
                                    .map(|end| {
                                        let secs = (end - start).num_seconds();
                                        format!("  {}", format_elapsed(secs))
                                    })
                            })
                            .unwrap_or_default();
                        let text = format!("✓ done{elapsed_str}");
                        Span::styled(text, Style::default().fg(Color::Green))
                    } else {
                        Span::styled("○ open", Style::default().fg(Color::White))
                    };
                    let labels: String = issue
                        .labels
                        .iter()
                        .map(|l| l.name.as_str())
                        .collect::<Vec<_>>()
                        .join(", ");
                    Row::new(vec![
                        Cell::from(format!("#{}", issue.number)),
                        Cell::from(issue.title.chars().take(50).collect::<String>()),
                        Cell::from(status_text),
                        Cell::from(labels),
                    ])
                })
                .collect();

            let table = Table::new(
                rows,
                [
                    Constraint::Length(6),
                    Constraint::Min(30),
                    Constraint::Length(24),
                    Constraint::Length(20),
                ],
            )
            .header(header_row)
            .block(Block::default().title(" Issues ").borders(Borders::ALL));
            f.render_widget(table, chunks[1]);

            // Tmux sessions
            let session_rows: Vec<Row> = tmux_sessions
                .iter()
                .map(|(s, created_ts)| {
                    let elapsed_str = created_ts
                        .map(|ts| format_elapsed(now_ts - ts))
                        .unwrap_or_else(|| "—".to_string());
                    Row::new(vec![
                        Cell::from(s.as_str()),
                        Cell::from(format!("tmux attach -t {s}")),
                        Cell::from(elapsed_str),
                    ])
                })
                .collect();
            let session_table = Table::new(
                session_rows,
                [
                    Constraint::Length(40),
                    Constraint::Min(30),
                    Constraint::Length(12),
                ],
            )
            .header(
                Row::new(["Session", "Attach command", "Elapsed"]).style(
                    Style::default()
                        .fg(Color::Yellow)
                        .add_modifier(Modifier::BOLD),
                ),
            )
            .block(
                Block::default()
                    .title(" Claude Sessions (tmux) ")
                    .borders(Borders::ALL),
            );
            f.render_widget(session_table, chunks[2]);

            // Log
            let visible_lines: Vec<Line> = log_lines
                .iter()
                .rev()
                .take(chunks[3].height.saturating_sub(2) as usize)
                .rev()
                .map(|l| Line::from(l.as_str()))
                .collect();
            let log_widget = Paragraph::new(visible_lines)
                .block(Block::default().title(" Log ").borders(Borders::ALL))
                .wrap(Wrap { trim: false });
            f.render_widget(log_widget, chunks[3]);

            // Footer
            let footer = Paragraph::new(Line::from(vec![
                Span::styled(
                    " q",
                    Style::default().fg(Color::Red).add_modifier(Modifier::BOLD),
                ),
                Span::raw(" quit  "),
                Span::styled(
                    "p",
                    Style::default()
                        .fg(Color::Cyan)
                        .add_modifier(Modifier::BOLD),
                ),
                Span::raw(" force poll  "),
                Span::styled(
                    "k",
                    Style::default().fg(Color::Red).add_modifier(Modifier::BOLD),
                ),
                Span::raw(" kill all sessions"),
            ]));
            f.render_widget(footer, chunks[4]);
        })?;

        // Handle input (non-blocking)
        if event::poll(Duration::from_millis(250))?
            && let Event::Key(key) = event::read()?
        {
            match key.code {
                KeyCode::Char('q') => break,
                KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => break,
                KeyCode::Char('k') => {
                    worker::kill_all_sessions(&repo, state_path, &app).await;
                }
                _ => {}
            }
        }
    }

    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::format_elapsed;

    #[test]
    fn format_elapsed_zero_seconds() {
        assert_eq!(format_elapsed(0), "0s");
    }

    #[test]
    fn format_elapsed_negative_clamped_to_zero() {
        // Negative durations (clock skew, etc.) should display as 0s
        assert_eq!(format_elapsed(-100), "0s");
    }

    #[test]
    fn format_elapsed_seconds_only_below_one_minute() {
        assert_eq!(format_elapsed(1), "1s");
        assert_eq!(format_elapsed(45), "45s");
        assert_eq!(format_elapsed(59), "59s");
    }

    #[test]
    fn format_elapsed_minutes_and_seconds_below_one_hour() {
        // Issue #27 example: "12m 34s"
        assert_eq!(format_elapsed(754), "12m 34s");
        assert_eq!(format_elapsed(60), "1m 0s");
        assert_eq!(format_elapsed(3599), "59m 59s");
    }

    #[test]
    fn format_elapsed_hours_minutes_seconds_at_or_above_one_hour() {
        // Issue #27 example: "1h 23m 45s"
        assert_eq!(format_elapsed(5025), "1h 23m 45s");
        assert_eq!(format_elapsed(3600), "1h 0m 0s");
        assert_eq!(format_elapsed(7384), "2h 3m 4s");
    }

    #[test]
    fn format_elapsed_omits_hours_when_less_than_one_hour() {
        // Acceptance criterion: omit hours if < 1h
        let result = format_elapsed(500);
        assert!(
            !result.contains('h'),
            "should not contain 'h' for < 1h: {result}"
        );
    }

    #[test]
    fn format_elapsed_omits_minutes_when_less_than_one_minute() {
        // Acceptance criterion: omit minutes if < 1m
        let result = format_elapsed(30);
        assert!(
            !result.contains('m'),
            "should not contain 'm' for < 1m: {result}"
        );
    }

    #[test]
    fn format_elapsed_issue_27_running_session_example() {
        // From the issue: "⚙ running  12m 34s"
        let elapsed = format_elapsed(12 * 60 + 34);
        assert_eq!(elapsed, "12m 34s");
    }

    #[test]
    fn format_elapsed_issue_27_done_session_example() {
        // From the issue: "✓ done      8m 12s"
        let elapsed = format_elapsed(8 * 60 + 12);
        assert_eq!(elapsed, "8m 12s");
    }
}
