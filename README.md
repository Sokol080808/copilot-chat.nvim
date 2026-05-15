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

| Command              | Description                                                   |
| -------------------- | ------------------------------------------------------------- |
| `:CopilotChat`       | Toggle the chat panel.                                        |
| `:CopilotChatOpen`   | Open the chat panel.                                          |
| `:CopilotChatClose`  | Close the chat panel.                                         |
| `:CopilotChatAsk`    | Focus the input box (or `:CopilotChatAsk <prompt>` to send).  |
| `:CopilotChatEdit`   | Edit current buffer; accepts a range and an optional prompt.  |
| `:CopilotChatNew`    | Start a fresh Copilot session (rotates the session UUID).     |
| `:CopilotChatApply`  | Accept the pending inline edit preview.                       |
| `:CopilotChatSkip`   | Reject the pending inline edit preview and restore content.   |
| `:CopilotChatCancel` | Cancel an in-flight reply.                                    |
| `:CopilotChatLogin`  | Open `copilot login` in a terminal split.                     |

## Keybindings inside the chat

- **Input box (insert mode):** `<C-s>` to send.
- **Input box (normal mode):** `<CR>` to send, `q` to close.
- **Chat history:** `i` / `a` / `<CR>` to focus the input, `q` to close.

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
})
```

## How session state works

Each chat panel has a session UUID, generated lazily on the first request and reused for every subsequent call via `--resume=<uuid>`. This delegates conversation memory to the Copilot CLI instead of resending history on every turn. `:CopilotChatNew` rotates the UUID to start a clean conversation.

## Notice

This plugin is mostly AI-generated code. Review before relying on it.
