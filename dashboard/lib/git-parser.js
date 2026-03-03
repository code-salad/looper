const { execSync } = require('child_process');
const path = require('path');

/**
 * Parse loop commits from git log into structured data.
 * Follows the same pattern as plugins/looper/skills/loop/scripts/git-loop-context
 */

function exec(cmd, cwd) {
  try {
    return execSync(cmd, { cwd: cwd || process.cwd(), encoding: 'utf8', timeout: 30000 }).trim();
  } catch {
    return '';
  }
}

function getRepoCwd() {
  // Use the parent directory of the dashboard as the repo root
  // Or allow override via LOOPER_REPO_DIR env var
  return process.env.LOOPER_REPO_DIR || path.resolve(__dirname, '..', '..');
}

function parseLoopCommits() {
  const cwd = getRepoCwd();

  // Fetch all loop commits with structured delimiters
  const raw = exec(
    'git log --grep="Loop-Phase:" --format="__COMMIT__%H|%aI|%s%n%B__END__" --all',
    cwd
  );

  if (!raw) return [];

  const commits = [];
  const blocks = raw.split('__COMMIT__').filter(Boolean);

  for (const block of blocks) {
    const endIdx = block.indexOf('__END__');
    if (endIdx === -1) continue;

    const content = block.substring(0, endIdx).trim();
    const lines = content.split('\n');
    if (lines.length === 0) continue;

    // First line: hash|date|subject
    const firstLine = lines[0];
    const pipeIdx = firstLine.indexOf('|');
    const hash = firstLine.substring(0, pipeIdx);
    const rest = firstLine.substring(pipeIdx + 1);
    const pipeIdx2 = rest.indexOf('|');
    const timestamp = rest.substring(0, pipeIdx2);
    const subject = rest.substring(pipeIdx2 + 1);

    // Parse body for trailers
    const body = lines.slice(1).join('\n');
    const phase = extractTrailer(body, 'Loop-Phase');
    const iteration = parseInt(extractTrailer(body, 'Loop-Iteration') || '0', 10);
    const verdict = extractTrailer(body, 'Loop-Verdict');

    // Parse scope from conventional commit subject: type(scope): message
    const scopeMatch = subject.match(/^\w+\(([^)]+)\):/);
    const scope = scopeMatch ? scopeMatch[1] : '';
    const typeMatch = subject.match(/^(\w+)\(/);
    const commitType = typeMatch ? typeMatch[1] : '';

    // Get file stats for doer commits
    let filesChanged = [];
    if (phase === 'do') {
      filesChanged = getFileStats(hash, cwd);
    }

    // Clean body (remove trailers)
    const cleanBody = body
      .split('\n')
      .filter(l => !l.startsWith('Loop-Phase:') && !l.startsWith('Loop-Iteration:') && !l.startsWith('Loop-Verdict:'))
      .join('\n')
      .trim();

    commits.push({
      hash: hash.substring(0, 8),
      fullHash: hash,
      timestamp,
      subject,
      body: cleanBody,
      phase,
      iteration,
      verdict: verdict || null,
      scope,
      commitType,
      filesChanged
    });
  }

  return commits;
}

function extractTrailer(body, key) {
  const match = body.match(new RegExp(`^${key}:\\s*(.+)$`, 'm'));
  return match ? match[1].trim() : null;
}

function getFileStats(hash, cwd) {
  const stat = exec(`git show --stat --format="" ${hash}`, cwd);
  if (!stat) return [];

  return stat.split('\n').filter(Boolean).map(line => {
    // Parse lines like: src/auth.ts | 25 +++---
    const match = line.match(/^\s*(.+?)\s*\|\s*(\d+)\s*([+-]*)/);
    if (!match) return null;
    const file = match[1].trim();
    const changes = parseInt(match[2], 10);
    const plusMinus = match[3] || '';
    const insertions = (plusMinus.match(/\+/g) || []).length;
    const deletions = (plusMinus.match(/-/g) || []).length;
    const ratio = insertions + deletions || 1;
    return {
      file,
      insertions: Math.round(changes * insertions / ratio),
      deletions: Math.round(changes * deletions / ratio)
    };
  }).filter(Boolean);
}

/**
 * Group commits into loop structures:
 * { taskName, status, totalIterations, iterations: [{ number, plan, do, check }] }
 */
function getLoops() {
  const commits = parseLoopCommits();

  // Group by scope (task name)
  const grouped = {};
  for (const commit of commits) {
    if (!commit.scope) continue;
    if (!grouped[commit.scope]) grouped[commit.scope] = [];
    grouped[commit.scope].push(commit);
  }

  const loops = [];
  for (const [taskName, taskCommits] of Object.entries(grouped)) {
    // Group by iteration
    const iterMap = {};
    for (const c of taskCommits) {
      if (!c.iteration) continue;
      if (!iterMap[c.iteration]) iterMap[c.iteration] = {};
      iterMap[c.iteration][c.phase] = c;
    }

    const iterations = Object.entries(iterMap)
      .sort(([a], [b]) => parseInt(a) - parseInt(b))
      .map(([num, phases]) => ({
        number: parseInt(num),
        plan: phases.plan || null,
        do: phases.do || null,
        check: phases.check || null
      }));

    // Determine overall status from last check verdict
    const lastCheck = [...iterations].reverse().find(i => i.check);
    const status = lastCheck?.check?.verdict || 'in-progress';

    loops.push({
      taskName,
      status: status === 'PASS' ? 'passed' : status === 'FAIL' ? 'failed' : 'in-progress',
      totalIterations: iterations.length,
      iterations,
      lastActivity: taskCommits.reduce((max, c) => c.timestamp > max ? c.timestamp : max, '')
    });
  }

  return loops.sort((a, b) => b.lastActivity.localeCompare(a.lastActivity));
}

function getStats() {
  const loops = getLoops();
  const total = loops.length;
  const passed = loops.filter(l => l.status === 'passed').length;
  const failed = loops.filter(l => l.status === 'failed').length;
  const inProgress = loops.filter(l => l.status === 'in-progress').length;
  const avgIterations = total > 0
    ? (loops.reduce((sum, l) => sum + l.totalIterations, 0) / total).toFixed(1)
    : 0;
  const passRate = total > 0 ? Math.round((passed / total) * 100) : 0;

  return { total, passed, failed, inProgress, avgIterations: parseFloat(avgIterations), passRate };
}

module.exports = { getLoops, getStats, parseLoopCommits, getRepoCwd };
