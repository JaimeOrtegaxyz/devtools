# devtools.zsh — lightweight dev-server helpers for interactive zsh
# Source this from ~/.zshrc (or install via install.sh)

# semantic colors — color means something here, it doesn't decorate
typeset -g _dt_reset=$'\033[0m' _dt_bold=$'\033[1m' _dt_dim=$'\033[2m'
typeset -g _dt_red=$'\033[31m' _dt_green=$'\033[32m' _dt_yellow=$'\033[33m'
typeset -g _dt_blue=$'\033[34m' _dt_mag=$'\033[35m'

devview() {
  echo "== Local servers =="
  lsof -nP -iTCP -sTCP:LISTEN | grep -iE 'COMMAND|node|python|ruby|php|deno|bun|java|dotnet|beam.smp' || true
  echo
  echo "== Dev processes =="
  ps aux | grep -E 'vite|npm run dev|next dev|node .*dev|esbuild' | grep -v grep || true
}

# --- generic table renderer ---
# reads: _dtt_headers, _dtt_align (l/r per column), _dtt_rows (cells joined
# with $'\x1f'). Cells may carry ANSI colors; widths are measured without them.
_devtools_render_table() {
  setopt localoptions extendedglob
  local ncols=${#_dtt_headers[@]}
  local -a widths
  local i row plain cell pad
  local -a cols

  for i in {1..$ncols}; do
    widths[$i]=${#_dtt_headers[$i]}
  done
  for row in "${_dtt_rows[@]}"; do
    cols=("${(@ps/\x1f/)row}")
    for i in {1..$ncols}; do
      plain=${cols[$i]//$'\e'\[[0-9;]#m/}
      [ ${#plain} -gt ${widths[$i]} ] && widths[$i]=${#plain}
    done
  done

  _dtt_border() {
    # pure-zsh fill: the printf|tr version forked two processes per segment
    local out="$1" w
    for i in {1..$ncols}; do
      w=$(( ${widths[$i]} + 2 ))
      out+="${(l:$w::─:):-}"
      [ "$i" -lt "$ncols" ] && out+="$2" || out+="$3"
    done
    print -r -- "$out"
  }

  _dtt_print_row() {
    local -a vals
    vals=("$@")
    printf "│"
    for i in {1..$ncols}; do
      cell="${vals[$i]}"
      plain=${cell//$'\e'\[[0-9;]#m/}
      pad=$(( ${widths[$i]} - ${#plain} ))
      if [ "${_dtt_align[$i]}" = "r" ]; then
        printf " %*s%s │" "$pad" "" "$cell"
      else
        printf " %s%*s │" "$cell" "$pad" ""
      fi
    done
    printf "\n"
  }

  local -a hdr
  for i in {1..$ncols}; do
    hdr+=("${_dt_bold}${_dtt_headers[$i]}${_dt_reset}")
  done

  _dtt_border "┌" "┬" "┐"
  _dtt_print_row "${hdr[@]}"
  _dtt_border "├" "┼" "┤"
  for row in "${_dtt_rows[@]}"; do
    cols=("${(@ps/\x1f/)row}")
    _dtt_print_row "${cols[@]}"
  done
  _dtt_border "└" "┴" "┘"
}

# Render _dtt_* as one table — or, when the table would scroll off the screen
# and the terminal is wide enough, as two side-by-side halves (read down the
# left table first, like ls columns).
_devtools_render_table_fit() {
  setopt localoptions extendedglob
  local rows=${#_dtt_rows[@]}
  local lines=${LINES:-24} cols=${COLUMNS:-80}

  # 4 = top border + header + rule + bottom border
  if (( rows < 4 || rows + 4 <= lines )); then
    _devtools_render_table
    return
  fi

  local -a all lt rt
  all=("${_dtt_rows[@]}")
  local half=$(( (rows + 1) / 2 ))

  _dtt_rows=("${(@)all[1,$half]}")
  lt=("${(@f)$(_devtools_render_table)}")
  _dtt_rows=("${(@)all[$half+1,-1]}")
  rt=("${(@f)$(_devtools_render_table)}")
  _dtt_rows=("${all[@]}")

  # each table's visible width = its top border (no ANSI codes there)
  local lw=${#lt[1]} gap=2
  if (( lw + gap + ${#rt[1]} > cols )); then
    _devtools_render_table
    return
  fi

  local i l plain
  for i in {1..${#lt[@]}}; do
    l="${lt[$i]}"
    if (( i <= ${#rt[@]} )); then
      plain=${l//$'\e'\[[0-9;]#m/}
      printf "%s%*s%*s%s\n" "$l" $(( lw - ${#plain} )) "" "$gap" "" "${rt[$i]}"
    else
      print -r -- "$l"
    fi
  done
}

# 4.2K / 356K / 1.2M, ls -h style. Returns via REPLY: a $(…) call would
# fork a subshell per file, which is exactly what makes shell loops slow.
_devtools_human_size() {
  local b=$1
  local -a units=(B K M G T)
  local i=1
  local -F v=$b
  while (( v >= 1024 && i < 5 )); do
    v=$(( v / 1024.0 ))
    (( i++ ))
  done
  if (( i == 1 )); then
    REPLY="${b}${units[$i]}"
  elif (( v >= 10 )); then
    printf -v REPLY "%.0f%s" "$v" "${units[$i]}"
  else
    printf -v REPLY "%.1f%s" "$v" "${units[$i]}"
  fi
}

# 45s / 12m / 3h / 5d / 2w / 4mo / 1y from an age in seconds. Returns via REPLY.
_devtools_rel_time() {
  local s=$1
  [ "$s" -lt 0 ] && s=0
  if   [ "$s" -lt 60 ];       then REPLY="${s}s"
  elif [ "$s" -lt 3600 ];     then REPLY="$(( s / 60 ))m"
  elif [ "$s" -lt 86400 ];    then REPLY="$(( s / 3600 ))h"
  elif [ "$s" -lt 604800 ];   then REPLY="$(( s / 86400 ))d"
  elif [ "$s" -lt 2592000 ];  then REPLY="$(( s / 604800 ))w"
  elif [ "$s" -lt 31536000 ]; then REPLY="$(( s / 2592000 ))mo"
  else                             REPLY="$(( s / 31536000 ))y"
  fi
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

  _dtt_headers=("PORT" "PID" "TOOL" "PROJECT" "PATH" "URL")
  _dtt_align=(r r l l l l)
  _dtt_rows=()

  local row
  local -a cols
  for row in "${_dt_rows[@]}"; do
    cols=("${(@s/|/)row}")
    _dtt_rows+=("${(pj/\x1f/)cols}")
  done

  _devtools_render_table_fit
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

# --- devls: ls as a table, newest first ---
# NAME:     blue dir, magenta symlink, red executable (ls -G conventions)
# MODIFIED: green under an hour, dimmed past a week
# GIT:      green ✓ clean, yellow ±N dirty, magenta branch when not main/master;
#           yellow ↓N behind / ↑N ahead of upstream, ↑? branch has no upstream,
#           $N stashes, red ! when a fetch failed
# -f:       git fetch every repo first, so ↓/↑ reflect the remote right now
#           (otherwise they reflect the last fetch, whenever that was)
# -g:       sort by git standing — most out of sync first, then clean, then the rest
# -n:       sort by name instead of mtime (-o reverses either)
devls() {
  zmodload -F zsh/stat b:zstat 2>/dev/null
  zmodload zsh/datetime 2>/dev/null
  setopt localoptions extendedglob

  local dir="." show_hidden=0 oldest=0 quick=0 bygit=0 byname=0 fetch=0 arg f
  for arg in "$@"; do
    case "$arg" in
      -*)
        for f in ${(s::)${arg#-}}; do   # flags bundle: -aq == -a -q
          case "$f" in
            a) show_hidden=1 ;;
            f) fetch=1 ;;
            g) bygit=1 ;;
            n) byname=1 ;;
            o) oldest=1 ;;
            q) quick=1 ;;
            *) echo "devls: unknown flag -$f (have: -a -f -g -n -o -q)"; return 1 ;;
          esac
        done ;;
      *) dir="$arg" ;;
    esac
  done
  [ -d "$dir" ] || { echo "devls: not a directory: $dir"; return 1; }
  if [ "$bygit" -eq 1 ] && [ "$quick" -eq 1 ]; then
    echo "devls: -g sorts by the clean/dirty check that -q skips"; return 1
  fi
  if [ "$fetch" -eq 1 ] && [ "$quick" -eq 1 ]; then
    echo "devls: -f fetches and checks every repo; -q skips exactly that"; return 1
  fi

  local -a entries
  local ord=om                          # mtime, newest first
  [ "$byname" -eq 1 ] && ord=on         # -n: name, A→Z
  [ "$oldest" -eq 1 ] && ord=O${ord#o}  # -o: reverse either order
  [ "$show_hidden" -eq 1 ] && entries=("$dir"/*(ND${ord})) || entries=("$dir"/*(N${ord}))
  if [ ${#entries[@]} -eq 0 ]; then
    echo "Empty."
    return
  fi

  local e name kind size mod git_cell branch dirty n row w k i
  local stash ns bh ah flags sync
  local now=$EPOCHSECONDS age has_git=0 gitdir=""
  local -A st
  local -a sub repos sl

  # The dirty check forks one `git status` per repo — the dominant cost.
  # Run them all concurrently up front; wall time becomes the slowest one.
  # No --no-optional-locks: each repo has its own index lock, so parallel
  # statuses across repos never contend — and the flag blocks the refreshed
  # stat-cache write-back, leaving a stale-index repo (rsync/iCloud/copied
  # clone) to re-hash every file on every run. Letting status heal the index
  # makes the first run pay once and every later run ~10ms.
  # With -f each job fetches first and the table waits for the slowest fetch —
  # a big pack takes as long as it takes (Ctrl-C if you can't wait; the fetches
  # finish on their own). What it never does is hang: no credential prompts,
  # no auto-gc, and a transfer that stalls is aborted and shown as a red !.
  for e in "${entries[@]}"; do
    [ -d "$e" ] && [ ! -h "$e" ] && [ -e "$e/.git" ] && repos+=("$e")
  done
  if [ "$quick" -eq 0 ] && [ ${#repos[@]} -gt 0 ]; then
    gitdir=$(mktemp -d)
    [ "$fetch" -eq 1 ] && [ -t 2 ] && print -nu2 -- "fetching ${#repos} repos…"
    ( # subshell so an interactive shell doesn't announce the background jobs
      local r out j=0   # n/bh/ah/flags are the function's locals; a re-`local`
                        # here would make zsh print them
      local -a olines
      for r in "${repos[@]}"; do
        {
          flags=""
          if [ "$fetch" -eq 1 ] && [ -n "$(git -C "$r" remote 2>/dev/null)" ]; then
            GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=10' \
              git -C "$r" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 \
                fetch --prune --no-auto-maintenance -q >/dev/null 2>&1 || flags+="F"
          fi
          out=$(git -C "$r" status --porcelain 2>/dev/null)
          n=0
          if [ -n "$out" ]; then
            # explicit array: inline ${#${(f)out}} gives strlen when out is one line
            olines=("${(@f)out}")
            n=${#olines}
          fi
          # behind/ahead of the tracking branch: local refs only, no network
          bh=0; ah=0
          if out=$(git -C "$r" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null); then
            bh=${out%%[[:space:]]*}; ah=${out##*[[:space:]]}
          elif [ -n "$(git -C "$r" remote 2>/dev/null)" ]; then
            flags+="U"   # has a remote, but this branch tracks nothing there
          fi
          print -r -- "$n $bh $ah $flags" > "$gitdir/${r:t}"
        } &
        (( ++j % 64 == 0 )) && wait
      done
      wait
    )
    [ "$fetch" -eq 1 ] && [ -t 2 ] && print -nu2 -- $'\r\e[K'
  fi

  _dtt_rows=()
  for e in "${entries[@]}"; do
    name="${e:t}"
    zstat -L -H st "$e" 2>/dev/null || continue
    age=$(( now - ${st[mtime]} ))
    git_cell=""
    w=0

    if [ -h "$e" ]; then
      kind="link"
      _devtools_human_size "${st[size]}"; size=$REPLY
      name="${_dt_mag}${name}${_dt_reset}"
    elif [ -d "$e" ]; then
      sub=("$e"/*(ND))
      size="${#sub} items"
      [ ${#sub} -eq 1 ] && size="1 item"
      kind="dir"
      [ -e "$e/.git" ] && kind="repo"
      name="${_dt_bold}${_dt_blue}${name}${_dt_reset}"
    else
      kind="file"
      _devtools_human_size "${st[size]}"; size=$REPLY
      [ -x "$e" ] && name="${_dt_red}${name}${_dt_reset}"
    fi

    _devtools_rel_time "$age"; mod=$REPLY
    if [ "$age" -lt 3600 ]; then
      mod="${_dt_green}${mod}${_dt_reset}"
    elif [ "$age" -ge 604800 ]; then
      mod="${_dt_dim}${mod}${_dt_reset}"
    fi

    if [ "$kind" = "repo" ]; then
      has_git=1
      branch=""
      if [ -f "$e/.git/HEAD" ]; then
        read -r branch < "$e/.git/HEAD"
        if [[ "$branch" == ref:* ]]; then
          branch="${branch#ref: refs/heads/}"
        else
          branch="${branch[1,7]}"   # detached HEAD: short hash
        fi
      else
        # .git is a file (worktree/submodule)
        branch=$(git -C "$e" branch --show-current 2>/dev/null)
      fi
      [ -z "$branch" ] && branch="?"

      # stashes: one reflog line each, read without a fork. Shown even with -q.
      # (A worktree's .git is a file; it shares the main checkout's stash anyway.)
      stash=""; ns=0
      if [ -s "$e/.git/logs/refs/stash" ]; then
        sl=("${(@f)$(<"$e/.git/logs/refs/stash")}")
        ns=${#sl}
        stash="${_dt_yellow}\$${ns}${_dt_reset}"
      fi

      sync=""
      if [ "$quick" -eq 1 ]; then
        dirty=""   # -q: no status run, so no clean/dirty or behind/ahead claim
      else
        n=0; bh=0; ah=0; flags=""
        [ -n "$gitdir" ] && [ -f "$gitdir/${e:t}" ] && read -r n bh ah flags < "$gitdir/${e:t}"
        if [ "$n" -gt 0 ]; then
          dirty="${_dt_yellow}±${n}${_dt_reset}"
        else
          dirty="${_dt_green}✓${_dt_reset}"
        fi
        [ "$bh" -gt 0 ] && sync+=" ${_dt_yellow}↓${bh}${_dt_reset}"
        [ "$ah" -gt 0 ] && sync+=" ${_dt_yellow}↑${ah}${_dt_reset}"
        [[ "$flags" == *U* ]] && sync+=" ${_dt_yellow}↑?${_dt_reset}"
        [[ "$flags" == *F* ]] && sync+=" ${_dt_red}!${_dt_reset}"
        # -g weight: anything pending beats clean (1), all repos beat non-repos (0)
        w=$(( n + bh + ah + ns + 1 ))
        [[ "$flags" == *U* ]] && (( w++ ))
      fi

      if [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
        git_cell="${branch}${dirty:+ $dirty}${sync}${stash:+ $stash}"
      else
        git_cell="${_dt_mag}${branch}${_dt_reset}${dirty:+ $dirty}${sync}${stash:+ $stash}"
      fi
    fi

    row="${name}"$'\x1f'"${kind}"$'\x1f'"${size}"$'\x1f'"${mod}"$'\x1f'"${git_cell}"
    if [ "$bygit" -eq 1 ]; then
      # fixed-width key so a plain string sort orders numerically: inverted
      # weight (dirtiest first), then row index (keeps the base sort as tie-break)
      k=$(( 999999 - w )); i=${#_dtt_rows}
      row="${(l:6::0:)k}${(l:6::0:)i}"$'\x1f'"$row"
    fi
    _dtt_rows+=("$row")
  done

  [ -n "$gitdir" ] && rm -rf "$gitdir"

  if [ "$bygit" -eq 1 ]; then
    _dtt_rows=("${(o)_dtt_rows[@]}")
    local -a resorted
    for row in "${_dtt_rows[@]}"; do resorted+=("${row#*$'\x1f'}"); done
    _dtt_rows=("${resorted[@]}")
  fi

  if [ "$has_git" -eq 1 ]; then
    _dtt_headers=("NAME" "KIND" "SIZE" "MODIFIED" "GIT")
    _dtt_align=(l l r r l)
  else
    _dtt_headers=("NAME" "KIND" "SIZE" "MODIFIED")
    _dtt_align=(l l r r)
    local -a trimmed
    local r
    for r in "${_dtt_rows[@]}"; do trimmed+=("${r%$'\x1f'}"); done
    _dtt_rows=("${trimmed[@]}")
  fi

  _devtools_render_table_fit
}
