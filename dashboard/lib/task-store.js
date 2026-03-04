const fs = require('fs');
const path = require('path');
const { v4: uuidv4 } = require('uuid');

const DATA_FILE = path.join(__dirname, '..', 'data', 'tasks.json');

const COLUMNS = ['backlog', 'planning', 'in-progress', 'review', 'done'];
const PRIORITIES = ['critical', 'high', 'medium', 'low'];

function readTasks() {
  try {
    const data = fs.readFileSync(DATA_FILE, 'utf8');
    return JSON.parse(data);
  } catch {
    return [];
  }
}

function writeTasks(tasks) {
  const dir = path.dirname(DATA_FILE);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(DATA_FILE, JSON.stringify(tasks, null, 2), 'utf8');
}

function getAllTasks({ search, column, priority, sort } = {}) {
  let tasks = readTasks();

  if (search) {
    const q = search.toLowerCase();
    tasks = tasks.filter(t =>
      t.title.toLowerCase().includes(q) ||
      (t.description || '').toLowerCase().includes(q) ||
      (t.labels || []).some(l => l.toLowerCase().includes(q))
    );
  }

  if (column) {
    tasks = tasks.filter(t => t.column === column);
  }

  if (priority) {
    tasks = tasks.filter(t => t.priority === priority);
  }

  if (sort === 'priority') {
    tasks.sort((a, b) => PRIORITIES.indexOf(a.priority) - PRIORITIES.indexOf(b.priority));
  } else if (sort === 'name') {
    tasks.sort((a, b) => a.title.localeCompare(b.title));
  } else {
    // Default: sort by updatedAt desc
    tasks.sort((a, b) => (b.updatedAt || '').localeCompare(a.updatedAt || ''));
  }

  return tasks;
}

function getTask(id) {
  const tasks = readTasks();
  return tasks.find(t => t.id === id) || null;
}

function createTask({ title, description, priority, labels, column }) {
  const tasks = readTasks();
  const now = new Date().toISOString();
  const task = {
    id: uuidv4(),
    title,
    description: description || '',
    priority: PRIORITIES.includes(priority) ? priority : 'medium',
    labels: labels || [],
    column: COLUMNS.includes(column) ? column : 'backlog',
    loopTaskName: null,
    loopStatus: null,
    loopIterations: 0,
    loopVerdict: null,
    loopLogs: [],
    createdAt: now,
    updatedAt: now
  };
  tasks.push(task);
  writeTasks(tasks);
  return task;
}

function updateTask(id, updates) {
  const tasks = readTasks();
  const idx = tasks.findIndex(t => t.id === id);
  if (idx === -1) return null;

  const allowed = ['title', 'description', 'priority', 'labels', 'column',
    'loopTaskName', 'loopStatus', 'loopIterations', 'loopVerdict', 'loopLogs'];
  for (const key of allowed) {
    if (updates[key] !== undefined) {
      if (key === 'column' && !COLUMNS.includes(updates[key])) continue;
      if (key === 'priority' && !PRIORITIES.includes(updates[key])) continue;
      tasks[idx][key] = updates[key];
    }
  }
  tasks[idx].updatedAt = new Date().toISOString();
  writeTasks(tasks);
  return tasks[idx];
}

function deleteTask(id) {
  const tasks = readTasks();
  const idx = tasks.findIndex(t => t.id === id);
  if (idx === -1) return false;
  tasks.splice(idx, 1);
  writeTasks(tasks);
  return true;
}

function bulkUpdate(ids, updates) {
  const tasks = readTasks();
  const results = [];
  for (const id of ids) {
    const idx = tasks.findIndex(t => t.id === id);
    if (idx === -1) continue;
    if (updates.column && COLUMNS.includes(updates.column)) {
      tasks[idx].column = updates.column;
    }
    if (updates.delete) {
      tasks.splice(idx, 1);
      results.push({ id, deleted: true });
      continue;
    }
    tasks[idx].updatedAt = new Date().toISOString();
    results.push(tasks[idx]);
  }
  writeTasks(tasks);
  return results;
}

module.exports = { getAllTasks, getTask, createTask, updateTask, deleteTask, bulkUpdate, COLUMNS, PRIORITIES };
