const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const https = require('https');
const { v4: uuidv4 } = require('uuid');

const REPOS_FILE = path.join(__dirname, '..', 'data', 'repos.json');
const SETTINGS_FILE = path.join(__dirname, '..', 'data', 'settings.json');

// ─── Settings ───

function readSettings() {
  try {
    return JSON.parse(fs.readFileSync(SETTINGS_FILE, 'utf8'));
  } catch {
    return { activeRepoId: null, githubToken: null };
  }
}

function writeSettings(settings) {
  const dir = path.dirname(SETTINGS_FILE);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(SETTINGS_FILE, JSON.stringify(settings, null, 2), 'utf8');
}

function getSettings() {
  const settings = readSettings();
  // Mask the GitHub token for security
  return {
    ...settings,
    githubToken: settings.githubToken ? '••••' + settings.githubToken.slice(-4) : null,
    hasGithubToken: !!settings.githubToken,
    hasApiKey: !!process.env.ANTHROPIC_API_KEY
  };
}

function updateSettings(updates) {
  const settings = readSettings();
  if (updates.activeRepoId !== undefined) settings.activeRepoId = updates.activeRepoId;
  if (updates.githubToken !== undefined) settings.githubToken = updates.githubToken;
  writeSettings(settings);
  return getSettings();
}

// ─── Repos ───

function readRepos() {
  try {
    return JSON.parse(fs.readFileSync(REPOS_FILE, 'utf8'));
  } catch {
    return [];
  }
}

function writeRepos(repos) {
  const dir = path.dirname(REPOS_FILE);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(REPOS_FILE, JSON.stringify(repos, null, 2), 'utf8');
}

function getAllRepos() {
  const repos = readRepos();
  const settings = readSettings();
  return repos.map(r => ({
    ...r,
    isActive: r.id === settings.activeRepoId
  }));
}

function getActiveRepo() {
  const repos = readRepos();
  const settings = readSettings();

  if (settings.activeRepoId) {
    const active = repos.find(r => r.id === settings.activeRepoId);
    if (active) return active;
  }

  // Fallback: use parent directory of dashboard
  const fallbackPath = path.resolve(__dirname, '..', '..');
  return {
    id: '__fallback__',
    name: path.basename(fallbackPath),
    path: fallbackPath,
    source: 'local',
    isActive: true
  };
}

function getActiveRepoCwd() {
  return getActiveRepo().path;
}

function addRepo({ name, localPath, githubUrl }) {
  const repos = readRepos();

  let repoPath, source, fullName;

  if (localPath) {
    // Validate local path is a git repo
    repoPath = path.resolve(localPath);
    if (!fs.existsSync(repoPath)) {
      throw new Error(`Path does not exist: ${repoPath}`);
    }
    if (!fs.existsSync(path.join(repoPath, '.git'))) {
      throw new Error(`Not a git repository: ${repoPath}`);
    }
    source = 'local';
    fullName = name || path.basename(repoPath);
  } else if (githubUrl) {
    // Clone GitHub repo
    const cloneDir = path.join(__dirname, '..', 'data', 'repos');
    if (!fs.existsSync(cloneDir)) fs.mkdirSync(cloneDir, { recursive: true });

    const repoName = githubUrl.split('/').pop().replace(/\.git$/, '');
    repoPath = path.join(cloneDir, repoName);

    if (fs.existsSync(repoPath)) {
      // Already cloned, just pull
      try {
        execSync('git pull', { cwd: repoPath, timeout: 30000, stdio: 'pipe' });
      } catch { /* ignore pull errors */ }
    } else {
      const settings = readSettings();
      let cloneUrl = githubUrl;
      if (settings.githubToken && cloneUrl.startsWith('https://')) {
        cloneUrl = cloneUrl.replace('https://', `https://x-access-token:${settings.githubToken}@`);
      }
      try {
        execSync(`git clone "${cloneUrl}" "${repoPath}"`, { timeout: 120000, stdio: 'pipe' });
      } catch (e) {
        throw new Error(`Failed to clone repository: ${e.message}`);
      }
    }
    source = 'github';
    fullName = name || repoName;
  } else {
    throw new Error('Either localPath or githubUrl is required');
  }

  // Check for duplicates
  const existing = repos.find(r => r.path === repoPath);
  if (existing) {
    return existing;
  }

  // Get branch info
  let branch = 'unknown';
  try {
    branch = execSync('git rev-parse --abbrev-ref HEAD', { cwd: repoPath, timeout: 5000, encoding: 'utf8' }).trim();
  } catch { /* ignore */ }

  const repo = {
    id: uuidv4(),
    name: fullName,
    path: repoPath,
    source,
    githubUrl: githubUrl || null,
    branch,
    addedAt: new Date().toISOString()
  };

  repos.push(repo);
  writeRepos(repos);

  // If this is the first repo, auto-activate it
  if (repos.length === 1) {
    const settings = readSettings();
    settings.activeRepoId = repo.id;
    writeSettings(settings);
  }

  return repo;
}

function removeRepo(id) {
  const repos = readRepos();
  const idx = repos.findIndex(r => r.id === id);
  if (idx === -1) return false;
  repos.splice(idx, 1);
  writeRepos(repos);

  // Clear active if removed
  const settings = readSettings();
  if (settings.activeRepoId === id) {
    settings.activeRepoId = repos.length > 0 ? repos[0].id : null;
    writeSettings(settings);
  }
  return true;
}

function activateRepo(id) {
  const repos = readRepos();
  const repo = repos.find(r => r.id === id);
  if (!repo) return null;

  const settings = readSettings();
  settings.activeRepoId = id;
  writeSettings(settings);

  // Update branch info
  try {
    repo.branch = execSync('git rev-parse --abbrev-ref HEAD', { cwd: repo.path, timeout: 5000, encoding: 'utf8' }).trim();
    writeRepos(repos);
  } catch { /* ignore */ }

  return { ...repo, isActive: true };
}

// ─── GitHub API ───

function githubAPI(endpoint) {
  const settings = readSettings();
  if (!settings.githubToken) {
    throw new Error('GitHub token not configured. Please add your GitHub Personal Access Token in Settings.');
  }

  return new Promise((resolve, reject) => {
    const options = {
      hostname: 'api.github.com',
      path: endpoint,
      method: 'GET',
      headers: {
        'Authorization': `token ${settings.githubToken}`,
        'User-Agent': 'Looper-Dashboard',
        'Accept': 'application/vnd.github.v3+json'
      },
      timeout: 15000
    };

    const req = https.request(options, (res) => {
      let data = '';
      res.on('data', chunk => { data += chunk; });
      res.on('end', () => {
        try {
          const parsed = JSON.parse(data);
          if (res.statusCode === 401) {
            reject(new Error('Invalid GitHub token. Please update your token in Settings.'));
          } else if (res.statusCode >= 400) {
            reject(new Error(`GitHub API error: ${parsed.message || res.statusCode}`));
          } else {
            resolve(parsed);
          }
        } catch (e) {
          reject(new Error(`Failed to parse GitHub response: ${e.message}`));
        }
      });
    });

    req.on('timeout', () => {
      req.destroy();
      reject(new Error('GitHub API request timed out'));
    });

    req.on('error', reject);
    req.end();
  });
}

async function getGithubOrgs() {
  const user = await githubAPI('/user');
  const orgs = await githubAPI('/user/orgs');
  return [
    { login: user.login, type: 'user', avatar_url: user.avatar_url },
    ...orgs.map(o => ({ login: o.login, type: 'org', avatar_url: o.avatar_url }))
  ];
}

async function getGithubRepos(owner) {
  // Try user repos first, then org repos
  let repos;
  try {
    repos = await githubAPI(`/users/${owner}/repos?per_page=100&sort=updated`);
  } catch {
    repos = await githubAPI(`/orgs/${owner}/repos?per_page=100&sort=updated`);
  }
  return repos.map(r => ({
    name: r.name,
    full_name: r.full_name,
    description: r.description,
    html_url: r.html_url,
    clone_url: r.clone_url,
    private: r.private,
    language: r.language,
    updated_at: r.updated_at,
    default_branch: r.default_branch
  }));
}

module.exports = {
  getSettings,
  updateSettings,
  getAllRepos,
  getActiveRepo,
  getActiveRepoCwd,
  addRepo,
  removeRepo,
  activateRepo,
  getGithubOrgs,
  getGithubRepos
};
