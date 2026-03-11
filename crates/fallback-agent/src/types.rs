/// Agent definition discovered from filesystem agent files.
#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct AgentDefinition {
    pub name: String,
    /// Qualified name e.g. "looper:planner"
    pub qualified_name: String,
    pub description: String,
    pub tools: Option<Vec<String>>,
    pub disallowed_tools: Option<Vec<String>>,
    pub model: Option<String>,
    /// Markdown body after frontmatter — used as system prompt
    pub system_prompt: String,
}

/// A single message from the claude CLI `--output-format stream-json` output.
#[derive(Debug, serde::Deserialize)]
#[allow(dead_code)]
pub struct StreamMessage {
    #[serde(rename = "type")]
    pub msg_type: String,
    pub message: Option<StreamMessageBody>,
    pub session_id: Option<String>,
    pub result: Option<String>,
    pub is_error: Option<bool>,
    pub duration_ms: Option<f64>,
    pub total_cost_usd: Option<f64>,
    pub usage: Option<UsageInfo>,
    pub tool_use_result: Option<ToolUseResult>,
}

#[derive(Debug, serde::Deserialize)]
pub struct StreamMessageBody {
    pub content: Option<Vec<ContentBlock>>,
}

#[derive(Debug, serde::Deserialize)]
#[allow(dead_code)]
pub struct ContentBlock {
    #[serde(rename = "type")]
    pub block_type: String,
    pub text: Option<String>,
    pub name: Option<String>,
    pub id: Option<String>,
    pub input: Option<serde_json::Value>,
}

#[derive(Debug, Clone, serde::Deserialize)]
#[allow(dead_code)]
pub struct UsageInfo {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_input_tokens: Option<u64>,
    pub cache_creation_input_tokens: Option<u64>,
}

#[derive(Debug, serde::Deserialize)]
#[allow(dead_code)]
pub struct ToolUseResult {
    pub stdout: Option<String>,
    pub stderr: Option<String>,
    pub interrupted: Option<bool>,
}

/// User-facing task input (aligned with built-in Agent tool).
#[derive(Debug, serde::Deserialize, Default)]
#[allow(dead_code)]
pub struct TaskInput {
    pub prompt: Option<String>,
    pub description: Option<String>,
    pub name: Option<String>,
    pub model: Option<String>,
    pub mode: Option<String>,
    pub isolation: Option<String>,
    pub max_turns: Option<u32>,
    pub resume: Option<String>,
    pub run_in_background: Option<bool>,
    pub subagent_type: Option<String>,
}

/// Internal config passed to run_task.
#[derive(Debug, Clone)]
pub struct RunTaskConfig {
    pub prompt: String,
    pub name: Option<String>,
    pub model: String,
    pub mode: Option<String>,
    pub isolation: Option<String>,
    pub resume: Option<String>,
    pub max_turns: Option<u32>,
    /// Applied from agent definitions — not user-facing
    pub system_prompt: Option<String>,
    /// Applied from agent definitions — not user-facing
    pub disallowed_tools: Option<Vec<String>>,
    pub working_dir: String,
    pub timeout_ms: u64,
}

/// Result returned from run_task.
#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct TaskResult {
    pub success: bool,
    pub result: Option<String>,
    pub error: Option<String>,
    pub session_id: Option<String>,
    pub usage: Option<UsageInfo>,
    pub tool_use_count: u32,
    pub duration_ms: u64,
    pub tokens: u64,
    pub tool_outputs: Vec<ToolOutput>,
}

#[derive(Debug, Clone)]
pub struct ToolOutput {
    pub tool: String,
    pub output: String,
}

/// Status of a background task.
#[derive(Debug, Clone, PartialEq)]
pub enum BackgroundTaskStatus {
    Running,
    Completed,
    Error,
}

/// A background task entry.
#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct BackgroundTask {
    pub task_id: String,
    pub status: BackgroundTaskStatus,
    pub result: Option<TaskResult>,
}

/// Progress state tracked while running a task.
pub struct ProgressState {
    pub tool_use_count: u32,
    pub assistant_turn_count: u32,
    pub current_tool_use: Option<String>,
    pub start_time: std::time::Instant,
    pub tool_outputs: Vec<ToolOutput>,
    pub session_id: Option<String>,
}

impl ProgressState {
    pub fn new() -> Self {
        Self {
            tool_use_count: 0,
            assistant_turn_count: 0,
            current_tool_use: None,
            start_time: std::time::Instant::now(),
            tool_outputs: Vec::new(),
            session_id: None,
        }
    }

    pub fn elapsed_ms(&self) -> u64 {
        self.start_time.elapsed().as_millis() as u64
    }
}

impl UsageInfo {
    pub fn total_tokens(&self) -> u64 {
        self.input_tokens
            + self.output_tokens
            + self.cache_read_input_tokens.unwrap_or(0)
            + self.cache_creation_input_tokens.unwrap_or(0)
    }
}
