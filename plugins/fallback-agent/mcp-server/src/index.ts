/**
 * Fallback Agent MCP Server - Streaming Edition
 *
 * This MCP server provides a fallback agent by spawning fresh Claude processes
 * with REAL-TIME progress streaming using MCP progress notifications.
 *
 * KEY FEATURES:
 * - Uses `claude -p --output-format stream-json --verbose` for real-time streaming
 * - Emits MCP progress notifications for each tool use
 * - Supports abort via SIGTERM (graceful) and SIGKILL (forced)
 * - API aligned with built-in Agent tool (minus team features)
 *
 * Architecture:
 * ```
 * Main Plugin Session
 *     └── MCP Tool: Task({prompt, progressToken})
 *             │
 *             ├── Spawns: claude -p --output-format stream-json --verbose
 *             │
 *             ├── Parses streaming JSON line by line
 *             │
 *             ├── Emits: notifications/progress for each tool_use
 *             │
 *             └── Returns final result when complete
 * ```
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  Tool,
} from "@modelcontextprotocol/sdk/types.js";
import { spawn, ChildProcess } from "child_process";
import { createInterface } from "readline";
import { appendFileSync, writeFileSync, readFileSync, readdirSync, existsSync, statSync } from "fs";
import { join, resolve, basename } from "path";

// Debug logging to file - use /tmp for reliable access
const LOG_FILE = "/tmp/fallback-agent-debug.log";
function log(message: string) {
  const timestamp = new Date().toISOString();
  const logLine = `[${timestamp}] ${message}\n`;
  try {
    appendFileSync(LOG_FILE, logLine);
  } catch {
    // Ignore logging errors
  }
}

// Initialize log file
try {
  writeFileSync(LOG_FILE, `=== Fallback Agent MCP Server Started ===\n`);
  appendFileSync(LOG_FILE, `CLAUDE_PLUGIN_ROOT=${process.env.CLAUDE_PLUGIN_ROOT || '(not set)'}\n`);
} catch {
  // Ignore
}

// ── Agent Definition Discovery ──────────────────────────────────────────────

interface AgentDefinition {
  name: string;
  qualifiedName: string; // e.g., "looper:planner"
  description: string;
  tools?: string[];
  disallowedTools?: string[];
  model?: "sonnet" | "opus" | "haiku";
  systemPrompt: string; // markdown body after frontmatter
}

/** Tools that require write access — used to enforce read-only agents. */
const WRITE_TOOLS = ["Write", "Edit", "NotebookEdit"];

/**
 * Parse YAML frontmatter and markdown body from an agent definition file.
 * Handles simple `key: value` pairs and comma-separated lists.
 */
function parseAgentFile(content: string, namespace: string): AgentDefinition | null {
  if (!content.startsWith("---")) return null;

  const endIdx = content.indexOf("\n---", 3);
  if (endIdx === -1) return null;

  const frontmatter = content.slice(4, endIdx); // skip opening '---\n'
  const body = content.slice(endIdx + 4).trim(); // skip closing '\n---\n'

  const meta: Record<string, string> = {};
  for (const line of frontmatter.split("\n")) {
    const colonIdx = line.indexOf(":");
    if (colonIdx === -1) continue;
    const key = line.slice(0, colonIdx).trim();
    const value = line.slice(colonIdx + 1).trim();
    if (key && value) meta[key] = value;
  }

  if (!meta.name) return null;

  const parseList = (s?: string): string[] | undefined =>
    s ? s.split(",").map((t) => t.trim()).filter(Boolean) : undefined;

  const qualifiedName = namespace ? `${namespace}:${meta.name}` : meta.name;
  const model = (["sonnet", "opus", "haiku"].includes(meta.model) ? meta.model : undefined) as
    | AgentDefinition["model"]
    | undefined;

  return {
    name: meta.name,
    qualifiedName,
    description: meta.description || "",
    tools: parseList(meta.tools),
    disallowedTools: parseList(meta.disallowedTools),
    model,
    systemPrompt: body,
  };
}

/**
 * Read the plugin name from `.claude-plugin/plugin.json`, falling back to the
 * directory basename.
 */
function getPluginNamespace(pluginDir: string): string {
  try {
    const pj = JSON.parse(readFileSync(join(pluginDir, ".claude-plugin", "plugin.json"), "utf-8"));
    if (pj.name) return pj.name;
  } catch {
    // fall through
  }
  return basename(resolve(pluginDir));
}

/**
 * Check if a directory is a plugin root (has .claude-plugin/plugin.json).
 */
function isPluginDir(dir: string): boolean {
  return existsSync(join(dir, ".claude-plugin", "plugin.json"));
}

/**
 * Discover agent definitions by scanning:
 *   1. CLAUDE_PLUGIN_ROOT/agents/*.md  (own plugin)
 *   2. Sibling plugins — handles both flat and versioned cache layouts:
 *      - Flat:  plugins/<this-plugin>/  → plugins/<sibling>/agents/
 *      - Cache: cache/<repo>/<this-plugin>/<ver>/ → cache/<repo>/<sibling>/<ver>/agents/
 */
function discoverAgents(): Map<string, AgentDefinition> {
  const agents = new Map<string, AgentDefinition>();
  const pluginRoot = process.env.CLAUDE_PLUGIN_ROOT;

  if (!pluginRoot) {
    log("No CLAUDE_PLUGIN_ROOT set — skipping agent discovery");
    return agents;
  }

  const scanTargets: Array<[string, string]> = [];
  const visited = new Set<string>([resolve(pluginRoot)]);

  // 1. Own plugin agents
  const ownAgentsDir = join(pluginRoot, "agents");
  if (existsSync(ownAgentsDir) && statSync(ownAgentsDir).isDirectory()) {
    scanTargets.push([ownAgentsDir, getPluginNamespace(pluginRoot)]);
  }

  /**
   * Try to add a plugin directory's agents/ to scan targets.
   * Skips if already visited or if it's the current plugin.
   */
  function addPluginAgents(pluginDir: string) {
    const resolved = resolve(pluginDir);
    if (visited.has(resolved)) return;
    visited.add(resolved);
    const agentsDir = join(pluginDir, "agents");
    if (existsSync(agentsDir) && statSync(agentsDir).isDirectory()) {
      scanTargets.push([agentsDir, getPluginNamespace(pluginDir)]);
      log(`Found sibling agents: ${agentsDir}`);
    }
  }

  /**
   * Scan a directory for sibling plugins. Each child entry may be:
   *   - A plugin directory (has .claude-plugin/plugin.json)  → flat layout
   *   - A versioned directory containing plugin subdirs       → cache layout
   */
  function scanForSiblings(dir: string) {
    try {
      for (const entry of readdirSync(dir)) {
        const entryPath = join(dir, entry);
        if (!statSync(entryPath).isDirectory()) continue;

        // Direct plugin sibling (flat layout)
        if (isPluginDir(entryPath)) {
          addPluginAgents(entryPath);
          continue;
        }

        // Versioned plugin sibling (cache layout) — scan subdirs for plugin roots
        // e.g., looper/0.11.1/.claude-plugin/plugin.json
        try {
          for (const sub of readdirSync(entryPath)) {
            const subPath = join(entryPath, sub);
            if (statSync(subPath).isDirectory() && isPluginDir(subPath)) {
              addPluginAgents(subPath);
            }
          }
        } catch {
          // ignore
        }
      }
    } catch (err) {
      log(`Error scanning for siblings in ${dir}: ${err}`);
    }
  }

  // 2. Scan parent (flat layout: plugins/<name>/) and grandparent (cache: cache/<repo>/<name>/<ver>/)
  const parent = resolve(pluginRoot, "..");
  const grandparent = resolve(pluginRoot, "../..");

  scanForSiblings(parent);
  scanForSiblings(grandparent);

  // 3. Parse agent files from all discovered directories
  for (const [dir, namespace] of scanTargets) {
    try {
      for (const file of readdirSync(dir).filter((f) => f.endsWith(".md"))) {
        try {
          const content = readFileSync(join(dir, file), "utf-8");
          const agent = parseAgentFile(content, namespace);
          if (agent) {
            agents.set(agent.qualifiedName, agent);
            log(`Discovered agent: ${agent.qualifiedName} (${join(dir, file)})`);
          }
        } catch (err) {
          log(`Error parsing agent file ${join(dir, file)}: ${err}`);
        }
      }
    } catch (err) {
      log(`Error scanning agent directory ${dir}: ${err}`);
    }
  }

  return agents;
}

/**
 * Compute effective disallowed tools for an agent definition.
 * Uses explicit `disallowedTools` and supplements by blocking write tools
 * that are absent from the `tools` allowlist.
 */
function computeEffectiveDisallowedTools(agent: AgentDefinition): string[] {
  const disallowed = new Set(agent.disallowedTools ?? []);
  if (agent.tools?.length) {
    for (const tool of WRITE_TOOLS) {
      if (!agent.tools.includes(tool)) {
        disallowed.add(tool);
      }
    }
  }
  return [...disallowed];
}

// Run agent discovery at startup
const agentDefinitions = discoverAgents();
log(`Discovered ${agentDefinitions.size} agent definition(s): ${[...agentDefinitions.keys()].join(", ") || "(none)"}`);

// Types for Claude CLI stream-json output
interface StreamMessage {
  type: "system" | "assistant" | "user" | "result";
  subtype?: string;
  message?: {
    content: Array<{
      type: "text" | "tool_use" | "tool_result";
      text?: string;
      name?: string;
      id?: string;
      input?: Record<string, unknown>;
      content?: string;
    }>;
  };
  session_id?: string;
  uuid?: string;
  result?: string;
  is_error?: boolean;
  duration_ms?: number;
  total_cost_usd?: number;
  usage?: {
    input_tokens: number;
    output_tokens: number;
    cache_read_input_tokens?: number;
    cache_creation_input_tokens?: number;
  };
  tool_use_result?: {
    stdout?: string;
    stderr?: string;
    interrupted?: boolean;
  };
}

// ── Tool Definitions ────────────────────────────────────────────────────────

// Build Task tool definition — API aligned with built-in Agent tool (minus team features)
function buildToolDefinition(): Tool {
  const properties: Record<string, object> = {
    prompt: {
      type: "string",
      description: "The task for the agent to perform",
    },
    description: {
      type: "string",
      description: "A short (3-5 word) description of the task",
    },
    name: {
      type: "string",
      description: "Agent name for identification in logs and results",
    },
    model: {
      type: "string",
      enum: ["sonnet", "opus", "haiku"],
      default: "sonnet",
      description: "Model to use (default: sonnet)",
    },
    mode: {
      type: "string",
      enum: ["default", "acceptEdits", "bypassPermissions", "dontAsk", "plan"],
      description: "Permission mode for the spawned subagent",
    },
    isolation: {
      type: "string",
      enum: ["worktree"],
      description: 'When "worktree": run the agent in a temporary git worktree',
    },
    max_turns: {
      type: "number",
      description: "Maximum number of agentic turns (API round-trips) before stopping",
      exclusiveMinimum: 0,
    },
    resume: {
      type: "string",
      description: "Session ID to resume from a previous invocation",
    },
    run_in_background: {
      type: "boolean",
      description: "Run the task in the background; returns immediately with a taskId. Use TaskStatus to check progress.",
    },
  };

  // Add subagent_type enum if agents were discovered
  if (agentDefinitions.size > 0) {
    const agentList = [...agentDefinitions.entries()]
      .map(([k, v]) => `"${k}" — ${v.description}`)
      .join("\n");
    properties.subagent_type = {
      type: "string",
      enum: [...agentDefinitions.keys()],
      description: `Specialized agent type. Applies the agent's system prompt, tool restrictions, and model from its definition file. Explicit parameters override agent defaults.\n\nAvailable agents:\n${agentList}`,
    };
  }

  return {
    name: "Task",
    description: `FALLBACK AGENT SPAWNER — Only use this tool from within subagents that do NOT have access to the built-in Agent tool. If you have access to the built-in Agent tool (check your tool list), ALWAYS prefer that instead. This tool exists solely to give nested subagents the ability to spawn further subagents.

Usage notes:
1. Launch multiple agents concurrently whenever possible, to maximize performance; to do that, use a single message with multiple tool uses
2. When the agent is done, it will return a single message back to you. The result returned by the agent is not visible to the user. To show the user the result, you should send a text message back to the user with a concise summary of the result.
3. Each agent invocation is stateless. You will not be able to send additional messages to the agent, nor will the agent be able to communicate with you outside of its final report. Therefore, your prompt should contain a highly detailed task description for the agent to perform autonomously and you should specify exactly what information the agent should return back to you in its final and only message to you.
4. The agent's outputs should generally be trusted
5. IMPORTANT: The spawned agent runs as a fresh process with its own 200k context window and CAN use the Task tool.`,
    inputSchema: {
      type: "object" as const,
      properties,
      required: ["prompt"],
    },
  };
}

// Build TaskStatus tool definition for checking background tasks
function buildTaskStatusDefinition(): Tool {
  return {
    name: "TaskStatus",
    description: "Check the status of a background task started with run_in_background: true. Returns the current status and, once completed, the full result.",
    inputSchema: {
      type: "object" as const,
      properties: {
        taskId: {
          type: "string",
          description: "The task ID returned when the background task was started",
        },
      },
      required: ["taskId"],
    },
  };
}

// ── Types ───────────────────────────────────────────────────────────────────

// User-facing input (aligned with built-in Agent tool, minus team features)
interface TaskInput {
  prompt: string;
  description?: string;
  name?: string;
  model?: "sonnet" | "opus" | "haiku";
  mode?: "default" | "acceptEdits" | "bypassPermissions" | "dontAsk" | "plan";
  isolation?: "worktree";
  max_turns?: number;
  resume?: string;
  run_in_background?: boolean;
  subagent_type?: string;
}

// Internal config passed to runTask (includes agent-definition resolved fields)
interface RunTaskConfig {
  prompt: string;
  name?: string;
  model: string;
  mode?: string;
  isolation?: string;
  resume?: string;
  max_turns?: number;
  // Internal — applied from agent definitions, not user-facing
  systemPrompt?: string;
  disallowedTools?: string[];
  // Defaults applied by caller
  workingDir: string;
  timeout: number;
}

interface TaskResult {
  success: boolean;
  result?: string;
  error?: string;
  session_id?: string;
  usage?: object;
  toolUseCount?: number;
  duration?: number;
  tokens?: number;
  toolOutputs?: ToolOutput[];
}

interface ToolOutput {
  tool: string;
  output: string;
}

interface ProgressState {
  toolUseCount: number;
  assistantTurnCount: number;
  currentToolUse: string | null;
  startTime: number;
  toolOutputs: ToolOutput[];
  sessionId?: string;
}

interface BackgroundTask {
  taskId: string;
  status: "running" | "completed" | "error";
  result?: TaskResult;
}

const backgroundTasks = new Map<string, BackgroundTask>();

// ── Server ──────────────────────────────────────────────────────────────────

// Create MCP server
const server = new Server(
  {
    name: "fallback-agent",
    version: "3.0.0",
  },
  {
    capabilities: {
      tools: {},
    },
  }
);

// Track active processes for abort handling
const activeProcesses = new Map<string, ChildProcess>();

/**
 * Helper to format numbers with K/M suffixes
 */
function formatNumber(num: number): string {
  if (num >= 1000000) return (num / 1000000).toFixed(1) + 'M';
  if (num >= 1000) return (num / 1000).toFixed(1) + 'k';
  return num.toString();
}

/**
 * Helper to format duration
 */
function formatDuration(ms: number): string {
  if (ms < 1000) return `${ms}ms`;
  return `${(ms / 1000).toFixed(0)}s`;
}

/**
 * Format a TaskResult into display text.
 */
function formatTaskResult(result: TaskResult): string {
  if (!result.success) {
    const parts: string[] = [`Error: ${result.error}`];
    if (result.session_id) {
      parts.push(`session_id: ${result.session_id}`);
    }
    return parts.join("\n");
  }

  const toolUseText = result.toolUseCount === 1 ? '1 tool use' : `${result.toolUseCount ?? 0} tool uses`;
  const tokensText = formatNumber(result.tokens ?? 0) + ' tokens';
  const durationText = formatDuration(result.duration ?? 0);
  const summary = `Done (${toolUseText} · ${tokensText} · ${durationText})`;

  let toolOutputsText = '';
  if (result.toolOutputs && result.toolOutputs.length > 0) {
    toolOutputsText = result.toolOutputs
      .map(to => `[${to.tool}]\n${to.output}`)
      .join('\n\n');
  }

  const parts: string[] = [];
  if (toolOutputsText) parts.push(toolOutputsText);
  if (result.result) parts.push(result.result);
  if (result.session_id) parts.push(`session_id: ${result.session_id}`);
  parts.push(summary);

  return parts.join('\n\n');
}

// ── Task Runner ─────────────────────────────────────────────────────────────

/**
 * Spawns a nested task (fresh Claude process) with streaming output.
 */
async function runTask(
  config: RunTaskConfig,
  progressToken?: string | number,
): Promise<TaskResult> {
  const {
    prompt,
    name: agentName,
    model,
    mode,
    isolation,
    resume,
    max_turns,
    systemPrompt,
    disallowedTools,
    workingDir,
    timeout,
  } = config;

  const state: ProgressState = {
    toolUseCount: 0,
    assistantTurnCount: 0,
    currentToolUse: null,
    startTime: Date.now(),
    toolOutputs: [],
  };

  // Build CLI arguments
  const args: string[] = [
    "-p", prompt,
    "--output-format", "stream-json",
    "--verbose",
    "--model", model,
  ];

  // Permission mode
  if (mode) {
    args.push("--permission-mode", mode);
  }

  // Isolation via worktree
  if (isolation === "worktree") {
    args.push("--worktree");
  }

  // Resume session or disable persistence
  if (resume) {
    args.push("--resume", resume);
  } else {
    args.push("--no-session-persistence");
  }

  // System prompt (from agent definitions — not user-facing)
  if (systemPrompt) {
    args.push("--system-prompt", systemPrompt);
  }

  // Tool restrictions (from agent definitions — not user-facing)
  if (disallowedTools && disallowedTools.length > 0) {
    args.push("--disallowed-tools", ...disallowedTools);
  }

  // CRITICAL: Pass plugin directory so spawned process has access to the same plugins
  const pluginRoot = process.env.CLAUDE_PLUGIN_ROOT;
  if (pluginRoot) {
    args.push("--plugin-dir", pluginRoot);
  }

  return new Promise((resolvePromise) => {
    let lastResult: StreamMessage | null = null;
    let timedOut = false;
    let maxTurnsReached = false;
    const processId = `${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const label = agentName || processId;

    log(`[${label}] CLAUDE_PLUGIN_ROOT=${process.env.CLAUDE_PLUGIN_ROOT || '(not set)'}`);
    log(`[${label}] Spawning claude with args: ${JSON.stringify(args)}`);
    log(`[${label}] Working dir: ${workingDir}`);

    // Spawn Claude CLI
    const proc = spawn("claude", args, {
      cwd: workingDir,
      env: process.env,
      stdio: ["pipe", "pipe", "pipe"],
    });

    log(`[${label}] Process spawned with PID: ${proc.pid}`);

    // Close stdin immediately - Claude with -p doesn't need it
    proc.stdin?.end();
    log(`[${label}] stdin closed`);

    // Track for abort
    activeProcesses.set(processId, proc);

    // Timeout handling
    const timeoutId = setTimeout(() => {
      timedOut = true;
      proc.kill("SIGTERM");
      setTimeout(() => {
        if (!proc.killed) {
          proc.kill("SIGKILL");
        }
      }, 5000);
    }, timeout);

    // Parse streaming JSON output line by line
    const rl = createInterface({ input: proc.stdout! });

    rl.on("line", (line) => {
      log(`[${label}] STDOUT line: ${line.slice(0, 200)}${line.length > 200 ? '...' : ''}`);
      if (!line.trim()) return;

      try {
        const msg: StreamMessage = JSON.parse(line);

        // Handle different message types
        switch (msg.type) {
          case "system":
            // Capture session_id for resume support
            if (msg.session_id) {
              state.sessionId = msg.session_id;
            }
            if (progressToken !== undefined) {
              server.notification({
                method: "notifications/progress",
                params: {
                  progressToken,
                  progress: 0,
                  message: `Session initialized (${msg.session_id?.slice(0, 8)}...)`,
                },
              });
            }
            break;

          case "assistant":
            state.assistantTurnCount++;

            // Check max_turns limit
            if (max_turns && state.assistantTurnCount > max_turns) {
              log(`[${label}] max_turns (${max_turns}) exceeded at turn ${state.assistantTurnCount}, stopping`);
              maxTurnsReached = true;
              proc.kill("SIGTERM");
              break;
            }

            // Check for tool uses and text content
            if (msg.message?.content) {
              for (const block of msg.message.content) {
                if (block.type === "tool_use" && block.name) {
                  state.toolUseCount++;
                  state.currentToolUse = block.name;

                  if (progressToken !== undefined) {
                    server.notification({
                      method: "notifications/progress",
                      params: {
                        progressToken,
                        progress: state.toolUseCount,
                        message: `Tool: ${block.name}${block.input ? ` (${JSON.stringify(block.input).slice(0, 50)}...)` : ""}`,
                      },
                    });
                  }
                } else if (block.type === "text" && block.text) {
                  // Text response
                  if (progressToken !== undefined) {
                    server.notification({
                      method: "notifications/progress",
                      params: {
                        progressToken,
                        progress: state.toolUseCount,
                        message: `Response: ${block.text.slice(0, 100)}${block.text.length > 100 ? "..." : ""}`,
                      },
                    });
                  }
                }
              }
            }
            break;

          case "user":
            // Tool result - capture output and emit progress
            if (msg.tool_use_result) {
              const stdout = msg.tool_use_result.stdout || "";
              // Capture tool output for final result
              if (stdout && state.currentToolUse) {
                state.toolOutputs.push({
                  tool: state.currentToolUse,
                  output: stdout,
                });
              }
              if (progressToken !== undefined) {
                const resultPreview = stdout.slice(0, 50) || "(no output)";
                server.notification({
                  method: "notifications/progress",
                  params: {
                    progressToken,
                    progress: state.toolUseCount,
                    message: `Result: ${resultPreview}${stdout.length > 50 ? "..." : ""}`,
                  },
                });
              }
            }
            break;

          case "result":
            // Final result
            lastResult = msg;
            break;
        }
      } catch {
        // Ignore JSON parse errors (might be partial lines)
      }
    });

    // Collect stderr for errors
    let stderr = "";
    proc.stderr?.on("data", (data: Buffer) => {
      const chunk = data.toString();
      stderr += chunk;
      log(`[${label}] STDERR: ${chunk}`);
    });

    // Handle process completion
    proc.on("close", (code: number | null) => {
      log(`[${label}] Process closed with code: ${code}`);
      clearTimeout(timeoutId);
      activeProcesses.delete(processId);
      const duration = Date.now() - state.startTime;
      log(`[${label}] Duration: ${duration}ms, timedOut: ${timedOut}, maxTurnsReached: ${maxTurnsReached}, hasResult: ${!!lastResult}`);

      if (timedOut) {
        log(`[${label}] Resolving with timeout error`);
        resolvePromise({
          success: false,
          error: `Task timed out after ${timeout}ms`,
          session_id: state.sessionId,
        });
        return;
      }

      if (maxTurnsReached) {
        // Graceful stop — return what we have so far
        const totalTokens = lastResult?.usage
          ? (lastResult.usage.cache_creation_input_tokens ?? 0) +
            (lastResult.usage.cache_read_input_tokens ?? 0) +
            lastResult.usage.input_tokens +
            lastResult.usage.output_tokens
          : 0;

        resolvePromise({
          success: true,
          result: lastResult?.result || `(stopped after ${max_turns} turns)`,
          session_id: state.sessionId,
          usage: lastResult?.usage,
          toolUseCount: state.toolUseCount,
          duration,
          tokens: totalTokens,
          toolOutputs: state.toolOutputs,
        });
        return;
      }

      if (lastResult) {
        // Calculate total tokens
        const totalTokens = lastResult.usage
          ? (lastResult.usage.cache_creation_input_tokens ?? 0) +
          (lastResult.usage.cache_read_input_tokens ?? 0) +
          lastResult.usage.input_tokens +
          lastResult.usage.output_tokens
          : 0;

        // Emit final progress
        if (progressToken !== undefined) {
          server.notification({
            method: "notifications/progress",
            params: {
              progressToken,
              progress: state.toolUseCount,
              total: state.toolUseCount,
              message: `Done (${state.toolUseCount} tool uses, ${duration}ms, $${lastResult.total_cost_usd?.toFixed(4) ?? "?"})`,
            },
          });
        }

        resolvePromise({
          success: !lastResult.is_error,
          result: lastResult.result,
          session_id: state.sessionId,
          usage: lastResult.usage,
          toolUseCount: state.toolUseCount,
          duration,
          tokens: totalTokens,
          toolOutputs: state.toolOutputs,
        });
      } else if (code === 0) {
        resolvePromise({
          success: true,
          result: "(completed with no output)",
          session_id: state.sessionId,
          toolUseCount: state.toolUseCount,
          duration,
          tokens: 0,
          toolOutputs: state.toolOutputs,
        });
      } else {
        resolvePromise({
          success: false,
          error: stderr.trim() || `Process exited with code ${code}`,
          session_id: state.sessionId,
        });
      }
    });

    proc.on("error", (err: Error) => {
      clearTimeout(timeoutId);
      activeProcesses.delete(processId);
      resolvePromise({
        success: false,
        error: `Failed to spawn: ${err.message}`,
      });
    });
  });
}

// ── Request Handlers ────────────────────────────────────────────────────────

// Handle tool listing
server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [buildToolDefinition(), buildTaskStatusDefinition()],
}));

// Handle tool execution
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  log(`Tool called: ${request.params.name}`);

  // ── TaskStatus tool ──
  if (request.params.name === "TaskStatus") {
    const args = request.params.arguments as { taskId?: string };
    const taskId = args?.taskId;
    if (!taskId) {
      return {
        content: [{ type: "text", text: "Error: taskId is required" }],
        isError: true,
      };
    }
    const entry = backgroundTasks.get(taskId);
    if (!entry) {
      return {
        content: [{ type: "text", text: `Error: unknown taskId "${taskId}"` }],
        isError: true,
      };
    }
    if (entry.status === "running") {
      return {
        content: [{ type: "text", text: JSON.stringify({ taskId, status: "running" }) }],
      };
    }
    // Completed or error — return full result
    return {
      content: [{ type: "text", text: formatTaskResult(entry.result!) }],
      isError: !entry.result!.success,
    };
  }

  // ── Task tool ──
  if (request.params.name !== "Task") {
    return {
      content: [{ type: "text", text: `Unknown tool: ${request.params.name}` }],
      isError: true,
    };
  }

  const input = request.params.arguments as unknown as TaskInput;
  const progressToken = request.params._meta?.progressToken;

  log(`Prompt: ${input.prompt?.slice(0, 100)}...`);
  log(`Model: ${input.model}, mode: ${input.mode}, name: ${input.name}`);

  if (!input.prompt) {
    return {
      content: [{ type: "text", text: "Error: prompt is required" }],
      isError: true,
    };
  }

  // Build internal config with defaults
  const config: RunTaskConfig = {
    prompt: input.prompt,
    name: input.name,
    model: input.model || "sonnet",
    mode: input.mode,
    isolation: input.isolation,
    resume: input.resume,
    max_turns: input.max_turns,
    workingDir: process.cwd(),
    timeout: 600000,
  };

  // Apply agent definition defaults when subagent_type is specified
  if (input.subagent_type) {
    const agent = agentDefinitions.get(input.subagent_type);
    if (!agent) {
      const available = [...agentDefinitions.keys()].join(", ") || "(none discovered)";
      return {
        content: [{ type: "text", text: `Error: unknown subagent_type "${input.subagent_type}". Available: ${available}` }],
        isError: true,
      };
    }

    log(`Applying agent definition: ${agent.qualifiedName} (model=${agent.model})`);

    // Agent markdown body → system prompt
    if (agent.systemPrompt) {
      config.systemPrompt = agent.systemPrompt;
    }

    // Agent model as default (explicit input.model takes precedence)
    if (!input.model && agent.model) {
      config.model = agent.model;
    }

    // Compute and apply disallowed tools from agent definition
    const effective = computeEffectiveDisallowedTools(agent);
    if (effective.length > 0) {
      config.disallowedTools = effective;
      log(`Applied disallowed tools: ${effective.join(", ")}`);
    }
  }

  // Handle background execution
  if (input.run_in_background) {
    const taskId = `task-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const entry: BackgroundTask = { taskId, status: "running" };
    backgroundTasks.set(taskId, entry);

    runTask(config, progressToken).then((result) => {
      entry.status = result.success ? "completed" : "error";
      entry.result = result;
    }).catch((err) => {
      entry.status = "error";
      entry.result = { success: false, error: String(err) };
    });

    return {
      content: [{ type: "text", text: JSON.stringify({ taskId, status: "running" }) }],
    };
  }

  // Synchronous execution
  const result = await runTask(config, progressToken);
  log(`Result: success=${result.success}, error=${result.error}`);

  return {
    content: [{ type: "text", text: formatTaskResult(result) }],
    isError: !result.success ? true : undefined,
  };
});

// ── Shutdown ────────────────────────────────────────────────────────────────

// Graceful shutdown - abort all active processes
process.on("SIGTERM", () => {
  for (const [, proc] of activeProcesses) {
    proc.kill("SIGTERM");
  }
  setTimeout(() => {
    for (const [, proc] of activeProcesses) {
      if (!proc.killed) proc.kill("SIGKILL");
    }
    process.exit(0);
  }, 5000);
});

process.on("SIGINT", () => {
  for (const [, proc] of activeProcesses) {
    proc.kill("SIGINT");
  }
  process.exit(0);
});

// Start server
async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("Fallback Agent MCP Server v3.0 (streaming) running on stdio");
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
