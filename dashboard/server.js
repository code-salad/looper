const express = require('express');
const http = require('http');
const { WebSocketServer } = require('ws');
const path = require('path');

const taskStore = require('./lib/task-store');
const gitParser = require('./lib/git-parser');
const loopRunner = require('./lib/loop-runner');
const pmAgent = require('./lib/pm-agent');
const repoManager = require('./lib/repo-manager');

const app = express();
const server = http.createServer(app);
const wss = new WebSocketServer({ server });

const PORT = process.env.PORT || 3000;

// Security headers
app.use((req, res, next) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'SAMEORIGIN');
  res.setHeader('X-XSS-Protection', '1; mode=block');
  next();
});

// Middleware
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// --- WebSocket ---
const wsClients = new Set();

wss.on('connection', (ws) => {
  wsClients.add(ws);
  ws.on('close', () => wsClients.delete(ws));
});

function broadcast(type, data) {
  const msg = JSON.stringify({ type, data, timestamp: new Date().toISOString() });
  for (const ws of wsClients) {
    if (ws.readyState === 1) ws.send(msg);
  }
}

// --- Health Check ---
app.get('/api/health', (req, res) => {
  const activeRepo = repoManager.getActiveRepo();
  res.json({
    status: 'ok',
    uptime: process.uptime(),
    repo: activeRepo ? { name: activeRepo.name, path: activeRepo.path, branch: activeRepo.branch } : null,
    pm: pmAgent.checkAvailability()
  });
});

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
  broadcast('task:created', task);
  res.status(201).json(task);
});

app.put('/api/tasks/:id', (req, res) => {
  const task = taskStore.updateTask(req.params.id, req.body);
  if (!task) return res.status(404).json({ error: 'Task not found' });
  broadcast('task:updated', task);
  res.json(task);
});

app.delete('/api/tasks/:id', (req, res) => {
  const ok = taskStore.deleteTask(req.params.id);
  if (!ok) return res.status(404).json({ error: 'Task not found' });
  broadcast('task:deleted', { id: req.params.id });
  res.json({ ok: true });
});

app.post('/api/tasks/bulk', (req, res) => {
  const { ids, updates } = req.body;
  if (!ids || !Array.isArray(ids)) return res.status(400).json({ error: 'ids array required' });
  const results = taskStore.bulkUpdate(ids, updates || {});
  broadcast('tasks:bulk-updated', results);
  res.json(results);
});

// --- Loop API ---

app.post('/api/tasks/:id/start-loop', (req, res) => {
  const task = taskStore.getTask(req.params.id);
  if (!task) return res.status(404).json({ error: 'Task not found' });

  if (loopRunner.isRunning(task.id)) {
    return res.status(409).json({ error: 'Loop already running' });
  }

  try {
    const cwd = repoManager.getActiveRepoCwd();
    const loopTaskName = task.title.replace(/[^a-zA-Z0-9_-]/g, '-').toLowerCase().substring(0, 50);

    const result = loopRunner.startLoop(task.id, task.title, {
      cwd,
      onLog: (log) => {
        broadcast('loop:log', { taskId: task.id, ...log });
      },
      onComplete: (result) => {
        const column = result.code === 0 ? 'done' : 'review';
        taskStore.updateTask(task.id, {
          loopStatus: result.code === 0 ? 'passed' : 'failed',
          column
        });
        broadcast('loop:complete', { taskId: task.id, ...result });
      }
    });

    taskStore.updateTask(task.id, {
      loopStatus: 'running',
      loopTaskName,
      column: 'in-progress'
    });
    broadcast('task:updated', taskStore.getTask(task.id));

    res.json({ started: true, pid: result.pid });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post('/api/tasks/:id/stop-loop', (req, res) => {
  const ok = loopRunner.stopLoop(req.params.id);
  if (!ok) return res.status(404).json({ error: 'No running loop for this task' });

  taskStore.updateTask(req.params.id, { loopStatus: 'stopped' });
  broadcast('task:updated', taskStore.getTask(req.params.id));
  res.json({ stopped: true });
});

app.get('/api/tasks/:id/loop-status', (req, res) => {
  const task = taskStore.getTask(req.params.id);
  if (!task) return res.status(404).json({ error: 'Task not found' });

  const cwd = repoManager.getActiveRepoCwd();
  const loops = gitParser.getLoops(cwd);
  const loop = loops.find(l => l.taskName === task.loopTaskName) || null;
  res.json({
    running: loopRunner.isRunning(req.params.id),
    loop
  });
});

// --- PM Agent API ---

app.get('/api/pm/status', (req, res) => {
  res.json(pmAgent.checkAvailability());
});

app.post('/api/pm/decompose', async (req, res) => {
  const { prompt } = req.body;
  if (!prompt) return res.status(400).json({ error: 'prompt is required' });

  try {
    broadcast('pm:decomposing', { prompt });
    const subtasks = await pmAgent.decompose(prompt, {
      onProgress: (chunk) => broadcast('pm:progress', { chunk })
    });
    broadcast('pm:complete', { subtasks });
    res.json({ subtasks });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// --- Repository API ---

app.get('/api/repos', (req, res) => {
  res.json(repoManager.getAllRepos());
});

app.post('/api/repos', (req, res) => {
  const { name, localPath, githubUrl } = req.body;
  try {
    const repo = repoManager.addRepo({ name, localPath, githubUrl });
    broadcast('repo:added', repo);
    res.status(201).json(repo);
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

app.delete('/api/repos/:id', (req, res) => {
  const ok = repoManager.removeRepo(req.params.id);
  if (!ok) return res.status(404).json({ error: 'Repository not found' });
  broadcast('repo:removed', { id: req.params.id });
  res.json({ ok: true });
});

app.put('/api/repos/:id/activate', (req, res) => {
  const repo = repoManager.activateRepo(req.params.id);
  if (!repo) return res.status(404).json({ error: 'Repository not found' });
  broadcast('repo:activated', repo);
  res.json(repo);
});

// --- GitHub Integration API ---

app.post('/api/repos/github/connect', (req, res) => {
  const { token } = req.body;
  if (!token) return res.status(400).json({ error: 'token is required' });
  const settings = repoManager.updateSettings({ githubToken: token });
  res.json({ connected: true, settings });
});

app.get('/api/repos/github/orgs', async (req, res) => {
  try {
    const orgs = await repoManager.getGithubOrgs();
    res.json(orgs);
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

app.get('/api/repos/github/repos', async (req, res) => {
  const { owner } = req.query;
  if (!owner) return res.status(400).json({ error: 'owner query parameter required' });
  try {
    const repos = await repoManager.getGithubRepos(owner);
    res.json(repos);
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

// --- Settings API ---

app.get('/api/settings', (req, res) => {
  res.json(repoManager.getSettings());
});

app.put('/api/settings', (req, res) => {
  const settings = repoManager.updateSettings(req.body);
  res.json(settings);
});

// --- Git API ---

app.get('/api/git/loops', (req, res) => {
  const cwd = repoManager.getActiveRepoCwd();
  const loops = gitParser.getLoops(cwd);
  res.json(loops);
});

app.get('/api/stats', (req, res) => {
  const cwd = repoManager.getActiveRepoCwd();
  const gitStats = gitParser.getStats(cwd);
  const tasks = taskStore.getAllTasks();
  const tasksByColumn = {};
  for (const col of taskStore.COLUMNS) {
    tasksByColumn[col] = tasks.filter(t => t.column === col).length;
  }
  res.json({ ...gitStats, tasksByColumn, totalTasks: tasks.length });
});

// --- SPA fallback ---
app.get('*', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

// --- Start ---
// Only listen when running locally (not on Vercel serverless)
if (!process.env.VERCEL) {
  server.listen(PORT, () => {
    const activeRepo = repoManager.getActiveRepo();
    console.log(`Looper Dashboard running at http://localhost:${PORT}`);
    console.log(`Active repository: ${activeRepo.name} (${activeRepo.path})`);
    console.log(`PM Agent: ${pmAgent.checkAvailability().message}`);
  });
}

// Export for Vercel serverless
module.exports = app;
