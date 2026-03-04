const { spawn, execSync } = require('child_process');
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

const CLI_TIMEOUT = 90000; // 90 seconds
const API_TIMEOUT = 60000; // 60 seconds

/**
 * Check if Claude CLI is available and responsive.
 * Returns { available: boolean, method: 'cli'|'api'|null, message: string }
 */
function checkAvailability() {
  // Check API key first
  if (process.env.ANTHROPIC_API_KEY) {
    return { available: true, method: 'api', message: 'Anthropic API key configured' };
  }

  // Check Claude CLI
  try {
    execSync('which claude', { timeout: 5000, stdio: 'pipe' });
    return { available: true, method: 'cli', message: 'Claude CLI found' };
  } catch {
    return {
      available: false,
      method: null,
      message: 'Neither ANTHROPIC_API_KEY nor Claude CLI is available. Please set ANTHROPIC_API_KEY environment variable or install Claude CLI.'
    };
  }
}

/**
 * Decompose a high-level prompt into subtasks using Claude CLI or Anthropic API.
 * Returns an array of { title, description, priority }.
 */
async function decompose(prompt, { onProgress } = {}) {
  const availability = checkAvailability();
  if (!availability.available) {
    throw new Error(availability.message);
  }

  if (availability.method === 'api') {
    return decomposeViaAPI(prompt, onProgress);
  }
  return decomposeViaCLI(prompt, onProgress);
}

function decomposeViaCLI(prompt, onProgress) {
  return new Promise((resolve, reject) => {
    const fullPrompt = DECOMPOSE_PROMPT + prompt;
    const proc = spawn('claude', ['-p', fullPrompt, '--output-format', 'text'], {
      stdio: ['pipe', 'pipe', 'pipe'],
      env: { ...process.env, TERM: 'dumb' }
    });

    let stdout = '';
    let stderr = '';
    let killed = false;

    // Timeout: kill process if it takes too long
    const timer = setTimeout(() => {
      killed = true;
      proc.kill('SIGKILL');
      reject(new Error('Claude CLI timed out after 90 seconds. The CLI may be unresponsive or require authentication. Try setting ANTHROPIC_API_KEY instead.'));
    }, CLI_TIMEOUT);

    proc.stdout.on('data', (data) => {
      const chunk = data.toString();
      stdout += chunk;
      if (onProgress) onProgress(chunk);
    });

    proc.stderr.on('data', (data) => {
      stderr += data.toString();
    });

    proc.on('close', (code) => {
      clearTimeout(timer);
      if (killed) return; // Already rejected by timeout

      if (code !== 0) {
        const errMsg = stderr || 'Unknown error';
        if (errMsg.includes('auth') || errMsg.includes('login') || errMsg.includes('API key')) {
          reject(new Error('Claude CLI authentication failed. Please run "claude login" or set ANTHROPIC_API_KEY environment variable.'));
        } else {
          reject(new Error(`Claude CLI exited with code ${code}: ${errMsg}`));
        }
        return;
      }

      if (!stdout.trim()) {
        reject(new Error('Claude CLI returned empty response. The CLI may not be properly configured.'));
        return;
      }

      try {
        const tasks = parseSubtasks(stdout);
        resolve(tasks);
      } catch (e) {
        reject(new Error(`Failed to parse subtasks: ${e.message}`));
      }
    });

    proc.on('error', (err) => {
      clearTimeout(timer);
      if (err.code === 'ENOENT') {
        reject(new Error('Claude CLI not found. Install it from: https://docs.anthropic.com/en/docs/claude-code\nOr set ANTHROPIC_API_KEY environment variable to use the API directly.'));
      } else {
        reject(new Error(`Claude CLI error: ${err.message}`));
      }
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
      },
      timeout: API_TIMEOUT
    };

    const req = https.request(options, (res) => {
      let data = '';
      res.on('data', chunk => { data += chunk; });
      res.on('end', () => {
        try {
          const response = JSON.parse(data);
          if (response.error) {
            const msg = response.error.message || JSON.stringify(response.error);
            if (msg.includes('invalid') && msg.includes('key')) {
              reject(new Error('Invalid API key. Please check your ANTHROPIC_API_KEY environment variable.'));
            } else {
              reject(new Error(`API error: ${msg}`));
            }
            return;
          }
          const text = response.content?.[0]?.text || '';
          if (!text) {
            reject(new Error('API returned empty response'));
            return;
          }
          if (onProgress) onProgress(text);
          const tasks = parseSubtasks(text);
          resolve(tasks);
        } catch (e) {
          reject(new Error(`Failed to parse API response: ${e.message}`));
        }
      });
    });

    req.on('timeout', () => {
      req.destroy();
      reject(new Error('API request timed out after 60 seconds. Please try again.'));
    });

    req.on('error', (err) => {
      if (err.code === 'ECONNREFUSED' || err.code === 'ENOTFOUND') {
        reject(new Error('Cannot reach Anthropic API. Please check your network connection.'));
      } else {
        reject(new Error(`API request failed: ${err.message}`));
      }
    });

    req.write(body);
    req.end();
  });
}

function parseSubtasks(text) {
  // Try to extract JSON array from response
  // Handle markdown-wrapped responses: ```json\n[...]\n```
  let cleaned = text.trim();

  // Remove markdown code fences if present
  const fenceMatch = cleaned.match(/```(?:json)?\s*\n?([\s\S]*?)\n?\s*```/);
  if (fenceMatch) {
    cleaned = fenceMatch[1].trim();
  }

  // Try to find JSON array
  const jsonMatch = cleaned.match(/\[[\s\S]*\]/);
  if (!jsonMatch) {
    throw new Error('No JSON array found in response. The AI may have returned an unexpected format.');
  }

  let parsed;
  try {
    parsed = JSON.parse(jsonMatch[0]);
  } catch (e) {
    // Try fixing common JSON issues (trailing commas, etc.)
    const fixedJson = jsonMatch[0]
      .replace(/,\s*\]/g, ']')  // trailing comma in array
      .replace(/,\s*\}/g, '}'); // trailing comma in object
    parsed = JSON.parse(fixedJson);
  }

  if (!Array.isArray(parsed)) throw new Error('Response is not an array');
  if (parsed.length === 0) throw new Error('Response contains no subtasks');

  return parsed.map(item => ({
    title: String(item.title || '').trim(),
    description: String(item.description || '').trim(),
    priority: ['critical', 'high', 'medium', 'low'].includes(item.priority) ? item.priority : 'medium'
  })).filter(item => item.title);
}

module.exports = { decompose, checkAvailability };
