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

/// Truncate a title to fit within a column, adding "…" if needed.
fn truncate_title(title: &str, max_chars: usize) -> String {
    if title.chars().count() <= max_chars {
        title.to_string()
    } else {
        let truncated: String = title.chars().take(max_chars.saturating_sub(1)).collect();
        format!("{truncated}…")
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
            let area = f.area();

            // Categorize issues into kanban columns
            let mut col_open: Vec<Line> = Vec::new();
            let mut col_running: Vec<Line> = Vec::new();
            let mut col_done: Vec<Line> = Vec::new();

            for issue in &open_issues {
                let session = state::session_name(&repo, issue.number);
                let labels: String = issue
                    .labels
                    .iter()
                    .map(|l| l.name.as_str())
                    .collect::<Vec<_>>()
                    .join(", ");

                if in_progress.contains(&issue.number) {
                    // Running column
                    let elapsed_str = tmux_sessions
                        .iter()
                        .find(|(s, _)| s == &session)
                        .and_then(|(_, ts)| *ts)
                        .map(|ts| format_elapsed(now_ts - ts))
                        .unwrap_or_default();
                    col_running.push(Line::from(vec![
                        Span::styled(
                            format!("#{}", issue.number),
                            Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD),
                        ),
                        Span::raw(format!(" {}", truncate_title(&issue.title, 20))),
                    ]));
                    if !elapsed_str.is_empty() {
                        col_running.push(Line::from(Span::styled(
                            format!("  ⏱ {elapsed_str}"),
                            Style::default().fg(Color::Yellow),
                        )));
                    }
                    if !labels.is_empty() {
                        col_running.push(Line::from(Span::styled(
                            format!("  {labels}"),
                            Style::default().fg(Color::DarkGray),
                        )));
                    }
                    col_running.push(Line::from(""));
                } else if history.iter().any(|e| {
                    e.issue_number == issue.number
                        && (e.outcome.starts_with("success")
                            || e.outcome.starts_with("completed"))
                }) {
                    // Done column
                    let elapsed_str = history
                        .iter()
                        .find(|e| {
                            e.issue_number == issue.number
                                && (e.outcome.starts_with("success")
                                    || e.outcome.starts_with("completed"))
                        })
                        .and_then(|entry| {
                            entry
                                .started_at
                                .as_deref()
                                .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                                .and_then(|start| {
                                    chrono::DateTime::parse_from_rfc3339(&entry.timestamp)
                                        .ok()
                                        .map(|end| format_elapsed((end - start).num_seconds()))
                                })
                        })
                        .unwrap_or_default();
                    col_done.push(Line::from(vec![
                        Span::styled(
                            format!("#{}", issue.number),
                            Style::default().fg(Color::Green).add_modifier(Modifier::BOLD),
                        ),
                        Span::raw(format!(" {}", truncate_title(&issue.title, 20))),
                    ]));
                    if !elapsed_str.is_empty() {
                        col_done.push(Line::from(Span::styled(
                            format!("  ⏱ {elapsed_str}"),
                            Style::default().fg(Color::Green),
                        )));
                    }
                    if !labels.is_empty() {
                        col_done.push(Line::from(Span::styled(
                            format!("  {labels}"),
                            Style::default().fg(Color::DarkGray),
                        )));
                    }
                    col_done.push(Line::from(""));
                } else {
                    // Open column
                    col_open.push(Line::from(vec![
                        Span::styled(
                            format!("#{}", issue.number),
                            Style::default().fg(Color::White).add_modifier(Modifier::BOLD),
                        ),
                        Span::raw(format!(" {}", truncate_title(&issue.title, 20))),
                    ]));
                    if !labels.is_empty() {
                        col_open.push(Line::from(Span::styled(
                            format!("  {labels}"),
                            Style::default().fg(Color::DarkGray),
                        )));
                    }
                    col_open.push(Line::from(""));
                }
            }

            // Also show done entries from history that aren't in open_issues
            for entry in &history {
                if (entry.outcome.starts_with("success") || entry.outcome.starts_with("completed"))
                    && !open_issues.iter().any(|i| i.number == entry.issue_number)
                {
                    let elapsed_str = entry
                        .started_at
                        .as_deref()
                        .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                        .and_then(|start| {
                            chrono::DateTime::parse_from_rfc3339(&entry.timestamp)
                                .ok()
                                .map(|end| format_elapsed((end - start).num_seconds()))
                        })
                        .unwrap_or_default();
                    col_done.push(Line::from(vec![
                        Span::styled(
                            format!("#{}", entry.issue_number),
                            Style::default().fg(Color::Green).add_modifier(Modifier::BOLD),
                        ),
                        Span::raw(format!(" {}", truncate_title(&entry.issue_title, 20))),
                    ]));
                    if !elapsed_str.is_empty() {
                        col_done.push(Line::from(Span::styled(
                            format!("  ⏱ {elapsed_str}"),
                            Style::default().fg(Color::Green),
                        )));
                    }
                    col_done.push(Line::from(""));
                }
            }

            // Count items per column (non-empty lines, excluding spacers)
            let count_open = open_issues
                .iter()
                .filter(|i| {
                    !in_progress.contains(&i.number)
                        && !history.iter().any(|e| {
                            e.issue_number == i.number
                                && (e.outcome.starts_with("success")
                                    || e.outcome.starts_with("completed"))
                        })
                })
                .count();
            let count_running = in_progress.len();
            let count_done = col_done.iter().filter(|l| !l.spans.is_empty() && l.spans[0].content.starts_with('#')).count();

            // Layout: header, kanban board, sessions, log, footer
            let fixed = 3 + 8 + 1; // header + sessions + footer
            let flexible = area.height.saturating_sub(fixed as u16);
            let board_h = (flexible * 50 / 100).max(6);
            let log_h = flexible.saturating_sub(board_h).max(4);

            let chunks = Layout::default()
                .direction(Direction::Vertical)
                .constraints([
                    Constraint::Length(3),        // header
                    Constraint::Length(board_h),   // kanban board
                    Constraint::Length(8),         // tmux sessions
                    Constraint::Length(log_h),     // log
                    Constraint::Length(1),         // footer
                ])
                .split(area);

            // Header
            let poll_info = format!(
                " {} | last: {} | next: {} | active: {} ",
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

            // Kanban board: 3 columns
            let board_cols = Layout::default()
                .direction(Direction::Horizontal)
                .constraints([
                    Constraint::Percentage(33),
                    Constraint::Percentage(34),
                    Constraint::Percentage(33),
                ])
                .split(chunks[1]);

            // Empty state fallback
            if col_open.is_empty() {
                col_open.push(Line::from(Span::styled(
                    "No issues",
                    Style::default().fg(Color::DarkGray),
                )));
            }
            if col_running.is_empty() {
                col_running.push(Line::from(Span::styled(
                    "No active sessions",
                    Style::default().fg(Color::DarkGray),
                )));
            }
            if col_done.is_empty() {
                col_done.push(Line::from(Span::styled(
                    "No completed issues",
                    Style::default().fg(Color::DarkGray),
                )));
            }

            let open_panel = Paragraph::new(col_open)
                .block(
                    Block::default()
                        .title(format!(" ○ Open ({count_open}) "))
                        .borders(Borders::ALL)
                        .border_style(Style::default().fg(Color::White)),
                )
                .wrap(Wrap { trim: true });
            f.render_widget(open_panel, board_cols[0]);

            let running_panel = Paragraph::new(col_running)
                .block(
                    Block::default()
                        .title(format!(" ⚙ Running ({count_running}) "))
                        .borders(Borders::ALL)
                        .border_style(Style::default().fg(Color::Yellow)),
                )
                .wrap(Wrap { trim: true });
            f.render_widget(running_panel, board_cols[1]);

            let done_panel = Paragraph::new(col_done)
                .block(
                    Block::default()
                        .title(format!(" ✓ Done ({count_done}) "))
                        .borders(Borders::ALL)
                        .border_style(Style::default().fg(Color::Green)),
                )
                .wrap(Wrap { trim: true });
            f.render_widget(done_panel, board_cols[2]);

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
                    Constraint::Length(16),
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
                KeyCode::Char('p') => {
                    app.poll_notify.notify_one();
                }
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
