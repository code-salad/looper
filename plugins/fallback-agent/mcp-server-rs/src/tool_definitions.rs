use std::collections::HashMap;
use std::sync::Arc;

use rmcp::model::{JsonObject, ListToolsResult, Tool};
use serde_json::json;

use crate::types::AgentDefinition;

/// Build the Task tool definition with dynamic subagent_type enum.
pub fn build_task_tool(agents: &HashMap<String, AgentDefinition>) -> Tool {
    let mut properties = serde_json::Map::new();

    properties.insert(
        "prompt".to_string(),
        json!({
            "type": "string",
            "description": "The task for the agent to perform"
        }),
    );
    properties.insert(
        "description".to_string(),
        json!({
            "type": "string",
            "description": "A short (3-5 word) description of the task"
        }),
    );
    properties.insert(
        "name".to_string(),
        json!({
            "type": "string",
            "description": "Agent name for identification in logs and results"
        }),
    );
    properties.insert(
        "model".to_string(),
        json!({
            "type": "string",
            "enum": ["sonnet", "opus", "haiku"],
            "default": "sonnet",
            "description": "Model to use (default: sonnet)"
        }),
    );
    properties.insert(
        "mode".to_string(),
        json!({
            "type": "string",
            "enum": ["default", "acceptEdits", "bypassPermissions", "dontAsk", "plan"],
            "description": "Permission mode for the spawned subagent"
        }),
    );
    properties.insert(
        "isolation".to_string(),
        json!({
            "type": "string",
            "enum": ["worktree"],
            "description": "When \"worktree\": run the agent in a temporary git worktree"
        }),
    );
    properties.insert(
        "max_turns".to_string(),
        json!({
            "type": "number",
            "description": "Maximum number of agentic turns (API round-trips) before stopping",
            "exclusiveMinimum": 0
        }),
    );
    properties.insert(
        "resume".to_string(),
        json!({
            "type": "string",
            "description": "Session ID to resume from a previous invocation"
        }),
    );
    properties.insert(
        "run_in_background".to_string(),
        json!({
            "type": "boolean",
            "description": "Run the task in the background; returns immediately with a taskId. Use TaskStatus to check progress."
        }),
    );

    // Add subagent_type enum if agents were discovered
    if !agents.is_empty() {
        let agent_keys: Vec<serde_json::Value> = agents
            .keys()
            .map(|k| serde_json::Value::String(k.clone()))
            .collect();
        let agent_list = agents
            .iter()
            .map(|(k, v)| format!("\"{}\" — {}", k, v.description))
            .collect::<Vec<_>>()
            .join("\n");

        properties.insert(
            "subagent_type".to_string(),
            json!({
                "type": "string",
                "enum": agent_keys,
                "description": format!(
                    "Specialized agent type. Applies the agent's system prompt, tool restrictions, and model from its definition file. Explicit parameters override agent defaults.\n\nAvailable agents:\n{}",
                    agent_list
                )
            }),
        );
    }

    let input_schema: JsonObject = {
        let mut schema = serde_json::Map::new();
        schema.insert("type".to_string(), json!("object"));
        schema.insert(
            "properties".to_string(),
            serde_json::Value::Object(properties),
        );
        schema.insert("required".to_string(), json!(["prompt"]));
        schema
    };

    Tool::new(
        "Task",
        "Launch a new agent that has access to all tools including Task. When you are searching for a keyword or file and are not confident that you will find the right match on the first try, use the Agent tool to perform the search for you. For example:\n\n- If you are searching for a keyword like \"config\" or \"logger\", the Agent tool is appropriate\n- If you want to read a specific file path, use the Read or Glob tool instead of the Agent tool, to find the match more quickly\n- If you are searching for a specific class definition like \"class Foo\", use the Glob tool instead, to find the match more quickly\n\nUsage notes:\n1. Launch multiple agents concurrently whenever possible, to maximize performance; to do that, use a single message with multiple tool uses\n2. When the agent is done, it will return a single message back to you. The result returned by the agent is not visible to the user. To show the user the result, you should send a text message back to the user with a concise summary of the result.\n3. Each agent invocation is stateless. You will not be able to send additional messages to the agent, nor will the agent be able to communicate with you outside of its final report. Therefore, your prompt should contain a highly detailed task description for the agent to perform autonomously and you should specify exactly what information the agent should return back to you in its final and only message to you.\n4. The agent's outputs should generally be trusted\n5. IMPORTANT: The spawned agent runs as a fresh process with its own 200k context window and CAN use the Task tool.",
        Arc::new(input_schema),
    )
}

/// Build the TaskStatus tool definition.
pub fn build_task_status_tool() -> Tool {
    let mut properties = serde_json::Map::new();
    properties.insert(
        "taskId".to_string(),
        json!({
            "type": "string",
            "description": "The task ID returned when the background task was started"
        }),
    );

    let input_schema: JsonObject = {
        let mut schema = serde_json::Map::new();
        schema.insert("type".to_string(), json!("object"));
        schema.insert(
            "properties".to_string(),
            serde_json::Value::Object(properties),
        );
        schema.insert("required".to_string(), json!(["taskId"]));
        schema
    };

    Tool::new(
        "TaskStatus",
        "Check the status of a background task started with run_in_background: true. Returns the current status and, once completed, the full result.",
        Arc::new(input_schema),
    )
}

/// Build the ListToolsResult with Task and TaskStatus tools.
pub fn build_list_tools_result(agents: &HashMap<String, AgentDefinition>) -> ListToolsResult {
    ListToolsResult {
        meta: None,
        next_cursor: None,
        tools: vec![build_task_tool(agents), build_task_status_tool()],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_build_task_tool_no_agents() {
        let agents = HashMap::new();
        let tool = build_task_tool(&agents);
        assert_eq!(tool.name, "Task");
        assert!(tool.description.is_some());
        let schema = tool.schema_as_json_value();
        let props = schema["properties"].as_object().unwrap();
        assert!(props.contains_key("prompt"));
        assert!(props.contains_key("model"));
        assert!(!props.contains_key("subagent_type"));
    }

    #[test]
    fn test_build_task_tool_with_agents() {
        let mut agents = HashMap::new();
        agents.insert(
            "looper:planner".to_string(),
            AgentDefinition {
                name: "planner".to_string(),
                qualified_name: "looper:planner".to_string(),
                description: "Plans things".to_string(),
                tools: None,
                disallowed_tools: None,
                model: Some("sonnet".to_string()),
                system_prompt: "".to_string(),
            },
        );
        let tool = build_task_tool(&agents);
        let schema = tool.schema_as_json_value();
        let props = schema["properties"].as_object().unwrap();
        assert!(props.contains_key("subagent_type"));
        let enum_vals = props["subagent_type"]["enum"].as_array().unwrap();
        assert!(enum_vals.contains(&json!("looper:planner")));
    }

    #[test]
    fn test_build_task_status_tool() {
        let tool = build_task_status_tool();
        assert_eq!(tool.name, "TaskStatus");
        let schema = tool.schema_as_json_value();
        let props = schema["properties"].as_object().unwrap();
        assert!(props.contains_key("taskId"));
    }
}
