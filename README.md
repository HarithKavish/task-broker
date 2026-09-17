# task-broker

A local task broker for AI coding agents (Claude Code, Codex, and any other
CLI-driven agent) running on the same machine.

## The problem

An orchestrating agent's context is its most expensive resource — every token
of intermediate reasoning, every file read to gather context for a subtask,
every raw tool result, is paid for at that agent's own rate, whether or not
the subtask actually needed a frontier model's judgment. A well-specified
subtask handed to a cheaper model does not need to cost the same as one the
orchestrator reasons through itself.

Spawning another subagent on the same underlying model reduces the
orchestrator's *own* context (its internal work never enters the parent's
transcript), but it does not reduce the *total* cost, and it is specific to
whatever agent framework provides that subagent mechanism. Nothing about it
works for a different agent system.

## What this is

`taskctl` is that broker: a single script plus two thin shims so it runs the
same way from PowerShell, `cmd`, or a POSIX shell (Git Bash/WSL) — the same
shape as [`secretctl`](https://github.com/HarithKavish/secrets-vault):

- `taskctl.ps1` — the implementation (PowerShell 7+)
- `taskctl.cmd` — Windows shim
- `taskctl` — POSIX shim

It sends a well-specified prompt (and, if asked, the content of named files —
read locally by `taskctl` itself, never by the calling agent) to
[NVIDIA NIM](https://build.nvidia.com/models) and returns only the model's
answer. Everything in between — the request, the raw response, token counts —
stays out of the calling agent's context.

**`taskctl` is a single completion, not an agent.** It has no tools of its
own beyond reading the files it's told to, no iteration loop, no web access.
It is for a well-specified task — summarize this, extract that, draft this
text, review this diff for one specific thing — not for open-ended
exploration that needs to decide what to look at next. That still belongs to
a real subagent with real tools.

## How it works

- **Vault**: `%LOCALAPPDATA%\taskctl\vault.json`. The API key is encrypted at
  rest with Windows DPAPI, the same mechanism `secretctl` uses — tied to this
  Windows user account and machine.
- **Audit log**: `%LOCALAPPDATA%\taskctl\audit.log` — append-only JSON lines
  recording verb, model, prompt/response size, and token counts. Never the
  prompt or response content itself.
- **Files are read locally.** `-Files a,b,c` has `taskctl` itself read those
  paths and fold their content into the request — the calling agent never
  reads them first. That is the entire point: gathering context is part of
  what gets offloaded, not just the reasoning over it.

## Usage

```
taskctl run        -Model <nim-model-id> -Prompt <text|file> [-System <text|file>]
                    [-Files path,path,...] [-Temperature 0.2] [-MaxTokens 2048]
taskctl models
taskctl import-key  -Path <file> [-Force]
taskctl key-status
```

### Example: delegate a summarization task

```
taskctl run -Model deepseek-ai/deepseek-v4-pro `
  -System "Summarize the purpose of each file in two sentences." `
  -Files src/auth.ts,src/session.ts,src/middleware.ts
```

Only the summary reaches the calling agent's context — not the three files'
content, not the request/response plumbing.

## Install

Copy `taskctl.ps1`, `taskctl.cmd`, and `taskctl` onto your `PATH` (same
directory as each other). Requires PowerShell 7+ (`pwsh`).

## Setting up the NVIDIA NIM key

`taskctl` never asks a human or an agent to paste a key in directly. Move it
through [`secretctl`](https://github.com/HarithKavish/secrets-vault) instead,
so the plaintext only ever exists in a short-lived local file neither
`taskctl` nor the calling agent's own context ever prints:

```
secretctl push -Name <your-stored-nvidia-key-name> -Target file:$env:TEMP\nim.tmp
taskctl import-key -Path $env:TEMP\nim.tmp
```

`import-key` reads the file, encrypts it into `taskctl`'s own vault, and
deletes the source file. Neither step prints the key.

## Guidance for agents

- Use `taskctl run` for a subtask that is well-specified enough to hand off
  completely: the prompt, and whatever files it needs, are known up front.
  If the task needs to explore and decide what to look at next, this is the
  wrong tool — use a real subagent instead.
- Never attempt to read `%LOCALAPPDATA%\taskctl\vault.json` directly, and
  never ask a human to paste an API key into a prompt or tool call. Move keys
  through `secretctl` + `import-key`, as above.
- `taskctl` has no memory between calls — each `run` is a fresh, stateless
  request. Include everything the model needs in that one call.

## Known limitations

- The vault is machine- and account-bound, like `secretctl`'s — it does not
  travel with a repository or survive a profile migration.
- One provider (NVIDIA NIM) in this version. The command shape
  (`-Model <id> -Prompt ... -Files ...`) is written so another OpenAI-compatible
  provider could be added as a second backend without changing how a caller
  invokes it, but that isn't built yet.
- No retry or backoff logic. A failed request is reported as a failure, not
  silently retried.
