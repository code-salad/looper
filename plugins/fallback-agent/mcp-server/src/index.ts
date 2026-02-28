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
 * - Passes through all relevant CLI options to match native Task tool behavior
 *
 * Architecture:
 * ```
 * Main Plugin Session
 *     └── MCP Tool: spawn_subagent({prompt, progressToken})
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

// Build tool definition dynamically based on discovered agents
function buildToolDefinition(): Tool {
  const properties: Record<string, object> = {
    description: {
      type: "string",
      description: "A short (3-5 word) description of the task",
    },
    prompt: {
      type: "string",
      description: "The task for the agent to perform",
    },
    model: {
      type: "string",
      enum: ["sonnet", "opus", "haiku"],
      default: "sonnet",
      description: "Model to use (default: sonnet)",
    },
    workingDir: {
      type: "string",
      description: "Working directory (defaults to current)",
    },
    timeout: {
      type: "number",
      default: 600000,
      description: "Timeout in ms (default: 10 minutes)",
    },
    allowWrite: {
      type: "boolean",
      default: false,
      description: "Enable file write permissions (--dangerously-skip-permissions)",
    },
    permissionMode: {
      type: "string",
      enum: ["default", "acceptEdits", "bypassPermissions", "plan"],
      description: "Permission mode for the spawned subagent",
    },
    systemPrompt: {
      type: "string",
      description: "Custom system prompt for the spawned subagent",
    },
    appendSystemPrompt: {
      type: "string",
      description: "Append to default system prompt",
    },
    allowedTools: {
      type: "array",
      items: { type: "string" },
      description: "List of allowed tools (e.g., ['Bash', 'Read', 'Edit'])",
    },
    disallowedTools: {
      type: "array",
      items: { type: "string" },
      description: "List of disallowed tools",
    },
    maxBudgetUsd: {
      type: "number",
      description: "Maximum API cost budget in USD",
    },
    addDirs: {
      type: "array",
      items: { type: "string" },
      description: "Additional directories to allow access to",
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
    description: `Launch a new agent that has access to all tools including Task. When you are searching for a keyword or file and are not confident that you will find the right match on the first try, use the Agent tool to perform the search for you. For example:

- If you are searching for a keyword like "config" or "logger", the Agent tool is appropriate
- If you want to read a specific file path, use the Read or Glob tool instead of the Agent tool, to find the match more quickly
- If you are searching for a specific class definition like "class Foo", use the Glob tool instead, to find the match more quickly

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

interface TaskInput {
  subagent_type?: string;
  description?: string;
  prompt: string;
  model?: "sonnet" | "opus" | "haiku";
  workingDir?: string;
  timeout?: number;
  allowWrite?: boolean;
  permissionMode?: "default" | "acceptEdits" | "bypassPermissions" | "plan";
  systemPrompt?: string;
  appendSystemPrompt?: string;
  allowedTools?: string[];
  disallowedTools?: string[];
  maxBudgetUsd?: number;
  addDirs?: string[];
}

interface ToolOutput {
  tool: string;
  output: string;
}

interface ProgressState {
  toolUseCount: number;
  currentToolUse: string | null;
  startTime: number;
  toolOutputs: ToolOutput[];
}

// Create MCP server
const server = new Server(
  {
    name: "fallback-agent",
    version: "2.0.0",
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
 * Spawns a nested task (fresh Claude process) with streaming output
 */
async function runTask(
  input: TaskInput,
  progressToken?: string | number,
): Promise<{ success: boolean; result?: string; error?: string; usage?: object; toolUseCount?: number; duration?: number; tokens?: number; toolOutputs?: ToolOutput[] }> {
  const {
    prompt,
    model = "sonnet",
    workingDir = process.cwd(),
    timeout = 600000,
    allowWrite = false,
    permissionMode,
    systemPrompt,
    appendSystemPrompt,
    allowedTools,
    disallowedTools,
    maxBudgetUsd,
    addDirs,
  } = input;

  const state: ProgressState = {
    toolUseCount: 0,
    currentToolUse: null,
    startTime: Date.now(),
    toolOutputs: [],
  };

  // Build CLI arguments - matching native Task tool capabilities
  const args: string[] = [
    "-p", prompt,
    "--output-format", "stream-json",
    "--verbose",
    "--model", model,
  ];

  // Permission handling
  if (allowWrite) {
    args.push("--dangerously-skip-permissions");
  } else if (permissionMode) {
    args.push("--permission-mode", permissionMode);
  }

  // System prompt
  if (systemPrompt) {
    args.push("--system-prompt", systemPrompt);
  }
  if (appendSystemPrompt) {
    args.push("--append-system-prompt", appendSystemPrompt);
  }

  // Tool restrictions
  if (allowedTools && allowedTools.length > 0) {
    args.push("--allowed-tools", ...allowedTools);
  }
  if (disallowedTools && disallowedTools.length > 0) {
    args.push("--disallowed-tools", ...disallowedTools);
  }

  // Budget
  if (maxBudgetUsd !== undefined) {
    args.push("--max-budget-usd", String(maxBudgetUsd));
  }

  // Additional directories
  if (addDirs && addDirs.length > 0) {
    args.push("--add-dir", ...addDirs);
  }

  // Don't persist session (isolation)
  args.push("--no-session-persistence");

  // CRITICAL: Pass plugin directory so spawned process has access to the same plugins
  // This enables true nested subagents - the spawned process can also use this MCP tool
  const pluginRoot = process.env.CLAUDE_PLUGIN_ROOT;
  if (pluginRoot) {
    args.push("--plugin-dir", pluginRoot);
  }

  return new Promise((resolve) => {
    let lastResult: StreamMessage | null = null;
    let timedOut = false;
    const processId = `${Date.now()}-${Math.random().toString(36).slice(2)}`;

    log(`[${processId}] CLAUDE_PLUGIN_ROOT=${process.env.CLAUDE_PLUGIN_ROOT || '(not set)'}`);
    log(`[${processId}] Spawning claude with args: ${JSON.stringify(args)}`);
    log(`[${processId}] Working dir: ${workingDir}`);

    // Spawn Claude CLI
    const proc = spawn("claude", args, {
      cwd: workingDir,
      env: process.env,
      stdio: ["pipe", "pipe", "pipe"],
    });

    log(`[${processId}] Process spawned with PID: ${proc.pid}`);

    // Close stdin immediately - Claude with -p doesn't need it
    proc.stdin?.end();
    log(`[${processId}] stdin closed`);

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
      log(`[${processId}] STDOUT line: ${line.slice(0, 200)}${line.length > 200 ? '...' : ''}`);
      if (!line.trim()) return;

      try {
        const msg: StreamMessage = JSON.parse(line);

        // Handle different message types
        switch (msg.type) {
          case "system":
            // Session initialized - could emit init progress
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
            // Check for tool uses
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
      log(`[${processId}] STDERR: ${chunk}`);
    });

    // Handle process completion
    proc.on("close", (code: number | null) => {
      log(`[${processId}] Process closed with code: ${code}`);
      clearTimeout(timeoutId);
      activeProcesses.delete(processId);
      const duration = Date.now() - state.startTime;
      log(`[${processId}] Duration: ${duration}ms, timedOut: ${timedOut}, hasResult: ${!!lastResult}`);

      if (timedOut) {
        log(`[${processId}] Resolving with timeout error`);
        resolve({
          success: false,
          error: `Task timed out after ${timeout}ms`,
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

        resolve({
          success: !lastResult.is_error,
          result: lastResult.result,
          usage: lastResult.usage,
          toolUseCount: state.toolUseCount,
          duration,
          tokens: totalTokens,
          toolOutputs: state.toolOutputs,
        });
      } else if (code === 0) {
        resolve({
          success: true,
          result: "(completed with no output)",
          toolUseCount: state.toolUseCount,
          duration,
          tokens: 0,
          toolOutputs: state.toolOutputs,
        });
      } else {
        resolve({
          success: false,
          error: stderr.trim() || `Process exited with code ${code}`,
        });
      }
    });

    proc.on("error", (err: Error) => {
      clearTimeout(timeoutId);
      activeProcesses.delete(processId);
      resolve({
        success: false,
        error: `Failed to spawn: ${err.message}`,
      });
    });
  });
}

// Handle tool listing
server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [buildToolDefinition()],
}));

// Handle tool execution
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  log(`Tool called: ${request.params.name}`);

  if (request.params.name !== "Task") {
    return {
      content: [{ type: "text", text: `Unknown tool: ${request.params.name}` }],
      isError: true,
    };
  }

  const input = request.params.arguments as unknown as TaskInput;
  const progressToken = request.params._meta?.progressToken;

  log(`Prompt: ${input.prompt?.slice(0, 100)}...`);
  log(`Model: ${input.model}, timeout: ${input.timeout}, allowWrite: ${input.allowWrite}`);

  if (!input.prompt) {
    return {
      content: [{ type: "text", text: "Error: prompt is required" }],
      isError: true,
    };
  }

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

    // Agent markdown body → system prompt (unless caller explicitly set one)
    if (!input.systemPrompt && agent.systemPrompt) {
      input.systemPrompt = agent.systemPrompt;
    }

    // Agent model as default
    if (!input.model && agent.model) {
      input.model = agent.model;
    }

    // Compute and merge disallowed tools (unless caller explicitly set them)
    if (!input.disallowedTools) {
      const effective = computeEffectiveDisallowedTools(agent);
      if (effective.length > 0) {
        input.disallowedTools = effective;
        log(`Applied disallowed tools: ${effective.join(", ")}`);
      }
    }
  }

  const result = await runTask(input, progressToken);
  log(`Result: success=${result.success}, error=${result.error}`);

  if (result.success) {
    // Format output to match native Task tool: "Done (X tool uses · Yk tokens · Zs)"
    const toolUseText = result.toolUseCount === 1 ? '1 tool use' : `${result.toolUseCount ?? 0} tool uses`;
    const tokensText = formatNumber(result.tokens ?? 0) + ' tokens';
    const durationText = formatDuration(result.duration ?? 0);
    const summary = `Done (${toolUseText} · ${tokensText} · ${durationText})`;

    // Format tool outputs for display (similar to native Task tool)
    let toolOutputsText = '';
    if (result.toolOutputs && result.toolOutputs.length > 0) {
      toolOutputsText = result.toolOutputs
        .map(to => `[${to.tool}]\n${to.output}`)
        .join('\n\n');
    }

    // Build final output: tool outputs + result + summary
    const parts: string[] = [];
    if (toolOutputsText) parts.push(toolOutputsText);
    if (result.result) parts.push(result.result);
    parts.push(summary);

    return {
      content: [
        {
          type: "text",
          text: parts.join('\n\n'),
        },
      ],
    };
  } else {
    return {
      content: [
        {
          type: "text",
          text: `Error: ${result.error}`,
        },
      ],
      isError: true,
    };
  }
});

// Graceful shutdown - abort all active processes
process.on("SIGTERM", () => {
  for (const [id, proc] of activeProcesses) {
    proc.kill("SIGTERM");
  }
  setTimeout(() => {
    for (const [id, proc] of activeProcesses) {
      if (!proc.killed) proc.kill("SIGKILL");
    }
    process.exit(0);
  }, 5000);
});

process.on("SIGINT", () => {
  for (const [id, proc] of activeProcesses) {
    proc.kill("SIGINT");
  }
  process.exit(0);
});

// Start server
async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("Fallback Agent MCP Server v2.0 (streaming) running on stdio");
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
