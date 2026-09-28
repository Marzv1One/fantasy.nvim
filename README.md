# fantasy.nvim

A Neovim client for the `fantasy-server` Go agent. Spawns a long-lived
JSON-RPC 2.0 process (stdin/stdout) and streams responses into a floating
window, with sessions persisted server-side in SQLite.

Features:

- Streaming responses with tool-call / tool-result annotations
- Session management (list, read, rename, delete, compact) backed by the server
- File edit and shell execution gated behind interactive confirm dialogs
- Image/audio attachments (`:FantasyAttach`)
- Runtime model / system-prompt switching, per-role model picker
- Works on Windows without external tools (bundled pure-Lua base64 encoder)

## Requirements

- Neovim **0.11+** recommended (`vim.diff` for unified diffs in edit confirmations;
  older versions fall back to a plain before/after listing)
- A built `fantasy-server` binary on `PATH` (see below)
- Optional: [fzf-lua](https://github.com/ibhagwan/fzf-lua) for `:FantasySessions`
  and `:FantasyModels`; [markview.nvim](https://github.com/OXY2DEV/markview.nvim)
  for rendered markdown

## Building the server

From the `fantasy-server-demo` repo:

```
go build -o fantasy-server.exe .
```

Put the resulting binary on your `PATH`, or point `server_cmd` at the absolute
path in your config. The server reads `XIAOMI_MIMO_API_KEY` from the
environment, so make sure it is exported before starting Neovim.

> Note: `charm.land/fantasy` is fetched as a normal module dependency
> (`v0.43.1`), so the server builds anywhere with Go installed.

## Installation

### lazy.nvim

```lua
{
  dir = 'C:/Users/SH_Develop/source/go/fantasy.nvim', -- or wherever you cloned it
  dependencies = { 'ibhagwan/fzf-lua' },
  opts = {},
}
```

`opts` is passed to `require('fantasy').setup()`.

## Configuration

```lua
require('fantasy').setup({
  server_cmd = 'fantasy-server', -- binary on PATH
  server_args = {},              -- extra argv for the server
  server_cwd = nil,              -- defaults to Neovim's cwd at spawn time
  model = nil,                   -- override the server's default model
  system_prompt = nil,           -- override the server's system prompt
  width = 0.85,                  -- float size (fraction of editor)
  height = 0.85,
  border = 'rounded',
  title = ' fantasy ',
})
```

## Commands

| Command | Description |
|---|---|
| `:Fantasy {question}` | Ask with the current visual selection as context |
| `:FantasyChat {question}` | Chat without code context |
| `:FantasyPrompt` | Multi-line prompt buffer (`<C-CR>` / `<S-CR>` / `<C-s>` to send, `q`/`<Esc>` to close) |
| `:FantasyOpen` | Reopen the last response window |
| `:FantasyModel {model}` | Change the primary model at runtime |
| `:FantasyModels` | Interactive role + model picker (fzf-lua) |
| `:FantasySystem {prompt}` | Change the system prompt at runtime |
| `:FantasySessions` | Session picker (fzf-lua; `ctrl-x` delete, `ctrl-o` preview tail, `ctrl-r` rename) |
| `:FantasySession {id}` | Set the active session |
| `:FantasyReadSession [id]` | View a session transcript (chunked loading; `r` refresh) |
| `:FantasyNewSession` | Create a fresh session and make it active |
| `:FantasyRename {title}` | Rename the active session |
| `:FantasyAttach {file} [prompt]` | Attach an image/audio file and send |
| `:FantasyCompact [id]` | Manually compact a session's context |
| `:FantasyStop` | Kill the server process |

Output window: `q` closes, `Y` copies the full response to the clipboard.

Confirm dialogs (`file.confirm`, `shell.confirm`): `<CR>` accepts, `q` cancels.

## Health check

Run `:checkhealth fantasy` to verify the server binary, base64 encoder, and
optional dependencies.

## Troubleshooting

- **"server not running"** — the binary isn't on `PATH` or failed to spawn.
  Check `:messages` for the startup error; the server also logs to stderr.
- **"Server is busy"** — only one `chat.send` may run at a time; wait for the
  current response to finish.
- **`fantasy.db` location** — created in Neovim's cwd at spawn time; it does
  not move when you `:cd` (only the agent's working directory is synced via
  `set.cwd`).
