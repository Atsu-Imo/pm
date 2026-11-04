#!/usr/bin/env bash
# pm-lib.sh — pm 各コマンドで共有する設定と関数
# 他のスクリプトから `source` して使う。単体では実行しない。

set -euo pipefail

PM_VERSION="0.1.0"

# ---- 設定値（環境変数で上書き可能。~/.config/pm/config でも上書きできる）----
PM_CONFIG_DIR="${PM_CONFIG_DIR:-$HOME/.config/pm}"
if [ -f "$PM_CONFIG_DIR/config" ]; then
  # shellcheck disable=SC1091
  . "$PM_CONFIG_DIR/config"
fi

PM_SHARED="${PM_SHARED:-$HOME/pm}"                 # 親の起動場所（~/pm）。実体は symlink 先でもよい
PM_SESSION="${PM_SESSION:-pm}"                     # tmux セッション名
PM_TMUX_BIN="${PM_TMUX_BIN:-tmux}"                 # テストで差し替える
PM_TMUX_SOCKET="${PM_TMUX_SOCKET:-}"               # 空なら既定のソケット
PM_CLAUDE_BIN="${PM_CLAUDE_BIN:-claude}"
PM_PARENT_USER="${PM_PARENT_USER:-}"               # 空なら同一ユーザーで親を起動
PM_PARENT_RUN="${PM_PARENT_RUN:-/usr/local/bin/pm-parent-run}"  # 親ユーザーで claude を起動する root 所有のラッパ
PM_FIRST_WINDOW_CHILDREN="${PM_FIRST_WINDOW_CHILDREN:-4}"  # 1枚目のウィンドウに置く子の数
PM_CHILDREN_PER_WINDOW="${PM_CHILDREN_PER_WINDOW:-5}"      # 2枚目以降のウィンドウ1枚あたりの子の数
PM_STATUS_INTERVAL="${PM_STATUS_INTERVAL:-5}"      # 課題一覧ペインの更新間隔（秒）
PM_DISPATCH_INTERVAL="${PM_DISPATCH_INTERVAL:-2}"  # inbox 監視の間隔（秒）
PM_RESTART_WAIT="${PM_RESTART_WAIT:-180}"          # restart 時に引き継ぎメモ更新を待つ上限（秒）
PM_HANDOFF_STALE_MIN="${PM_HANDOFF_STALE_MIN:-30}" # 引き継ぎメモが古いと見なす分数

PM_WORKSPACES="$PM_CONFIG_DIR/workspaces"
PM_HANDOFF_DIR="$PM_CONFIG_DIR/handoff"
PM_STATE_DIR="$PM_CONFIG_DIR/state"
PM_GENERATED_DIR="$PM_CONFIG_DIR/generated"
PM_PANES="$PM_STATE_DIR/panes.tsv"
PM_STATUS_DIR="$PM_SHARED/status"
PM_INBOX_DIR="$PM_SHARED/inbox"
PM_SHARE_DIR="${PM_SHARE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../share" 2>/dev/null && pwd || echo "$HOME/.local/share/pm")}"

PM_NAME_RE='^[A-Za-z0-9][A-Za-z0-9_-]*$'
PM_RESERVED_NAMES="parent status main sys"

# ---- 出力 ----
pm_die()  { printf 'pm: %s\n' "$*" >&2; exit 1; }
pm_warn() { printf 'pm: %s\n' "$*" >&2; }
pm_info() { printf '%s\n' "$*"; }

# ---- tmux ラッパ ----
t() {
  if [ -n "$PM_TMUX_SOCKET" ]; then
    "$PM_TMUX_BIN" -L "$PM_TMUX_SOCKET" "$@"
  else
    "$PM_TMUX_BIN" "$@"
  fi
}

pm_session_exists() { t has-session -t "=$PM_SESSION" 2>/dev/null; }

# ---- 案件名 ----
pm_validate_name() {
  local name="$1" r
  [[ "$name" =~ $PM_NAME_RE ]] || pm_die "案件名に使えるのは英数字・ハイフン・アンダースコアのみです（先頭は英数字）: '$name'"
  for r in $PM_RESERVED_NAMES; do
    [ "$name" = "$r" ] && pm_die "案件名 '$name' は予約されています"
  done
  return 0
}

# ---- 対応表（TSV: 名前 <TAB> 絶対パス [<TAB> モデル]）----
PM_MODEL_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'

pm_validate_model() {
  local m="$1"
  [[ "$m" =~ $PM_MODEL_RE ]] || pm_die "モデル名に使えるのは英数字とドット、ハイフン、アンダースコアだけです: '$m'"
}

pm_ws_names() {
  [ -f "$PM_WORKSPACES" ] || return 0
  awk -F'\t' 'NF>=2 && $1 !~ /^#/ {print $1}' "$PM_WORKSPACES"
}

pm_ws_path() {
  local name="$1"
  [ -f "$PM_WORKSPACES" ] || return 1
  awk -F'\t' -v n="$name" 'NF>=2 && $1==n {print $2; found=1; exit} END{exit !found}' "$PM_WORKSPACES"
}

# 案件に指定されたモデル。未指定なら空（Claude Code の既定に従う）
pm_ws_model() {
  local name="$1"
  [ -f "$PM_WORKSPACES" ] || return 0
  awk -F'\t' -v n="$name" 'NF>=3 && $1==n {print $3; exit}' "$PM_WORKSPACES"
}

# 対応表の1行を書き換える（モデル列の設定・解除）
pm_ws_set_model() {
  local name="$1" model="$2"
  awk -F'\t' -v OFS='\t' -v n="$name" -v m="$model" '
    $1==n { if (m=="") print $1, $2; else print $1, $2, m; next }
    { print }' "$PM_WORKSPACES" > "$PM_WORKSPACES.tmp"
  mv "$PM_WORKSPACES.tmp" "$PM_WORKSPACES"
  chmod 600 "$PM_WORKSPACES" 2>/dev/null || true
}

pm_ws_exists() { pm_ws_path "$1" >/dev/null 2>&1; }

# 対応表（TSV）と生成する JSON を壊す文字を含むパスを拒否する
pm_validate_path() {
  local p="$1"
  case "$p" in
    *$'\t'*|*$'\n'*) pm_die "タブや改行を含むパスは扱えません" ;;
    *'"'*|*'\\'*)      pm_die "二重引用符やバックスラッシュを含むパスは扱えません" ;;
  esac
  return 0
}

pm_ws_count() { pm_ws_names | wc -l | tr -d ' '; }

# ---- ペイン対応表（TSV: 名前 <TAB> pane_id）----
pm_pane_id() {
  local name="$1"
  [ -f "$PM_PANES" ] || return 1
  awk -F'\t' -v n="$name" '$1==n {print $2; found=1; exit} END{exit !found}' "$PM_PANES"
}

pm_pane_alive() {
  local id="$1"
  pm_session_exists || return 1
  t list-panes -s -t "=$PM_SESSION" -F '#{pane_id}' 2>/dev/null | grep -qx -- "$id"
}

pm_pane_record() {
  local name="$1" id="$2"
  mkdir -p "$PM_STATE_DIR"
  touch "$PM_PANES"
  { awk -F'\t' -v n="$name" '$1!=n' "$PM_PANES"; printf '%s\t%s\n' "$name" "$id"; } > "$PM_PANES.tmp"
  mv "$PM_PANES.tmp" "$PM_PANES"
}

# ---- ファイル生成 ----
pm_now() { date '+%Y-%m-%d %H:%M'; }

# テンプレートの {{KEY}} を置換して出力する。引数は KEY=VALUE の並び。
pm_render() {
  local template="$1"; shift
  local out kv key val
  out="$(cat "$template")"
  for kv in "$@"; do
    key="${kv%%=*}"; val="${kv#*=}"
    out="${out//\{\{$key\}\}/$val}"
  done
  printf '%s\n' "$out"
}

pm_ensure_status_file() {
  local name="$1" f
  f="$PM_STATUS_DIR/$name.md"
  mkdir -p "$PM_STATUS_DIR"
  if [ ! -f "$f" ]; then
    pm_render "$PM_SHARE_DIR/templates/status.md" "NAME=$name" "NOW=$(pm_now)" > "$f"
    chmod 640 "$f" 2>/dev/null || true
  fi
}

pm_ensure_handoff_file() {
  local name="$1" f
  f="$PM_HANDOFF_DIR/$name.md"
  mkdir -p "$PM_HANDOFF_DIR"
  chmod 700 "$PM_HANDOFF_DIR" 2>/dev/null || true
  if [ ! -f "$f" ]; then
    pm_render "$PM_SHARE_DIR/templates/handoff.md" "NAME=$name" "NOW=$(pm_now)" > "$f"
    chmod 600 "$f" 2>/dev/null || true
  fi
}

# 親に渡す案件名の一覧（パスを含まない）
pm_write_workspace_list() {
  local f="$PM_SHARED/workspaces.txt"
  mkdir -p "$PM_SHARED"
  { echo "# 登録済みの案件名（pm add-workspace が更新する。パスは含まない）"; pm_ws_names; } > "$f.tmp"
  mv "$f.tmp" "$f"
  chmod 640 "$f" 2>/dev/null || true
}

# 子セッション用の設定ファイルと追加システムプロンプトを生成する
pm_generate_child_files() {
  local name="$1" gen other
  gen="$PM_GENERATED_DIR/$name"
  mkdir -p "$gen"
  chmod 700 "$PM_GENERATED_DIR" 2>/dev/null || true

  pm_render "$PM_SHARE_DIR/child/rules.md" \
    "NAME=$name" \
    "STATUS_FILE=$PM_STATUS_DIR/$name.md" \
    "HANDOFF_FILE=$PM_HANDOFF_DIR/$name.md" \
    > "$gen/rules.md"

  local deny="" nl=$'\n'
  for other in $(pm_ws_names); do
    [ "$other" = "$name" ] && continue
    deny+="      \"Read(//$PM_STATUS_DIR/$other.md)\",$nl      \"Edit(//$PM_STATUS_DIR/$other.md)\",$nl"
    deny+="      \"Read(//$PM_HANDOFF_DIR/$other.md)\",$nl      \"Edit(//$PM_HANDOFF_DIR/$other.md)\",$nl"
  done

  cat > "$gen/settings.json" <<EOF
{
  "crossSessionInbound": "refuse",
  "permissions": {
    "allow": [
      "Read(//$PM_STATUS_DIR/$name.md)",
      "Edit(//$PM_STATUS_DIR/$name.md)",
      "Read(//$PM_HANDOFF_DIR/$name.md)",
      "Edit(//$PM_HANDOFF_DIR/$name.md)"
    ],
    "deny": [
$(printf '%s' "$deny")      "ListAgents",
      "SendMessage",
      "Read(//$PM_WORKSPACES)",
      "Read(//$PM_CONFIG_DIR/config)",
      "Read(//$PM_GENERATED_DIR/**)",
      "Read(//$PM_STATE_DIR/**)",
      "Edit(//$PM_INBOX_DIR/**)",
      "Edit(//$PM_SHARED/CLAUDE.md)",
      "Edit(//$PM_SHARED/workspaces.txt)",
      "Edit(//$PM_SHARED/.claude/**)",
      "Bash(pm *)",
      "Bash(pm)",
      "Bash(pm-child *)",
      "Bash(pm-dispatch *)",
      "Bash(sudo *)",
      "Bash(su *)",
      "Bash(tmux *)",
      "Bash(tmux)"
    ]
  },
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "pm-hook $name SessionStart" } ] }
    ],
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "pm-hook $name UserPromptSubmit" } ] }
    ],
    "PreCompact": [
      { "hooks": [ { "type": "command", "command": "pm-hook $name PreCompact" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "pm-hook $name Stop" } ] }
    ]
  }
}
EOF
  chmod 600 "$gen/settings.json" "$gen/rules.md" 2>/dev/null || true
}

# 同一ユーザー構成の親用に、案件パスを含む deny 設定を生成する（親からは読めない場所に置く）
pm_generate_parent_single_user_settings() {
  local f="$PM_GENERATED_DIR/parent.settings.json" p path deny="" sandbox="" sep="" nl=$'\n'
  mkdir -p "$PM_GENERATED_DIR"
  chmod 700 "$PM_GENERATED_DIR" 2>/dev/null || true
  for p in $(pm_ws_names); do
    path="$(pm_ws_path "$p")"
    deny+="$sep      \"Read(//$path/**)\",$nl      \"Edit(//$path/**)\",$nl      \"Glob(//$path/**)\",$nl      \"Grep(//$path/**)\""
    sandbox+="$sep      \"$path\""
    sep=",$nl"
  done
  cat > "$f" <<EOF
{
  "permissions": {
    "deny": [
$(printf '%s' "$deny")
    ]
  },
  "sandbox": {
    "filesystem": {
      "denyRead": [
$(printf '%s' "$sandbox")
      ]
    }
  }
}
EOF
  chmod 600 "$f"
}
