use std::collections::HashMap;
use std::sync::Arc;

use rmcp::model::{JsonObject, ListToolsResult, Tool};
use serde_json::json;

use crate::types::AgentDefinition;

/// Build the AgentFallback tool definition with dynamic subagent_type enum.
pub fn build_agent_fallback_tool(agents: &HashMap<String, AgentDefinition>) -> Tool {
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
            "description": "Run the agent in the background; returns immediately with a taskId. Use AgentFallbackStatus to check progress."
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
        "AgentFallback",
        "FALLBACK AGENT SPAWNER — Only use this tool from within subagents that do NOT have access to the built-in Agent tool. If you have access to the built-in Agent tool (check your tool list), ALWAYS prefer that instead. This tool exists solely to give nested subagents the ability to spawn further subagents.\n\nUsage notes:\n1. Launch multiple agents concurrently whenever possible, to maximize performance; to do that, use a single message with multiple tool uses\n2. When the agent is done, it will return a single message back to you. The result returned by the agent is not visible to the user. To show the user the result, you should send a text message back to the user with a concise summary of the result.\n3. Each agent invocation is stateless. You will not be able to send additional messages to the agent, nor will the agent be able to communicate with you outside of its final report. Therefore, your prompt should contain a highly detailed task description for the agent to perform autonomously and you should specify exactly what information the agent should return back to you in its final and only message to you.\n4. The agent's outputs should generally be trusted\n5. IMPORTANT: The spawned agent runs as a fresh process with its own 200k context window and CAN use the AgentFallback tool.",
        Arc::new(input_schema),
    )
}

/// Build the AgentFallbackStatus tool definition.
pub fn build_agent_fallback_status_tool() -> Tool {
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
        "AgentFallbackStatus",
        "Check the status of a background agent started with run_in_background: true. Returns the current status and, once completed, the full result.",
        Arc::new(input_schema),
    )
}

/// Build the ListToolsResult with AgentFallback and AgentFallbackStatus tools.
pub fn build_list_tools_result(agents: &HashMap<String, AgentDefinition>) -> ListToolsResult {
    ListToolsResult {
        meta: None,
        next_cursor: None,
        tools: vec![
            build_agent_fallback_tool(agents),
            build_agent_fallback_status_tool(),
        ],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_build_agent_fallback_tool_no_agents() {
        let agents = HashMap::new();
        let tool = build_agent_fallback_tool(&agents);
        assert_eq!(tool.name, "AgentFallback");
        assert!(tool.description.is_some());
        let schema = tool.schema_as_json_value();
        let props = schema["properties"].as_object().unwrap();
        assert!(props.contains_key("prompt"));
        assert!(props.contains_key("model"));
        assert!(!props.contains_key("subagent_type"));
    }

    #[test]
    fn test_build_agent_fallback_tool_with_agents() {
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
        let tool = build_agent_fallback_tool(&agents);
        let schema = tool.schema_as_json_value();
        let props = schema["properties"].as_object().unwrap();
        assert!(props.contains_key("subagent_type"));
        let enum_vals = props["subagent_type"]["enum"].as_array().unwrap();
        assert!(enum_vals.contains(&json!("looper:planner")));
    }

    #[test]
    fn test_build_agent_fallback_status_tool() {
        let tool = build_agent_fallback_status_tool();
        assert_eq!(tool.name, "AgentFallbackStatus");
        let schema = tool.schema_as_json_value();
        let props = schema["properties"].as_object().unwrap();
        assert!(props.contains_key("taskId"));
    }
}
