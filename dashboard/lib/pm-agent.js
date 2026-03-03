const { spawn } = require('child_process');
const https = require('https');

const DECOMPOSE_PROMPT = `You are a PM Agent. Given a high-level task description, break it into 3-7 independent subtasks suitable for automated implementation by an AI coding agent.

For each subtask, provide:
1. title: A short, clear task title (imperative mood)
2. description: What needs to be done (2-3 sentences)
3. priority: One of "critical", "high", "medium", "low"

Respond ONLY with valid JSON array. No markdown, no explanation. Example:
[
  {"title": "Add user model", "description": "Create the User model with email, name, and password hash fields. Add database migration.", "priority": "high"},
  {"title": "Implement login endpoint", "description": "Create POST /api/auth/login that validates credentials and returns a JWT token.", "priority": "high"}
]

Task to decompose:
`;

/**
 * Decompose a high-level prompt into subtasks using Claude CLI or Anthropic API.
 * Returns an array of { title, description, priority }.
 */
async function decompose(prompt, { onProgress } = {}) {
  // Try Anthropic API first if key is available
  if (process.env.ANTHROPIC_API_KEY) {
    return decomposeViaAPI(prompt, onProgress);
  }
  // Fall back to Claude CLI
  return decomposeViaCLI(prompt, onProgress);
}

function decomposeViaCLI(prompt, onProgress) {
  return new Promise((resolve, reject) => {
    const fullPrompt = DECOMPOSE_PROMPT + prompt;
    const proc = spawn('claude', ['-p', fullPrompt, '--output-format', 'text'], {
      stdio: ['pipe', 'pipe', 'pipe'],
      timeout: 120000
    });

    let stdout = '';
    let stderr = '';

    proc.stdout.on('data', (data) => {
      const chunk = data.toString();
      stdout += chunk;
      if (onProgress) onProgress(chunk);
    });

    proc.stderr.on('data', (data) => {
      stderr += data.toString();
    });

    proc.on('close', (code) => {
      if (code !== 0) {
        reject(new Error(`Claude CLI exited with code ${code}: ${stderr}`));
        return;
      }
      try {
        const tasks = parseSubtasks(stdout);
        resolve(tasks);
      } catch (e) {
        reject(new Error(`Failed to parse subtasks: ${e.message}\nRaw output: ${stdout}`));
      }
    });

    proc.on('error', (err) => {
      reject(new Error(`Claude CLI not found. Install it: https://docs.anthropic.com/en/docs/claude-code\n${err.message}`));
    });
  });
}

function decomposeViaAPI(prompt, onProgress) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({
      model: 'claude-sonnet-4-20250514',
      max_tokens: 2048,
      messages: [{ role: 'user', content: DECOMPOSE_PROMPT + prompt }]
    });

    const options = {
      hostname: 'api.anthropic.com',
      path: '/v1/messages',
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': process.env.ANTHROPIC_API_KEY,
        'anthropic-version': '2023-06-01'
      }
    };

    const req = https.request(options, (res) => {
      let data = '';
      res.on('data', chunk => { data += chunk; });
      res.on('end', () => {
        try {
          const response = JSON.parse(data);
          if (response.error) {
            reject(new Error(`API error: ${response.error.message}`));
            return;
          }
          const text = response.content?.[0]?.text || '';
          if (onProgress) onProgress(text);
          const tasks = parseSubtasks(text);
          resolve(tasks);
        } catch (e) {
          reject(new Error(`Failed to parse API response: ${e.message}`));
        }
      });
    });

    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

function parseSubtasks(text) {
  // Extract JSON array from response (may contain markdown or extra text)
  const jsonMatch = text.match(/\[[\s\S]*\]/);
  if (!jsonMatch) throw new Error('No JSON array found in response');

  const parsed = JSON.parse(jsonMatch[0]);
  if (!Array.isArray(parsed)) throw new Error('Response is not an array');

  return parsed.map(item => ({
    title: String(item.title || '').trim(),
    description: String(item.description || '').trim(),
    priority: ['critical', 'high', 'medium', 'low'].includes(item.priority) ? item.priority : 'medium'
  })).filter(item => item.title);
}

module.exports = { decompose };
