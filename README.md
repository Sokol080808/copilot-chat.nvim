# copilot-chat.nvim

A Copilot-style chat panel for Neovim, backed by the official GitHub Copilot CLI.

## What it does

- Right-side chat panel with a stacked history view and a multi-line input box.
- Streams replies token-by-token from `copilot -p ... --output-format json`.
- Multi-turn conversation handled by the CLI itself via `copilot --resume=<uuid>` — no manual history reserialization.
- Explicit edit mode (`:CopilotChatEdit`): the model returns the full updated file, the plugin shows an inline diff in the source buffer, and you accept or skip with a command.

## Requirements

- Neovim 0.9+ (uses `vim.diff`, `nvim_set_option_value`, extmark virt_lines).
- GitHub Copilot CLI: `npm install -g @github/copilot`.
- An authenticated Copilot session: run `copilot login` once (or `:CopilotChatLogin` from inside Neovim).

## Install

### lazy.nvim

```lua
{
  "Sokol080808/copilot-chat.nvim",
  config = function()
    require("copilot-chat").setup()
  end,
}
```

### packer.nvim

```lua
use({
  "Sokol080808/copilot-chat.nvim",
  config = function() require("copilot-chat").setup() end,
})
```

## Commands

| Command                       | Description                                                          |
| ----------------------------- | -------------------------------------------------------------------- |
| `:CopilotChat`                | Toggle the chat panel.                                               |
| `:CopilotChatOpen`            | Open the chat panel.                                                 |
| `:CopilotChatClose`           | Close the chat panel.                                                |
| `:CopilotChatAsk`             | Focus the input (or `:CopilotChatAsk <prompt>` to send; range OK).   |
| `:CopilotChatEdit`            | Edit current buffer; accepts a range and an optional prompt.         |
| `:CopilotChatExplain`         | `/explain` shortcut. Range OK.                                       |
| `:CopilotChatTests`           | `/tests` shortcut. Range OK.                                         |
| `:CopilotChatFix`             | `/fix` shortcut. Range OK.                                           |
| `:CopilotChatDoc`             | `/doc` shortcut. Range OK.                                           |
| `:CopilotChatOptimize`        | `/optimize` shortcut. Range OK.                                      |
| `:CopilotChatReview`          | `/review` shortcut. Range OK.                                        |
| `:CopilotChatFixDiagnostic`   | Submit the diagnostic at the cursor as an edit request.              |
| `:CopilotChatNew`             | Start a fresh Copilot session (rotates the session UUID).            |
| `:CopilotChatApply`           | Accept the pending inline edit preview.                              |
| `:CopilotChatSkip`            | Reject the pending inline edit preview and restore content.          |
| `:CopilotChatCancel`          | Cancel an in-flight reply.                                           |
| `:CopilotChatLogin`           | Open `copilot login` in a terminal split.                            |

## Slash commands and references (in the input box)

- `/explain`, `/tests`, `/fix`, `/doc`, `/optimize`, `/review` — pre-baked prompts. Add free-form text after the slash to focus the request (`/explain how does the auth flow work`).
- `/help` lists slash commands. `/clear` starts a new session.
- `#file:path/to/foo.lua` inlines that file's contents into the prompt sent to Copilot. The path is resolved relative to your cwd or absolutely if it starts with `/`. Multiple references are fine.
- `@workspace` nudges Copilot to actively search the workspace before answering (it already has filesystem access, this just tells it to use it).

`<Tab>` in the input box triggers context-aware completion: slash commands after `/`, `git ls-files` results after `#file:`. Otherwise it inserts a literal Tab.

## Keybindings inside the chat

- **Input (insert mode):** `<C-s>` to send. `<Tab>` for completion (after `/` or `#file:`).
- **Input (normal mode):** `<CR>` to send, `q` to close.
- **Chat history:** `i` / `a` / `<CR>` to focus the input, `q` to close.

## Optional default keymaps

Set `default_keymaps = true` in `setup()` to install:

| Mapping        | Action                                |
| -------------- | ------------------------------------- |
| `<leader>cc`   | Toggle chat                           |
| `<leader>ca`   | Ask (visual: ask about selection)     |
| `<leader>ci`   | Edit current file (visual: selection) |
| `<leader>cf`   | Fix diagnostic at cursor              |
| `<leader>cn`   | New session                           |

## Edit flow

```vim
:CopilotChatEdit add a docstring to this function
" or with a visual range:
:'<,'>CopilotChatEdit refactor this block to use early returns
```

1. The plugin sends the file (and the selected range, if any) to Copilot.
2. The model is instructed to return the complete updated file in a `` ```UPDATE `` fenced block.
3. The new content is shown inline in the source buffer with `DiffAdd` / `DiffChange` highlights and `DiffDelete` virtual lines for removed text.
4. `:CopilotChatApply` keeps the change. `:CopilotChatSkip` restores the original.

## Configuration

```lua
require("copilot-chat").setup({
  -- Prepended to the very first user message in a session. nil disables.
  system_prompt = nil,
  -- Fence tag the model is asked to use for whole-file replacements.
  edit_fence_tag = "UPDATE",
  -- Install <leader>c{c,a,i,f,n} mappings.
  default_keymaps = false,
  -- Load a guide file (default: the plugin's bundled GUIDE.md) and prepend
  -- it to the first user message of every session. The CLI keeps it in
  -- conversation memory via --resume, so subsequent turns don't re-pay the
  -- token cost. Set false to disable; the [Editor context] block still ships
  -- every turn either way.
  use_guide = true,
  -- Override path to a custom guide file. nil → bundled GUIDE.md.
  guide_path = nil,
})
```

## How Copilot is briefed

There are two layers:

1. **Bundled `GUIDE.md`** (sent once per session, on the first user message). Lives at `lua/copilot-chat/GUIDE.md`. Tells Copilot about the edit/apply diff-preview flow, the strong "prefer in-place edits" default, tool-usage hints, response style, and the slash/reference shortcuts. Override with `guide_path = "/your/own.md"` in `setup()`, or set `use_guide = false` to skip it entirely. After the first turn, the CLI keeps the guide in its own session memory (`--resume`), so subsequent prompts don't re-send it — you pay the token cost once.

2. **Per-turn `[Editor context]` block** (sent every turn — it's genuinely dynamic):



Each chat request prepends a small block telling Copilot:

```
[Editor context]
cwd: /path/to/project
active file: lua/foo.lua (cursor: line 42)
other open files:
  - lua/bar.lua
  - lua/baz.lua
[End of editor context]
```

When invoked with a range (`:'<,'>CopilotChatAsk explain`), the selected lines are inlined too. The CLI is spawned with `cwd = vim.fn.getcwd()` and `--add-dir` for any open buffer outside cwd, so Copilot's `view` tool can actually read the files it's been told about.

## How session state works

Each chat panel has a session UUID, generated lazily on the first request and reused for every subsequent call via `--resume=<uuid>`. This delegates conversation memory to the Copilot CLI instead of resending history on every turn. `:CopilotChatNew` rotates the UUID to start a clean conversation.

## Notice

This plugin is mostly AI-generated code. Review before relying on it.
