#!/usr/bin/env bash
# PreToolUse hook: blocks re-reading a file that was already read (and not
# changed since) earlier in this Claude Code session.
#
# Written in pure Bash, using built-in string handling instead of external
# tools (grep, sed, awk, cksum, mkdir...) wherever possible, since spawning
# a process is the main source of latency on Windows. The only external
# program used is `stat` (file modification time), since Bash has no
# built-in equivalent.
#
# To disable without editing settings.json: create a file called
# `read-once.disabled` next to this script.
#   touch ~/.claude/hooks/read-once.disabled   # turn off
#   rm ~/.claude/hooks/read-once.disabled      # turn back on

if [[ -f "${BASH_SOURCE[0]%/*}/read-once.disabled" ]]; then
  exit 0
fi

IFS= read -r -d '' input

# Flatten to one line so parsing works whether Claude Code sends compact or
# pretty-printed JSON.
flat_input="${input//$'\n'/ }"

extract_json_string() {
  # $1 = JSON key name; parses `"key": "value"` out of $flat_input.
  local key="$1"
  if [[ "$flat_input" =~ \"$key\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

tool_name=$(extract_json_string "tool_name")
file_path=$(extract_json_string "file_path")
session_id=$(extract_json_string "session_id")
hook_event_name=$(extract_json_string "hook_event_name")

# PreCompact: session_id stays the same across a compact, but the
# transcript itself gets rewritten/summarized, so a file recorded here as
# "already read" may no longer actually be present verbatim afterward.
# Clear this session's cache so reads after a compact aren't wrongly
# blocked. Fires for both manual (/compact) and automatic compaction.
if [[ "$hook_event_name" == "PreCompact" ]]; then
  rm -f "/tmp/claude_read_cache_${session_id:-default}"
  exit 0
fi

# Only act on the Read tool
if [[ "$tool_name" != "Read" ]]; then
  exit 0
fi

if [[ -z "$file_path" ]]; then
  exit 0
fi

# Windows paths are case-insensitive; Unix paths are case-sensitive. Treat
# a path containing a backslash as Windows-style and normalize it to
# lowercase so "C:\Foo.txt" and "c:\foo.txt" match. Forward-slash paths
# keep their original case.
lookup_path="$file_path"
if [[ "$file_path" == *\\* ]]; then
  lookup_path="${file_path,,}"
fi

# Hash the path (not its content) so the cache key can't contain a
# character that collides with the storage format below. Simple DJB2-style
# string hash - just needs to be consistent, not cryptographically strong.
path_hash=5381
for (( i = 0; i < ${#lookup_path}; i++ )); do
  printf -v _char_code '%d' "'${lookup_path:i:1}"
  path_hash=$(( (path_hash * 33 + _char_code) & 0xFFFFFFFF ))
done

cache_file="/tmp/claude_read_cache_${session_id:-default}"

# Housekeeping: delete cache files left behind by sessions older than a
# day, so /tmp doesn't accumulate them forever. Only runs on ~1 in 20
# calls - purely a cleanup cadence, unrelated to the block/allow logic
# below, which always runs in full on every call.
if (( RANDOM % 20 == 0 )); then
  find /tmp -maxdepth 1 -name 'claude_read_cache_*' -type f -mtime +1 -delete 2>/dev/null
fi

# GNU stat (Linux/Git Bash) uses -c %Y; BSD stat (macOS) uses -f %m.
current_mtime=$(stat -c %Y "$file_path" 2>/dev/null || stat -f %m "$file_path" 2>/dev/null)

cached_mtime=""
found=0
if [[ -f "$cache_file" ]]; then
  while IFS=' ' read -r h m; do
    if [[ "$h" == "$path_hash" ]]; then
      cached_mtime="$m"
      found=1
      break
    fi
  done < "$cache_file"
fi

if (( found == 1 )); then
  if [[ "$cached_mtime" == "$current_mtime" ]]; then
    echo "File '$file_path' was already read earlier in this session and is already in your context. Do not re-read it — use the version you already have." >&2
    exit 2
  fi
  # File changed since it was cached: rewrite the cache without the stale
  # entry, then fall through to record the fresh read below.
  new_content=""
  while IFS=' ' read -r h m; do
    [[ "$h" == "$path_hash" ]] && continue
    new_content+="$h $m"$'\n'
  done < "$cache_file"
  printf '%s' "$new_content" > "$cache_file"
fi

printf '%s %s\n' "$path_hash" "$current_mtime" >> "$cache_file"
exit 0
