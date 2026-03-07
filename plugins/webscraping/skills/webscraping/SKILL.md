---
name: webscraping
description: End-to-end web scraping skill. Use when the user wants to scrape a website, build scrapers, or extract structured data. Covers the full pipeline - recon (via the recon agent), method selection, implementation (.NET 10), checkpointing, anti-detection, and proxy management.
argument-hint: "[url or target description]"
allowed-tools: Agent
---

# Web Scraping Skill

This skill delegates to the `webscraping:webscraping` agent, which handles the full scraping pipeline.

## Instructions

Spawn the webscraping agent with the user's request:

```
Agent tool call:
  subagent_type: "webscraping:webscraping"
  prompt: "$ARGUMENTS"
```

Wait for the agent to complete and present its results to the user.
