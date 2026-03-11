use std::io;
use std::path::Path;
use std::time::Duration;

use crossterm::event::{self, Event, KeyCode, KeyModifiers};
use crossterm::execute;
use crossterm::terminal::{
    EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode,
};
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Constraint, Direction, Layout};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Cell, Paragraph, Row, Table, Wrap};
use ratatui::Terminal;

use crate::state;
use crate::worker::{self, AppState};

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
        let tmux_sessions = state::list_repo_sessions(&repo).await;

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
                    let status = if in_progress.contains(&issue.number) {
                        Span::styled("⚙ running", Style::default().fg(Color::Yellow))
                    } else if history.iter().any(|e| {
                        e.issue_number == issue.number
                            && (e.outcome.starts_with("success")
                                || e.outcome.starts_with("completed"))
                    }) {
                        Span::styled("✓ done", Style::default().fg(Color::Green))
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
                        Cell::from(status),
                        Cell::from(labels),
                    ])
                })
                .collect();

            let table = Table::new(
                rows,
                [
                    Constraint::Length(6),
                    Constraint::Min(30),
                    Constraint::Length(12),
                    Constraint::Length(20),
                ],
            )
            .header(header_row)
            .block(Block::default().title(" Issues ").borders(Borders::ALL));
            f.render_widget(table, chunks[1]);

            // Tmux sessions
            let session_rows: Vec<Row> = tmux_sessions
                .iter()
                .map(|s| {
                    Row::new(vec![
                        Cell::from(s.as_str()),
                        Cell::from(format!("tmux attach -t {s}")),
                    ])
                })
                .collect();
            let session_table = Table::new(
                session_rows,
                [Constraint::Length(40), Constraint::Min(30)],
            )
            .header(
                Row::new(["Session", "Attach command"]).style(
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
                    Style::default()
                        .fg(Color::Red)
                        .add_modifier(Modifier::BOLD),
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
                    Style::default()
                        .fg(Color::Red)
                        .add_modifier(Modifier::BOLD),
                ),
                Span::raw(" kill all sessions"),
            ]));
            f.render_widget(footer, chunks[4]);
        })?;

        // Handle input (non-blocking)
        if event::poll(Duration::from_millis(250))? {
            if let Event::Key(key) = event::read()? {
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
    }

    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen)?;
    Ok(())
}
