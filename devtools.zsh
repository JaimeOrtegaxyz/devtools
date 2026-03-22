# devtools.zsh — lightweight dev-server helpers for interactive zsh
# Source this from ~/.zshrc (or install via install.sh)

devview() {
  echo "== Local servers =="
  lsof -nP -iTCP -sTCP:LISTEN | grep -E 'COMMAND|node|python|ruby|php' || true
  echo
  echo "== Dev processes =="
  ps aux | grep -E 'vite|npm run dev|next dev|node .*dev|esbuild' | grep -v grep || true
}

devwho() {
  local rows=()
  local headers=("PORT" "PID" "TOOL" "PROJECT" "TTY" "STATE")
  local widths=()
  local port pid cwd project tty state tool cur ppid cmd row
  local bold reset
  local i

  for port in 3000 5173 8080 8081; do
    pid=$(lsof -ti tcp:$port -sTCP:LISTEN 2>/dev/null | head -n 1)
    [ -z "$pid" ] && continue

    cwd=$(lsof -a -p "$pid" -d cwd 2>/dev/null | awk 'NR==2 {print $NF}')
    project=$(basename "$cwd")

    tty=$(ps -o tty= -p "$pid" | xargs)
    [ -z "$tty" ] && tty="?"
    state="attached"
    [ "$tty" = "??" ] && state="detached"

    tool="unknown"
    cur="$pid"

    for _ in 1 2 3 4 5 6; do
      ppid=$(ps -o ppid= -p "$cur" 2>/dev/null | tr -d ' ')
      [ -z "$ppid" ] && break
      cmd=$(ps -o command= -p "$ppid" 2>/dev/null)
      [ -z "$cmd" ] && break

      [[ "$cmd" =~ '/Applications/Claude.app|/\.claude/' ]] && tool="Claude"
      [[ "$cmd" =~ '/Applications/Collaborator.app|tmux -L collab' ]] && tool="Collaborator"
      [[ "$cmd" =~ 'tmux' ]] && [ "$tool" = "unknown" ] && tool="tmux"
      [[ "$cmd" =~ 'ghostty' ]] && [ "$tool" = "unknown" ] && tool="Ghostty"
      [[ "$cmd" =~ 'cursor' ]] && [ "$tool" = "unknown" ] && tool="Cursor"

      cur="$ppid"
    done

    rows+=("$port|$pid|$tool|$project|$tty|$state")
  done

  if [ ${#rows[@]} -eq 0 ]; then
    echo "No local dev servers found on the tracked ports."
    return
  fi

  for i in 1 2 3 4 5 6; do
    widths[$i]=${#headers[$i]}
  done

  for row in "${rows[@]}"; do
    local -a cols
    cols=("${(@s/|/)row}")
    for i in 1 2 3 4 5 6; do
      [ ${#cols[$i]} -gt ${widths[$i]} ] && widths[$i]=${#cols[$i]}
    done
  done

  bold=$'\033[1m'
  reset=$'\033[0m'

  print_border() {
    local left="$1" mid="$2" right="$3"
    printf "%s" "$left"
    for i in 1 2 3 4 5 6; do
      printf " %-${widths[$i]}s " "" | tr ' ' '─'
      [ "$i" -lt 6 ] && printf "%s" "$mid" || printf "%s\n" "$right"
    done
  }

  print_row() {
    local -a vals
    vals=("$@")
    printf "│"
    for i in 1 2 3 4 5 6; do
      printf " %-${widths[$i]}s " "${vals[$i]}"
      [ "$i" -lt 6 ] && printf "│" || printf "│\n"
    done
  }

  print_border "┌" "┬" "┐"

  printf "│"
  for i in 1 2 3 4 5 6; do
    printf " %s%-${widths[$i]}s%s " "$bold" "${headers[$i]}" "$reset"
    [ "$i" -lt 6 ] && printf "│" || printf "│\n"
  done

  print_border "├" "┼" "┤"

  for row in "${rows[@]}"; do
    local -a cols
    cols=("${(@s/|/)row}")
    print_row "${cols[@]}"
  done

  print_border "└" "┴" "┘"
}
