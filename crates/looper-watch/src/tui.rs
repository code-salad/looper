use std::io;
use std::time::Duration;

use crossterm::event::{self, Event, KeyCode, KeyModifiers};
use crossterm::execute;
use crossterm::terminal::{EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode};
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Constraint, Direction, Layout};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Cell, Paragraph, Row, Table, Wrap};
use ratatui::Terminal;

use crate::state::State;
use crate::worker::AppState;

pub async fn run_tui(app: AppState, repo: &str) -> io::Result<()> {
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    let repo = repo.to_string();

    loop {
        // Draw
        let log_lines = app.log_lines.lock().await.clone();
        let last_poll = app.last_poll.lock().await.clone();
        let next_poll = app.next_poll.lock().await.clone();
        let open_issues = app.open_issues.lock().await.clone();
        let state: State = {
            let s = app.state.lock().await;
            State {
                in_progress: s.in_progress.clone(),
                history: s.history.clone(),
            }
        };

        let tmux_sessions = list_tmux_sessions().await;

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
                " {} | last poll: {} | next poll: {} | in-progress: {} ",
                repo,
                last_poll.as_deref().unwrap_or("—"),
                next_poll.as_deref().unwrap_or("—"),
                state.in_progress.len(),
            );
            let header = Paragraph::new(Line::from(vec![
                Span::styled("looper-watch", Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD)),
                Span::raw(poll_info),
            ]))
            .block(Block::default().borders(Borders::ALL));
            f.render_widget(header, chunks[0]);

            // Issues table
            let header_row = Row::new(["#", "Title", "Status", "Labels"])
                .style(Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD));

            let rows: Vec<Row> = open_issues
                .iter()
                .map(|issue| {
                    let status = if state.in_progress.contains(&issue.number) {
                        Span::styled("⚙ running", Style::default().fg(Color::Yellow))
                    } else if state.history.iter().any(|e| e.issue_number == issue.number && e.outcome == "success") {
                        Span::styled("✓ done", Style::default().fg(Color::Green))
                    } else {
                        Span::styled("○ open", Style::default().fg(Color::White))
                    };
                    let labels: String = issue.labels.iter().map(|l| l.name.as_str()).collect::<Vec<_>>().join(", ");
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
                        Cell::from("tmux attach -t <name>"),
                    ])
                })
                .collect();
            let session_table = Table::new(
                session_rows,
                [Constraint::Length(30), Constraint::Min(30)],
            )
            .header(Row::new(["Session", "Attach command"]).style(Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD)))
            .block(Block::default().title(" Claude Sessions (tmux) ").borders(Borders::ALL));
            f.render_widget(session_table, chunks[2]);

            // Log
            let visible_lines: Vec<Line> = log_lines
                .iter()
                .rev()
                .take(chunks[3].height as usize - 2)
                .rev()
                .map(|l| Line::from(l.as_str()))
                .collect();
            let log_widget = Paragraph::new(visible_lines)
                .block(Block::default().title(" Log ").borders(Borders::ALL))
                .wrap(Wrap { trim: false });
            f.render_widget(log_widget, chunks[3]);

            // Footer
            let footer = Paragraph::new(Line::from(vec![
                Span::styled(" q", Style::default().fg(Color::Red).add_modifier(Modifier::BOLD)),
                Span::raw(" quit  "),
                Span::styled("p", Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD)),
                Span::raw(" force poll  "),
            ]));
            f.render_widget(footer, chunks[4]);
        })?;

        // Handle input (non-blocking)
        if event::poll(Duration::from_millis(250))? {
            if let Event::Key(key) = event::read()? {
                match key.code {
                    KeyCode::Char('q') => break,
                    KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => break,
                    _ => {}
                }
            }
        }
    }

    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen)?;
    Ok(())
}

async fn list_tmux_sessions() -> Vec<String> {
    let output = tokio::process::Command::new("tmux")
        .args(["list-sessions", "-F", "#{session_name}"])
        .output()
        .await;

    match output {
        Ok(o) if o.status.success() => {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .filter(|l| l.starts_with("looper-"))
                .map(|l| l.to_string())
                .collect()
        }
        _ => vec![],
    }
}
