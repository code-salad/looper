use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use crate::types::AgentDefinition;

/// Tools that require write access — used to enforce read-only agents.
pub const WRITE_TOOLS: &[&str] = &["Write", "Edit", "NotebookEdit"];

/// Parse YAML frontmatter and markdown body from an agent definition file.
/// Handles simple `key: value` pairs and comma-separated lists.
pub fn parse_agent_file(content: &str, namespace: &str) -> Option<AgentDefinition> {
    if !content.starts_with("---") {
        return None;
    }

    let end_idx = content[3..].find("\n---").map(|i| i + 3)?;

    let frontmatter = &content[4..end_idx]; // skip opening '---\n'
    let body = content[end_idx + 4..].trim().to_string(); // skip closing '\n---\n'

    let mut meta: HashMap<String, String> = HashMap::new();
    for line in frontmatter.lines() {
        let colon_idx = match line.find(':') {
            Some(i) => i,
            None => continue,
        };
        let key = line[..colon_idx].trim().to_string();
        let value = line[colon_idx + 1..].trim().to_string();
        if !key.is_empty() && !value.is_empty() {
            meta.insert(key, value);
        }
    }

    let name = meta.get("name")?.clone();

    let parse_list = |s: Option<&String>| -> Option<Vec<String>> {
        s.map(|v| {
            v.split(',')
                .map(|t| t.trim().to_string())
                .filter(|t| !t.is_empty())
                .collect()
        })
    };

    let qualified_name = if namespace.is_empty() {
        name.clone()
    } else {
        format!("{}:{}", namespace, name)
    };

    let model = meta.get("model").and_then(|m| {
        if ["sonnet", "opus", "haiku"].contains(&m.as_str()) {
            Some(m.clone())
        } else {
            None
        }
    });

    Some(AgentDefinition {
        name,
        qualified_name,
        description: meta.get("description").cloned().unwrap_or_default(),
        tools: parse_list(meta.get("tools")),
        disallowed_tools: parse_list(meta.get("disallowedTools")),
        model,
        system_prompt: body,
    })
}

/// Read the plugin name from `.claude-plugin/plugin.json`, falling back to dir basename.
pub fn get_plugin_namespace(plugin_dir: &Path) -> String {
    let plugin_json_path = plugin_dir.join(".claude-plugin").join("plugin.json");
    if let Ok(content) = fs::read_to_string(&plugin_json_path) {
        if let Ok(json) = serde_json::from_str::<serde_json::Value>(&content) {
            if let Some(name) = json.get("name").and_then(|n| n.as_str()) {
                return name.to_string();
            }
        }
    }
    plugin_dir
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("")
        .to_string()
}

/// Check if a directory is a plugin root (has .claude-plugin/plugin.json).
pub fn is_plugin_dir(dir: &Path) -> bool {
    dir.join(".claude-plugin").join("plugin.json").exists()
}

/// Discover agent definitions by scanning:
///   1. CLAUDE_PLUGIN_ROOT/agents/*.md  (own plugin)
///   2. Sibling plugins — handles both flat and versioned cache layouts
///   3. ~/.claude/agents/*.md — user agents, loaded with an empty namespace (no prefix)
pub fn discover_agents() -> HashMap<String, AgentDefinition> {
    let mut agents: HashMap<String, AgentDefinition> = HashMap::new();
    let plugin_root = match std::env::var("CLAUDE_PLUGIN_ROOT") {
        Ok(v) => v,
        Err(_) => {
            crate::log("No CLAUDE_PLUGIN_ROOT set — skipping agent discovery");
            return agents;
        }
    };

    let plugin_root = PathBuf::from(&plugin_root);
    let plugin_root_resolved = match plugin_root.canonicalize() {
        Ok(p) => p,
        Err(_) => plugin_root.clone(),
    };

    let mut scan_targets: Vec<(PathBuf, String)> = Vec::new();
    let mut visited: std::collections::HashSet<PathBuf> = std::collections::HashSet::new();
    visited.insert(plugin_root_resolved.clone());

    // 1. Own plugin agents
    let own_agents_dir = plugin_root.join("agents");
    if own_agents_dir.is_dir() {
        let ns = get_plugin_namespace(&plugin_root);
        scan_targets.push((own_agents_dir, ns));
    }

    let scan_for_siblings =
        |dir: &Path,
         scan_targets: &mut Vec<(PathBuf, String)>,
         visited: &mut std::collections::HashSet<PathBuf>| {
            let entries = match fs::read_dir(dir) {
                Ok(e) => e,
                Err(err) => {
                    crate::log(&format!(
                        "Error scanning for siblings in {}: {}",
                        dir.display(),
                        err
                    ));
                    return;
                }
            };

            for entry in entries.flatten() {
                let entry_path = entry.path();
                if !entry_path.is_dir() {
                    continue;
                }

                // Direct plugin sibling (flat layout)
                if is_plugin_dir(&entry_path) {
                    let resolved = entry_path
                        .canonicalize()
                        .unwrap_or_else(|_| entry_path.clone());
                    if !visited.contains(&resolved) {
                        visited.insert(resolved);
                        let agents_dir = entry_path.join("agents");
                        if agents_dir.is_dir() {
                            let ns = get_plugin_namespace(&entry_path);
                            scan_targets.push((agents_dir.clone(), ns));
                            crate::log(&format!("Found sibling agents: {}", agents_dir.display()));
                        }
                    }
                    continue;
                }

                // Versioned plugin sibling (cache layout) — scan subdirs for plugin roots
                if let Ok(sub_entries) = fs::read_dir(&entry_path) {
                    for sub_entry in sub_entries.flatten() {
                        let sub_path = sub_entry.path();
                        if sub_path.is_dir() && is_plugin_dir(&sub_path) {
                            let resolved =
                                sub_path.canonicalize().unwrap_or_else(|_| sub_path.clone());
                            if !visited.contains(&resolved) {
                                visited.insert(resolved);
                                let agents_dir = sub_path.join("agents");
                                if agents_dir.is_dir() {
                                    let ns = get_plugin_namespace(&sub_path);
                                    scan_targets.push((agents_dir.clone(), ns));
                                    crate::log(&format!(
                                        "Found sibling agents: {}",
                                        agents_dir.display()
                                    ));
                                }
                            }
                        }
                    }
                }
            }
        };

    // 2. Scan parent (flat layout) and grandparent (cache layout)
    let parent = plugin_root.join("..");
    let grandparent = plugin_root.join("..").join("..");

    scan_for_siblings(&parent, &mut scan_targets, &mut visited);
    scan_for_siblings(&grandparent, &mut scan_targets, &mut visited);

    // 3. User agents from ~/.claude/agents/
    if let Ok(home) = std::env::var("HOME") {
        let user_agents_dir = PathBuf::from(home).join(".claude").join("agents");
        if user_agents_dir.is_dir() {
            crate::log(&format!(
                "Scanning user agents: {}",
                user_agents_dir.display()
            ));
            scan_targets.push((user_agents_dir, String::new()));
        }
    }

    // 4. Parse agent files from all discovered directories
    for (dir, namespace) in &scan_targets {
        let entries = match fs::read_dir(dir) {
            Ok(e) => e,
            Err(err) => {
                crate::log(&format!(
                    "Error scanning agent directory {}: {}",
                    dir.display(),
                    err
                ));
                continue;
            }
        };

        for entry in entries.flatten() {
            let file_path = entry.path();
            if file_path.extension().and_then(|e| e.to_str()) != Some("md") {
                continue;
            }

            match fs::read_to_string(&file_path) {
                Ok(content) => {
                    if let Some(agent) = parse_agent_file(&content, namespace) {
                        crate::log(&format!(
                            "Discovered agent: {} ({})",
                            agent.qualified_name,
                            file_path.display()
                        ));
                        agents.insert(agent.qualified_name.clone(), agent);
                    }
                }
                Err(err) => {
                    crate::log(&format!(
                        "Error parsing agent file {}: {}",
                        file_path.display(),
                        err
                    ));
                }
            }
        }
    }

    agents
}

/// Compute effective disallowed tools for an agent definition.
/// Uses explicit `disallowedTools` and supplements by blocking write tools
/// that are absent from the `tools` allowlist.
pub fn compute_effective_disallowed_tools(agent: &AgentDefinition) -> Vec<String> {
    let mut disallowed: std::collections::HashSet<String> = agent
        .disallowed_tools
        .as_ref()
        .map(|v| v.iter().cloned().collect())
        .unwrap_or_default();

    if let Some(tools) = &agent.tools {
        if !tools.is_empty() {
            for &write_tool in WRITE_TOOLS {
                if !tools.contains(&write_tool.to_string()) {
                    disallowed.insert(write_tool.to_string());
                }
            }
        }
    }

    disallowed.into_iter().collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_agent_file_basic() {
        let content = "---\nname: planner\ndescription: A planning agent\nmodel: sonnet\n---\n\nThis is the system prompt.";
        let agent = parse_agent_file(content, "looper").unwrap();
        assert_eq!(agent.name, "planner");
        assert_eq!(agent.qualified_name, "looper:planner");
        assert_eq!(agent.description, "A planning agent");
        assert_eq!(agent.model, Some("sonnet".to_string()));
        assert_eq!(agent.system_prompt, "This is the system prompt.");
    }

    #[test]
    fn test_parse_agent_file_no_namespace() {
        let content = "---\nname: doer\ndescription: Does things\n---\n\nDo the thing.";
        let agent = parse_agent_file(content, "").unwrap();
        assert_eq!(agent.qualified_name, "doer");
    }

    #[test]
    fn test_parse_agent_file_with_tools() {
        let content = "---\nname: checker\ndescription: Checks things\ntools: Read, Glob, Grep\n---\n\nCheck it.";
        let agent = parse_agent_file(content, "ns").unwrap();
        assert_eq!(
            agent.tools,
            Some(vec![
                "Read".to_string(),
                "Glob".to_string(),
                "Grep".to_string()
            ])
        );
    }

    #[test]
    fn test_parse_agent_file_no_frontmatter() {
        let content = "Just a plain markdown file.";
        assert!(parse_agent_file(content, "ns").is_none());
    }

    #[test]
    fn test_parse_agent_file_no_name() {
        let content = "---\ndescription: No name here\n---\n\nBody.";
        assert!(parse_agent_file(content, "ns").is_none());
    }

    #[test]
    fn test_parse_agent_file_invalid_model() {
        let content = "---\nname: agent\nmodel: gpt-4\n---\n\nBody.";
        let agent = parse_agent_file(content, "ns").unwrap();
        assert_eq!(agent.model, None);
    }

    #[test]
    fn test_compute_effective_disallowed_tools_no_tools() {
        let agent = AgentDefinition {
            name: "agent".to_string(),
            qualified_name: "ns:agent".to_string(),
            description: "".to_string(),
            tools: None,
            disallowed_tools: None,
            model: None,
            system_prompt: "".to_string(),
        };
        let result = compute_effective_disallowed_tools(&agent);
        assert!(result.is_empty());
    }

    #[test]
    fn test_compute_effective_disallowed_tools_with_explicit() {
        let agent = AgentDefinition {
            name: "agent".to_string(),
            qualified_name: "ns:agent".to_string(),
            description: "".to_string(),
            tools: None,
            disallowed_tools: Some(vec!["Write".to_string()]),
            model: None,
            system_prompt: "".to_string(),
        };
        let result = compute_effective_disallowed_tools(&agent);
        assert!(result.contains(&"Write".to_string()));
    }

    #[test]
    fn test_compute_effective_disallowed_tools_from_allowlist() {
        let agent = AgentDefinition {
            name: "agent".to_string(),
            qualified_name: "ns:agent".to_string(),
            description: "".to_string(),
            tools: Some(vec!["Read".to_string(), "Glob".to_string()]),
            disallowed_tools: None,
            model: None,
            system_prompt: "".to_string(),
        };
        let result = compute_effective_disallowed_tools(&agent);
        // All WRITE_TOOLS should be disallowed since none are in the allowlist
        assert!(result.contains(&"Write".to_string()));
        assert!(result.contains(&"Edit".to_string()));
        assert!(result.contains(&"NotebookEdit".to_string()));
    }

    #[test]
    fn test_compute_effective_disallowed_tools_write_in_allowlist() {
        let agent = AgentDefinition {
            name: "agent".to_string(),
            qualified_name: "ns:agent".to_string(),
            description: "".to_string(),
            tools: Some(vec!["Read".to_string(), "Write".to_string()]),
            disallowed_tools: None,
            model: None,
            system_prompt: "".to_string(),
        };
        let result = compute_effective_disallowed_tools(&agent);
        // Write should NOT be disallowed since it's in the allowlist
        assert!(!result.contains(&"Write".to_string()));
        // Edit and NotebookEdit should still be disallowed
        assert!(result.contains(&"Edit".to_string()));
        assert!(result.contains(&"NotebookEdit".to_string()));
    }

    #[test]
    fn test_discover_user_agents_graceful_skip() {
        // Set HOME to a nonexistent directory; discover_agents() must not panic or error.
        // Also point CLAUDE_PLUGIN_ROOT to a nonexistent path to isolate this test.
        let tmp = std::env::temp_dir().join("looper_test_graceful_skip_no_home");
        std::env::set_var("HOME", tmp.to_str().unwrap());
        std::env::set_var("CLAUDE_PLUGIN_ROOT", "/nonexistent_plugin_root_xyz");

        // Should return an empty map without panicking.
        let agents = discover_agents();

        // No user agents should be loaded (the .claude/agents dir doesn't exist).
        assert!(
            agents.is_empty(),
            "Expected no agents when ~/.claude/agents does not exist"
        );
    }

    #[test]
    fn test_discover_user_agents_loads_md() {
        use std::fs;

        // Build a temp dir tree: {tmp}/.claude/agents/my-agent.md
        let tmp = std::env::temp_dir().join("looper_test_user_agents_loads_md");
        let agents_dir = tmp.join(".claude").join("agents");
        fs::create_dir_all(&agents_dir).expect("create agents dir");

        let agent_content =
            "---\nname: my-agent\ndescription: A user agent\nmodel: sonnet\n---\n\nDo the thing.";
        fs::write(agents_dir.join("my-agent.md"), agent_content).expect("write agent file");

        std::env::set_var("HOME", tmp.to_str().unwrap());
        std::env::set_var("CLAUDE_PLUGIN_ROOT", "/nonexistent_plugin_root_xyz");

        let agents = discover_agents();

        // Clean up before assertions in case they panic.
        let _ = fs::remove_dir_all(&tmp);

        assert!(
            agents.contains_key("my-agent"),
            "Expected 'my-agent' to be discovered with an empty namespace; got: {:?}",
            agents.keys().collect::<Vec<_>>()
        );
        let agent = &agents["my-agent"];
        assert_eq!(agent.name, "my-agent");
        // Empty namespace means qualified_name == name (no colon prefix).
        assert_eq!(
            agent.qualified_name, "my-agent",
            "qualified_name should equal name when namespace is empty"
        );
    }
}
