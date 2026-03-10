use std::sync::Arc;

use rmcp::model::{JsonObject, ListToolsResult, Tool};
use serde_json::json;

fn build_list_watchers_tool() -> Tool {
    let input_schema: JsonObject = {
        let mut schema = serde_json::Map::new();
        schema.insert("type".to_string(), json!("object"));
        schema.insert(
            "properties".to_string(),
            json!({}),
        );
        schema
    };

    Tool::new(
        "list_watchers",
        "List all running GitHub issue watchers. Returns each watcher's ID, repo, status, interval, and issue processing stats.",
        Arc::new(input_schema),
    )
}

fn build_setup_watcher_tool() -> Tool {
    let input_schema: JsonObject = {
        let mut schema = serde_json::Map::new();
        schema.insert("type".to_string(), json!("object"));
        schema.insert(
            "properties".to_string(),
            json!({
                "repo": {
                    "type": "string",
                    "description": "GitHub repository in 'owner/repo' format"
                },
                "interval_minutes": {
                    "type": "number",
                    "description": "Polling interval in minutes (default: 10)",
                    "default": 10
                }
            }),
        );
        schema.insert("required".to_string(), json!(["repo"]));
        schema
    };

    Tool::new(
        "setup_watcher",
        "Start a watcher that polls a GitHub repo for open, unassigned, non-blocked issues. When an issue is found, it is claimed and fed to 'claude -p /looper-ee <issue_url>'.",
        Arc::new(input_schema),
    )
}

fn build_kill_all_watchers_tool() -> Tool {
    let input_schema: JsonObject = {
        let mut schema = serde_json::Map::new();
        schema.insert("type".to_string(), json!("object"));
        schema.insert("properties".to_string(), json!({}));
        schema
    };

    Tool::new(
        "kill_all_watchers",
        "Stop and remove all running watchers.",
        Arc::new(input_schema),
    )
}

fn build_get_watcher_history_tool() -> Tool {
    let input_schema: JsonObject = {
        let mut schema = serde_json::Map::new();
        schema.insert("type".to_string(), json!("object"));
        schema.insert(
            "properties".to_string(),
            json!({
                "repo": {
                    "type": "string",
                    "description": "Optional: filter history by repo ('owner/repo'). Omit to get all history."
                }
            }),
        );
        schema
    };

    Tool::new(
        "get_watcher_history",
        "Get the history of issues processed by watchers. Each entry shows the repo, issue number, title, timestamp, and outcome.",
        Arc::new(input_schema),
    )
}

pub fn build_list_tools_result() -> ListToolsResult {
    ListToolsResult {
        meta: None,
        next_cursor: None,
        tools: vec![
            build_list_watchers_tool(),
            build_setup_watcher_tool(),
            build_kill_all_watchers_tool(),
            build_get_watcher_history_tool(),
        ],
    }
}
