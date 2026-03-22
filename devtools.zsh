# devtools.zsh — lightweight dev-server helpers for interactive zsh
# Source this from ~/.zshrc (or install via install.sh)

devview() {
  echo "== Local servers =="
  lsof -nP -iTCP -sTCP:LISTEN | grep -E 'COMMAND|node|python|ruby|php' || true
  echo
  echo "== Dev processes =="
  ps aux | grep -E 'vite|npm run dev|next dev|node .*dev|esbuild' | grep -v grep || true
}

# --- shared helper: collect info about listening dev servers ---
_devtools_scan() {
  _dt_rows=()
  _dt_ports=()
  _dt_pids=()
  _dt_projects=()

  local -A seen_pids
  local -a listeners
  listeners=("${(@f)$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk '/node|python|ruby|php|deno|bun/ {
    n = split($(NF-1), a, ":"); if (a[n]+0 > 0) print a[n], $2
  }')}")

  local line port pid cwd project tool cur ppid cmd

  for line in "${listeners[@]}"; do
    port="${line%% *}"
    pid="${line##* }"
    [ -z "$pid" ] || [ -n "${seen_pids[$pid]}" ] && continue
    seen_pids[$pid]=1

    cwd=$(lsof -a -p "$pid" -d cwd 2>/dev/null | awk 'NR==2 {print $NF}')
    local git_root
    git_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
    project=$(basename "${git_root:-$cwd}")
    local subpath="."
    if [ -n "$git_root" ] && [ "$cwd" != "$git_root" ]; then
      subpath="${cwd#$git_root/}"
    fi

    tool="unknown"
    cur="$pid"

    for _ in {1..12}; do
      ppid=$(ps -o ppid= -p "$cur" 2>/dev/null | tr -d ' ')
      [ -z "$ppid" ] || [ "$ppid" = "0" ] || [ "$ppid" = "1" ] && break
      cmd=$(ps -o command= -p "$ppid" 2>/dev/null)
      [ -z "$cmd" ] && break

      [[ "$cmd" =~ '/Applications/Claude.app|/\.claude/|^claude ' ]] && tool="Claude"
      [[ "$cmd" =~ '/Applications/Collaborator.app|tmux -L collab' ]] && tool="Collaborator"
      [[ "$cmd" =~ 'tmux' ]] && [ "$tool" = "unknown" ] && tool="tmux"
      [[ "$cmd" =~ 'ghostty' ]] && [ "$tool" = "unknown" ] && tool="Ghostty"
      [[ "$cmd" =~ 'cursor' ]] && [ "$tool" = "unknown" ] && tool="Cursor"

      cur="$ppid"
    done

    local url="http://localhost:$port"

    _dt_rows+=("$port|$pid|$tool|$project|$subpath|$url")
    _dt_ports+=("$port")
    _dt_pids+=("$pid")
    _dt_projects+=("$project")
  done
}

devwho() {
  _devtools_scan

  if [ ${#_dt_rows[@]} -eq 0 ]; then
    echo "No local dev servers found."
    return
  fi

  local headers=("PORT" "PID" "TOOL" "PROJECT" "PATH" "URL")
  local widths=()
  local ncols=6
  local i row

  for i in {1..$ncols}; do
    widths[$i]=${#headers[$i]}
  done

  for row in "${_dt_rows[@]}"; do
    local -a cols
    cols=("${(@s/|/)row}")
    for i in {1..$ncols}; do
      [ ${#cols[$i]} -gt ${widths[$i]} ] && widths[$i]=${#cols[$i]}
    done
  done

  local bold=$'\033[1m'
  local reset=$'\033[0m'

  print_border() {
    local left="$1" mid="$2" right="$3"
    printf "%s" "$left"
    for i in {1..$ncols}; do
      printf " %-${widths[$i]}s " "" | tr ' ' '─'
      [ "$i" -lt "$ncols" ] && printf "%s" "$mid" || printf "%s\n" "$right"
    done
  }

  print_row() {
    local -a vals
    vals=("$@")
    printf "│"
    for i in {1..$ncols}; do
      printf " %-${widths[$i]}s " "${vals[$i]}"
      [ "$i" -lt "$ncols" ] && printf "│" || printf "│\n"
    done
  }

  print_border "┌" "┬" "┐"

  printf "│"
  for i in {1..$ncols}; do
    printf " %s%-${widths[$i]}s%s " "$bold" "${headers[$i]}" "$reset"
    [ "$i" -lt "$ncols" ] && printf "│" || printf "│\n"
  done

  print_border "├" "┼" "┤"

  for row in "${_dt_rows[@]}"; do
    local -a cols
    cols=("${(@s/|/)row}")
    print_row "${cols[@]}"
  done

  print_border "└" "┴" "┘"
}

devkill() {
  local target="$1"

  _devtools_scan

  if [ ${#_dt_rows[@]} -eq 0 ]; then
    echo "No local dev servers found."
    return
  fi

  local -a kill_pids kill_labels
  local idx

  if [ -z "$target" ]; then
    # no args: show numbered list, let user pick
    echo "Running dev servers:"
    for idx in {1..${#_dt_rows[@]}}; do
      local -a cols
      cols=("${(@s/|/)_dt_rows[$idx]}")
      echo "  $idx) :${cols[1]}  ${cols[4]}  (${cols[3]}, pid ${cols[2]})"
    done
    echo
    printf "Kill which? (number, 'all', or Enter to cancel): "
    local choice
    read -r choice
    [ -z "$choice" ] && return

    if [ "$choice" = "all" ]; then
      for idx in {1..${#_dt_pids[@]}}; do
        kill_pids+=("${_dt_pids[$idx]}")
        kill_labels+=(":${_dt_ports[$idx]} ${_dt_projects[$idx]}")
      done
    elif [[ "$choice" =~ '^[0-9]+$' ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#_dt_rows[@]} ]; then
      kill_pids+=("${_dt_pids[$choice]}")
      kill_labels+=(":${_dt_ports[$choice]} ${_dt_projects[$choice]}")
    else
      echo "Invalid choice."
      return 1
    fi
  else
    # match by port number or project name
    for idx in {1..${#_dt_rows[@]}}; do
      if [ "${_dt_ports[$idx]}" = "$target" ] || [ "${_dt_projects[$idx]}" = "$target" ]; then
        kill_pids+=("${_dt_pids[$idx]}")
        kill_labels+=(":${_dt_ports[$idx]} ${_dt_projects[$idx]}")
      fi
    done

    if [ ${#kill_pids[@]} -eq 0 ]; then
      echo "No server matching '$target'."
      return 1
    fi
  fi

  for idx in {1..${#kill_pids[@]}}; do
    kill "${kill_pids[$idx]}" 2>/dev/null && \
      echo "Killed ${kill_labels[$idx]} (pid ${kill_pids[$idx]})" || \
      echo "Failed to kill pid ${kill_pids[$idx]}"
  done
}
