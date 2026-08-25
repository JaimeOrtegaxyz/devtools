# devtools.zsh — lightweight dev-server helpers for interactive zsh
# Source this from ~/.zshrc (or install via install.sh)

devview() {
  echo "== Local servers =="
  lsof -nP -iTCP -sTCP:LISTEN | grep -iE 'COMMAND|node|python|ruby|php|deno|bun|java|dotnet|beam.smp' || true
  echo
  echo "== Dev processes =="
  ps aux | grep -E 'vite|npm run dev|next dev|node .*dev|esbuild' | grep -v grep || true
}

# --- name the tool from the process's OWN command line ---
# Lineage is unreliable: servers launched detached reparent to launchd (ppid 1),
# so the ancestor chain is gone. The argv is always there.
_devtools_tool_self() {
  local cmd="$1" name runner sub targ

  # .../node_modules/.bin/vite --port 5173  → vite
  name=$(print -r -- "$cmd" | sed -nE 's|.*/node_modules/\.bin/([A-Za-z0-9_.-]+).*|\1|p' | head -1)
  [ -n "$name" ] && { print -r -- "$name"; return }

  # python -m uvicorn / python -m flask  → uvicorn / flask
  name=$(print -r -- "$cmd" | sed -nE 's|.*python[0-9.]* +-m +([A-Za-z0-9_.]+).*|\1|p' | head -1)
  [ -n "$name" ] && { print -r -- "$name"; return }

  # npm/pnpm/yarn/bun run <script> → the runner ; run <file> or exec/dlx <tool> → the target
  if [[ "$cmd" =~ '(^|/)(npm|pnpm|yarn|bun) ((run|exec|dlx|x) )?(-[^ ]+ )*([A-Za-z0-9@_.:][A-Za-z0-9@_./:-]*)' ]]; then
    runner="${match[2]}" sub="${match[4]}" targ="${match[6]}"
    if [[ "$sub" == (exec|dlx|x) || "$targ" == *[./]* ]]; then
      print -r -- "${targ:t}"; return
    fi
    print -r -- "$runner"; return
  fi

  # node path/to/server.js → server.js ; ruby bin/rails → rails
  # node (npx remotion studio) → npx  — npm rewrites its title, ps wraps it in parens
  name=$(print -r -- "$cmd" | awk '{for(i=2;i<=NF;i++){if($i !~ /^-/){gsub(/^\(|\)$/,"",$i); if($i=="")continue; n=split($i,a,"/"); print a[n]; exit}}}')
  [ -n "$name" ] && { print -r -- "$name"; return }

  print -r -- ""
}

# --- name an app-owned listener (Raycast, Docker, Figma, …) ---
_devtools_app_label() {
  local pid="$1" exe="$2" cur ppid cmd n vendor

  # any ancestor running out of an .app bundle names the app
  cur="$pid"
  for n in {1..12}; do
    cmd=$(ps -o command= -p "$cur" 2>/dev/null)
    if [[ "$cmd" =~ '/([^/]+)\.app/Contents/MacOS/' ]]; then
      print -r -- "${match[1]}"; return
    fi
    ppid=$(ps -o ppid= -p "$cur" 2>/dev/null | tr -d ' ')
    [ -z "$ppid" ] || [ "$ppid" = "0" ] || [ "$ppid" = "1" ] && break
    cur="$ppid"
  done

  # else the executable's own path: /Applications/Foo.app/… or …/com.vendor.product/…
  [[ "$exe" =~ '/([^/]+)\.app/' ]] && { print -r -- "${match[1]}"; return }
  if [[ "$exe" =~ 'Application Support/[a-z]+\.([A-Za-z0-9_-]+)\.' ]]; then
    vendor="${match[1]}"
    print -r -- "${(C)vendor}"; return
  fi

  # last resort: the process's own short name
  print -r -- "$(ps -o comm= -p "$pid" 2>/dev/null | awk '{n=split($0,a,"/"); print a[n]}')"
}

# --- shared helper: collect info about listening dev servers ---
_devtools_scan() {
  _dt_rows=()
  _dt_ports=()
  _dt_pids=()
  _dt_projects=()
  _dt_other=()

  local -A seen_pids
  local -a listeners
  listeners=("${(@f)$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk '{cmd=tolower($1)} cmd~/node|python|ruby|php|deno|bun|java|dotnet|beam.smp/ {
    n = split($(NF-1), a, ":"); if (a[n]+0 > 0) print a[n], $2
  }')}")

  local line port pid cwd project tool cur ppid cmd git_root subpath url exe self_tool

  for line in "${listeners[@]}"; do
    port="${line%% *}"
    pid="${line##* }"
    [ -z "$pid" ] || [ -n "${seen_pids[$pid]}" ] && continue
    seen_pids[$pid]=1

    cwd=$(lsof -a -p "$pid" -d cwd 2>/dev/null | awk 'NR==2 {print $NF}')
    exe=$(lsof -a -p "$pid" -d txt -Fn 2>/dev/null | grep -m1 '^n/' | cut -c2-)
    cmd=$(ps -o command= -p "$pid" 2>/dev/null)

    git_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
    self_tool=$(_devtools_tool_self "$cmd")

    # Classify: is this one of MY projects, or something an app happens to run?
    local is_dev=0
    if [ -n "$git_root" ]; then
      is_dev=1
    elif [[ "$exe" == /Applications/* || "$exe" == */Library/Application\ Support/* || "$exe" == /System/* ]]; then
      is_dev=0
    elif [ -n "$self_tool" ] && [[ "$cwd" == "$HOME"/* ]]; then
      is_dev=1
    fi

    if [ "$is_dev" -eq 0 ]; then
      _dt_other+=("$port|$pid|$(_devtools_app_label "$pid" "$exe")")
      continue
    fi

    project=$(basename "${git_root:-$cwd}")
    subpath="."
    if [ -n "$git_root" ] && [ "$cwd" != "$git_root" ]; then
      subpath="${cwd#$git_root/}"
    fi

    tool="${self_tool:-unknown}"

    # lineage is now only a fallback, for when argv says nothing useful
    if [ "$tool" = "unknown" ]; then
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
    fi

    url="http://localhost:$port"

    _dt_rows+=("$port|$pid|$tool|$project|$subpath|$url")
    _dt_ports+=("$port")
    _dt_pids+=("$pid")
    _dt_projects+=("$project")
  done
}

_devtools_print_other() {
  [ ${#_dt_other[@]} -eq 0 ] && return

  local dim=$'\033[2m'
  local reset=$'\033[0m'
  local entry pw=0 idx
  local -a cols

  for entry in "${_dt_other[@]}"; do
    cols=("${(@s/|/)entry}")
    [ ${#cols[1]} -gt $pw ] && pw=${#cols[1]}
  done

  echo
  echo "${dim}== Other listeners ==${reset}"
  for entry in "${_dt_other[@]}"; do
    cols=("${(@s/|/)entry}")
    printf "%s  :%-${pw}s  %s (pid %s)%s\n" "$dim" "${cols[1]}" "${cols[3]}" "${cols[2]}" "$reset"
  done
}

devwho() {
  _devtools_scan

  if [ ${#_dt_rows[@]} -eq 0 ]; then
    echo "No local dev servers found."
    _devtools_print_other
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

  _devtools_print_other
}

# collect the "other listeners" into the kill set, after an explicit confirmation
_devtools_confirm_others() {
  [ ${#_dt_other[@]} -eq 0 ] && { echo "No other listeners to kill."; return 1; }

  local entry
  local -a ocols
  echo
  echo "This also kills apps that are not your projects:"
  for entry in "${_dt_other[@]}"; do
    ocols=("${(@s/|/)entry}")
    echo "  :${ocols[1]}  ${ocols[3]} (pid ${ocols[2]})"
  done
  printf "Type 'yes' to include them: "
  local confirm
  read -r confirm
  [ "$confirm" = "yes" ]
}

devkill() {
  local target="$1"

  _devtools_scan

  if [ ${#_dt_rows[@]} -eq 0 ] && [ ${#_dt_other[@]} -eq 0 ]; then
    echo "No local dev servers found."
    return
  fi

  local -a kill_pids kill_labels
  local idx entry
  local -a ocols

  # 'all' / 'all!' work as arguments too
  if [ "$target" = "all" ] || [ "$target" = "all!" ]; then
    local choice="$target"
    target=""
    _devtools_kill_all "$choice" || return 1
    _devtools_do_kill
    return
  fi

  if [ -z "$target" ]; then
    # no args: show numbered list, let user pick
    echo "Running dev servers:"
    for idx in {1..${#_dt_rows[@]}}; do
      local -a cols
      cols=("${(@s/|/)_dt_rows[$idx]}")
      echo "  $idx) :${cols[1]}  ${cols[4]}  (${cols[3]}, pid ${cols[2]})"
    done
    echo
    if [ ${#_dt_other[@]} -gt 0 ]; then
      printf "Kill which? (number, 'all' = my servers, 'all!' = + other listeners, Enter to cancel): "
    else
      printf "Kill which? (number, 'all', or Enter to cancel): "
    fi
    local choice
    read -r choice
    [ -z "$choice" ] && return

    if [ "$choice" = "all" ] || [ "$choice" = "all!" ]; then
      _devtools_kill_all "$choice" || return 1
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
      # don't just say "not found" if it's a listener we deliberately excluded
      for entry in "${_dt_other[@]}"; do
        ocols=("${(@s/|/)entry}")
        if [ "${ocols[1]}" = "$target" ]; then
          echo ":$target is ${ocols[3]} (pid ${ocols[2]}), not a project dev server."
          echo "Kill it yourself if you mean to: kill ${ocols[2]}"
          return 1
        fi
      done
      echo "No server matching '$target'."
      return 1
    fi
  fi

  _devtools_do_kill
}

# fill kill_pids/kill_labels for 'all' (my servers) or 'all!' (everything listening)
_devtools_kill_all() {
  local mode="$1" idx entry

  for idx in {1..${#_dt_pids[@]}}; do
    kill_pids+=("${_dt_pids[$idx]}")
    kill_labels+=(":${_dt_ports[$idx]} ${_dt_projects[$idx]}")
  done

  if [ "$mode" = "all!" ]; then
    _devtools_confirm_others || { echo "Cancelled."; return 1; }
    for entry in "${_dt_other[@]}"; do
      ocols=("${(@s/|/)entry}")
      kill_pids+=("${ocols[2]}")
      kill_labels+=(":${ocols[1]} ${ocols[3]}")
    done
  fi
  return 0
}

_devtools_do_kill() {
  local idx
  for idx in {1..${#kill_pids[@]}}; do
    kill "${kill_pids[$idx]}" 2>/dev/null && \
      echo "Killed ${kill_labels[$idx]} (pid ${kill_pids[$idx]})" || \
      echo "Failed to kill pid ${kill_pids[$idx]}"
  done
}
