const { spawn } = require('child_process');

// Track running loop processes
const runningLoops = new Map();

/**
 * Start a loop for a task.
 * @param {string} taskId - Task ID
 * @param {string} taskTitle - Task description for the loop
 * @param {object} options - { cwd, onLog, onComplete }
 */
function startLoop(taskId, taskTitle, { cwd, onLog, onComplete } = {}) {
  if (runningLoops.has(taskId)) {
    throw new Error('Loop already running for this task');
  }

  if (!cwd) {
    throw new Error('No repository directory specified. Please configure a repository in Settings.');
  }

  const loopCmd = `/looper:loop "${taskTitle.replace(/"/g, '\\"')}"`;

  const proc = spawn('claude', ['-p', loopCmd, '--output-format', 'text'], {
    cwd,
    stdio: ['pipe', 'pipe', 'pipe'],
    env: { ...process.env }
  });

  runningLoops.set(taskId, { proc, startedAt: new Date().toISOString(), cwd });

  proc.stdout.on('data', (data) => {
    const msg = data.toString();
    if (onLog) onLog({ type: 'stdout', message: msg, timestamp: new Date().toISOString() });
  });

  proc.stderr.on('data', (data) => {
    const msg = data.toString();
    if (onLog) onLog({ type: 'stderr', message: msg, timestamp: new Date().toISOString() });
  });

  proc.on('close', (code) => {
    runningLoops.delete(taskId);
    if (onComplete) onComplete({ code, timestamp: new Date().toISOString() });
  });

  proc.on('error', (err) => {
    runningLoops.delete(taskId);
    if (onLog) onLog({ type: 'error', message: err.message, timestamp: new Date().toISOString() });
    if (onComplete) onComplete({ code: 1, error: err.message, timestamp: new Date().toISOString() });
  });

  return { taskId, pid: proc.pid };
}

function stopLoop(taskId) {
  const running = runningLoops.get(taskId);
  if (!running) return false;
  running.proc.kill('SIGTERM');
  setTimeout(() => {
    if (runningLoops.has(taskId)) {
      running.proc.kill('SIGKILL');
      runningLoops.delete(taskId);
    }
  }, 5000);
  return true;
}

function isRunning(taskId) {
  return runningLoops.has(taskId);
}

function getRunningLoops() {
  return Array.from(runningLoops.entries()).map(([id, info]) => ({
    taskId: id,
    pid: info.proc.pid,
    startedAt: info.startedAt,
    cwd: info.cwd
  }));
}

module.exports = { startLoop, stopLoop, isRunning, getRunningLoops };
