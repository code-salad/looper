const express = require('express');
const path = require('path');

const taskStore = require('./lib/task-store');
const pmAgent = require('./lib/pm-agent');

const app = express();

const IS_VERCEL = !!process.env.VERCEL;

// Middleware
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// --- Task API ---

app.get('/api/tasks', (req, res) => {
  const { search, column, priority, sort } = req.query;
  const tasks = taskStore.getAllTasks({ search, column, priority, sort });
  res.json(tasks);
});

app.post('/api/tasks', (req, res) => {
  const { title, description, priority, labels, column } = req.body;
  if (!title) return res.status(400).json({ error: 'title is required' });
  const task = taskStore.createTask({ title, description, priority, labels, column });
  res.status(201).json(task);
});

app.put('/api/tasks/:id', (req, res) => {
  const task = taskStore.updateTask(req.params.id, req.body);
  if (!task) return res.status(404).json({ error: 'Task not found' });
  res.json(task);
});

app.delete('/api/tasks/:id', (req, res) => {
  const ok = taskStore.deleteTask(req.params.id);
  if (!ok) return res.status(404).json({ error: 'Task not found' });
  res.json({ ok: true });
});

app.post('/api/tasks/bulk', (req, res) => {
  const { ids, updates } = req.body;
  if (!ids || !Array.isArray(ids)) return res.status(400).json({ error: 'ids array required' });
  const results = taskStore.bulkUpdate(ids, updates || {});
  res.json(results);
});

// --- Loop API (local only) ---

app.post('/api/tasks/:id/start-loop', (req, res) => {
  if (IS_VERCEL) {
    return res.status(501).json({ error: 'Loop execution is only available locally. Use: cd dashboard && npm start' });
  }
  const loopRunner = require('./lib/loop-runner');
  const task = taskStore.getTask(req.params.id);
  if (!task) return res.status(404).json({ error: 'Task not found' });
  if (loopRunner.isRunning(task.id)) return res.status(409).json({ error: 'Loop already running' });
  try {
    const result = loopRunner.startLoop(task.id, task.title, {
      onComplete: (r) => {
        taskStore.updateTask(task.id, {
          loopStatus: r.code === 0 ? 'passed' : 'failed',
          column: r.code === 0 ? 'done' : 'review'
        });
      }
    });
    taskStore.updateTask(task.id, { loopStatus: 'running', column: 'in-progress' });
    res.json({ started: true, pid: result.pid });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post('/api/tasks/:id/stop-loop', (req, res) => {
  if (IS_VERCEL) return res.status(501).json({ error: 'Not available on Vercel' });
  const loopRunner = require('./lib/loop-runner');
  const ok = loopRunner.stopLoop(req.params.id);
  if (!ok) return res.status(404).json({ error: 'No running loop' });
  taskStore.updateTask(req.params.id, { loopStatus: 'stopped' });
  res.json({ stopped: true });
});

app.get('/api/tasks/:id/loop-status', (req, res) => {
  const task = taskStore.getTask(req.params.id);
  if (!task) return res.status(404).json({ error: 'Task not found' });
  res.json({ running: false, loop: null });
});

// --- PM Agent API ---

app.post('/api/pm/decompose', async (req, res) => {
  const { prompt } = req.body;
  if (!prompt) return res.status(400).json({ error: 'prompt is required' });
  try {
    const subtasks = await pmAgent.decompose(prompt);
    res.json({ subtasks });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// --- Git API (returns empty on Vercel) ---

app.get('/api/git/loops', (req, res) => {
  if (IS_VERCEL) return res.json([]);
  try {
    const gitParser = require('./lib/git-parser');
    res.json(gitParser.getLoops());
  } catch { res.json([]); }
});

app.get('/api/stats', (req, res) => {
  const tasks = taskStore.getAllTasks();
  const tasksByColumn = {};
  for (const col of taskStore.COLUMNS) {
    tasksByColumn[col] = tasks.filter(t => t.column === col).length;
  }
  let gitStats = { total: 0, passed: 0, failed: 0, inProgress: 0, avgIterations: 0, passRate: 0 };
  if (!IS_VERCEL) {
    try { gitStats = require('./lib/git-parser').getStats(); } catch {}
  }
  res.json({ ...gitStats, tasksByColumn, totalTasks: tasks.length });
});

// --- Health check ---
app.get('/api/health', (req, res) => {
  res.json({ ok: true, env: IS_VERCEL ? 'vercel' : 'local', timestamp: new Date().toISOString() });
});

// --- SPA fallback ---
app.get('*', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

// --- Start (local only) ---
if (!IS_VERCEL) {
  const http = require('http');
  const { WebSocketServer } = require('ws');
  const server = http.createServer(app);
  const wss = new WebSocketServer({ server });
  const wsClients = new Set();
  wss.on('connection', (ws) => { wsClients.add(ws); ws.on('close', () => wsClients.delete(ws)); });
  const PORT = process.env.PORT || 3000;
  server.listen(PORT, () => {
    console.log(`Looper Dashboard running at http://localhost:${PORT}`);
  });
}

module.exports = app;
