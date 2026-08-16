# claude-read-once-hook

A `PreToolUse` hook for [Claude Code](https://claude.com/claude-code) that stops the agent from repeatedly reading the same file during a session.

## Why

Claude Code will sometimes re-read a file it already has in context (e.g. after losing track of what it's seen). This hook intercepts every `Read` tool call, checks whether that file path has already been read this session, and blocks the second read — telling Claude the file's contents are already in its context instead of burning tokens re-fetching them.

## How it works

- The hook is registered on the `PreToolUse` event, matching the `Read` tool.
- On each `Read` call, Claude Code pipes a JSON payload (`session_id`, `tool_name`, `tool_input.file_path`, etc.) to the script on stdin.
- The script keeps a per-session cache file at `/tmp/claude_read_cache_<session_id>`, one file path per line.
- First read of a path: the path is appended to the cache, the hook exits `0` (allow).
- Repeat read of the same path: the hook exits `2` (block) and writes an explanation to stderr, which Claude Code surfaces back to the model as the reason the call was blocked.
- Any tool other than `Read` is ignored (exit `0`, no-op).

The script is pure Bash — no `jq` or other JSON tooling required.

## Installation

1. Copy the script into your Claude Code hooks directory:

   ```bash
   mkdir -p ~/.claude/hooks
   cp hooks/read-once.sh ~/.claude/hooks/read-once.sh
   chmod +x ~/.claude/hooks/read-once.sh
   ```

2. Add the hook to `~/.claude/settings.json`. If you already have a `hooks` key, merge this into it rather than replacing the file — see [`settings.snippet.json`](settings.snippet.json) for the exact block to add:

   ```json
   {
     "hooks": {
       "PreToolUse": [
         {
           "matcher": "Read",
           "hooks": [
             {
               "type": "command",
               "command": "~/.claude/hooks/read-once.sh"
             }
           ]
         }
       ]
     }
   }
   ```

3. Restart Claude Code (or start a new session) for the hook to take effect.

## Testing it manually

You can exercise the script directly without going through Claude Code:

```bash
echo '{"session_id":"test","tool_name":"Read","tool_input":{"file_path":"/some/file.txt"}}' | ~/.claude/hooks/read-once.sh
echo "exit code: $?"   # 0 — first read, allowed

echo '{"session_id":"test","tool_name":"Read","tool_input":{"file_path":"/some/file.txt"}}' | ~/.claude/hooks/read-once.sh
echo "exit code: $?"   # 2 — duplicate read, blocked
```

## Disabling temporarily

To turn the hook off without editing `settings.json`, create a file next to the script:

```bash
touch ~/.claude/hooks/read-once.disabled   # turn off
rm ~/.claude/hooks/read-once.disabled      # turn back on
```

The script checks for this file on every call, so no restart is needed either way.

## Notes

- The cache is per session (`session_id`) and lives under `/tmp`, so it's automatically scoped and doesn't persist across machine reboots.
- If you rename or restructure a file mid-session, its cache entry is keyed on the literal path, so a legitimately different path is never blocked.

## License

[MIT](LICENSE)

---

*This script and its hook configuration were written with [Claude Code](https://claude.com/claude-code) assistance.*
