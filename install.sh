#!/usr/bin/env bash
# install.sh — pm を導入する（繰り返し実行しても壊れない）
#
# 使い方:
#   ./install.sh [--parent-user NAME] [--shared DIR] [--prefix DIR] [--single-user] [--yes]
#
#   --parent-user NAME  親 claude を動かす Linux ユーザー（既定: pm-parent）
#   --shared DIR        親と子が共有するディレクトリの実体（既定: /srv/pm）
#   --prefix DIR        コマンドの置き場所（既定: ~/.local）
#   --single-user       別ユーザーを作らず、同一ユーザーで親を動かす（パスの隠蔽は誤操作防止の水準）
#   --yes               確認を省略する
#
# 既存ファイルを置き換える前に <ファイル>.bak.<日時> として退避する。

set -euo pipefail

SRC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PARENT_USER="pm-parent"
SHARED="/srv/pm"
PREFIX="$HOME/.local"
SINGLE_USER=""
YES=""
GROUP="pm"
OWNER="$(id -un)"

while [ $# -gt 0 ]; do
  case "$1" in
    --parent-user) PARENT_USER="$2"; shift 2 ;;
    --shared) SHARED="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --single-user) SINGLE_USER=1; shift ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "不明な引数: $1" >&2; exit 1 ;;
  esac
done

if [ -n "$SINGLE_USER" ]; then
  PARENT_USER=""
  SHARED="$HOME/pm"
fi
SHARED="$(readlink -m "$SHARED")"
MARKER=".pm-managed"   # pm が管理するディレクトリに置く目印。uninstall はこれがある所しか消さない
case "$SHARED" in
  "/"|"$HOME"|"$HOME/"|/home|/root|/etc|/usr|/var|/srv|/tmp) echo "install: --shared に $SHARED は指定できません" >&2; exit 1 ;;
esac
if [ -d "$SHARED" ] && [ ! -e "$SHARED/$MARKER" ] && [ -n "$(ls -A "$SHARED" 2>/dev/null)" ]; then
  echo "install: $SHARED は既にあり、中身が入っていて pm の管理下ではありません。別の場所を指定するか、退避してください" >&2
  exit 1
fi

CONFIG_DIR="${PM_CONFIG_DIR:-$HOME/.config/pm}"
BIN_DIR="$PREFIX/bin"
SHARE_DIR="$PREFIX/share/pm"
STAMP="$(date +%Y%m%d-%H%M%S)"

say()  { printf '%s\n' "$*"; }
warn() { printf 'install: %s\n' "$*" >&2; }
die()  { warn "$*"; exit 1; }
confirm() {
  [ -n "$YES" ] && return 0
  confirm_always "$1"
}
# --yes でも省略しない確認（利用者のホームの権限変更、ネットワークからのインストール）
confirm_always() {
  [ -t 0 ] || return 1
  printf '%s [y/N] ' "$1"
  read -r a
  [ "$a" = y ] || [ "$a" = Y ]
}

# 既存ファイルと内容が違うときだけ退避してからコピーする
install_file() {  # install_file <src> <dst> <mode>
  local src="$1" dst="$2" mode="$3"
  if [ -e "$dst" ] && ! cmp -s "$src" "$dst"; then
    cp -p "$dst" "$dst.bak.$STAMP"
    say "  退避: $dst -> $dst.bak.$STAMP"
  fi
  if [ ! -e "$dst" ] || ! cmp -s "$src" "$dst"; then
    install -m "$mode" "$src" "$dst"
    say "  配置: $dst"
  fi
}

# ---------------------------------------------------------------- 1. 前提
say "== 前提確認"
for c in tmux claude; do
  command -v "$c" >/dev/null || die "$c が見つかりません"
done
if [ -z "$SINGLE_USER" ]; then
  [ -x /usr/bin/bwrap ] || [ -x /usr/local/bin/bwrap ] || warn "bubblewrap が /usr/bin にありません。親ユーザーからも使える場所に要ります: sudo apt-get install bubblewrap"
else
  command -v bwrap >/dev/null || warn "bubblewrap がありません（親のサンドボックスに必要: sudo apt-get install bubblewrap）"
fi
command -v socat  >/dev/null || warn "socat がありません（親のサンドボックスに必要: sudo apt-get install socat）"
tmux_ver="$(tmux -V | sed 's/^tmux //; s/[a-z]$//')"
say "  tmux $tmux_ver, $(claude --version 2>/dev/null | head -1)"

# ---------------------------------------------------------------- 2. コマンド
say "== コマンドを $BIN_DIR に配置"
mkdir -p "$BIN_DIR" "$SHARE_DIR"
for f in pm pm-lib.sh pm-child pm-hook; do
  install_file "$SRC/bin/$f" "$BIN_DIR/$f" 755
done
# share（テンプレート、子ルール、親設定の原本）
( cd "$SRC/share" && find . -type f ) | while read -r rel; do
  mkdir -p "$SHARE_DIR/$(dirname "$rel")"
  install_file "$SRC/share/$rel" "$SHARE_DIR/$rel" 644
done
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR が PATH にありません。シェルの設定に追加してください" ;;
esac

# ---------------------------------------------------------------- 3. 設定ディレクトリ
say "== 設定ディレクトリ $CONFIG_DIR"
mkdir -p "$CONFIG_DIR/handoff" "$CONFIG_DIR/state" "$CONFIG_DIR/generated"
chmod 700 "$CONFIG_DIR" "$CONFIG_DIR/handoff" "$CONFIG_DIR/generated" "$CONFIG_DIR/state"
[ -f "$CONFIG_DIR/workspaces" ] || { : > "$CONFIG_DIR/workspaces"; }
chmod 600 "$CONFIG_DIR/workspaces"

tmp_cfg="$(mktemp)"
cat > "$tmp_cfg" <<EOF
# pm の設定（install.sh が生成。手で編集してもよい）
PM_SHARED="$SHARED"
PM_PARENT_USER="$PARENT_USER"
PM_SHARE_DIR="$SHARE_DIR"
EOF
install_file "$tmp_cfg" "$CONFIG_DIR/config" 600
rm -f "$tmp_cfg"

# ---------------------------------------------------------------- 4. 別ユーザー構成
# 各手順は「必要なときだけ sudo を使う」。2 回目以降の実行で変更が無ければ sudo は呼ばれない。
if [ -n "$PARENT_USER" ]; then
  say "== 別ユーザー構成（親: $PARENT_USER, 共有: $SHARED）"
  SUDO_ANNOUNCED=""
  need_sudo() {  # 初めて sudo が必要になったときに一度だけ説明して確認する
    [ -n "$SUDO_ANNOUNCED" ] && return 0
    SUDO_ANNOUNCED=1
    say "  次の操作に sudo を使います（必要なものだけ）:"
    say "   - グループ $GROUP の作成、ユーザー $PARENT_USER の作成とグループ追加"
    say "   - $SHARED の作成と権限設定"
    say "   - /usr/local/bin/pm-parent-run（root 所有の起動ラッパ）の配置"
    say "   - /etc/sudoers.d/pm に「$OWNER が $PARENT_USER として pm-parent-run だけを実行できる」規則の配置"
    say "   - 親ユーザーのホームに ~/pm の symlink を作成"
    confirm "続けますか？" || die "中断しました"
  }
  in_group() { id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -qx "$2"; }
  dir_is() {  # dir_is <path> <owner:group> <mode>
    [ -d "$1" ] && [ "$(stat -c '%U:%G %a' "$1")" = "$2 $3" ]
  }

  getent group "$GROUP" >/dev/null || { need_sudo; sudo groupadd "$GROUP"; }
  if ! id "$PARENT_USER" >/dev/null 2>&1; then
    need_sudo; sudo useradd -m -s /bin/bash -G "$GROUP" "$PARENT_USER"
  elif ! in_group "$PARENT_USER" "$GROUP"; then
    need_sudo; sudo usermod -aG "$GROUP" "$PARENT_USER"
  fi
  in_group "$OWNER" "$GROUP" || { need_sudo; sudo usermod -aG "$GROUP" "$OWNER"; }

  for d in "$SHARED" "$SHARED/status" "$SHARED/.claude"; do
    dir_is "$d" "$OWNER:$GROUP" 2750 || { need_sudo; sudo mkdir -p "$d"; sudo chown "$OWNER:$GROUP" "$d"; sudo chmod 2750 "$d"; }
  done
  # inbox は親が書き、利用者側の監視処理が読む。監視処理はグループ追加前に起動したシェルから動くことが
  # あるので、グループに頼らず読めるよう o+rx にする（中身は親が書いた依頼文のみ）
  dir_is "$SHARED/inbox" "$PARENT_USER:$GROUP" 2775 || { need_sudo; sudo mkdir -p "$SHARED/inbox"; sudo chown "$PARENT_USER:$GROUP" "$SHARED/inbox"; sudo chmod 2775 "$SHARED/inbox"; }

  # 起動ラッパ（root 所有・書き込み不可）。sudoers はこのファイルの実行だけを許可する
  if ! cmp -s "$SRC/share/pm-parent-run" /usr/local/bin/pm-parent-run 2>/dev/null; then
    need_sudo
    sudo install -m 755 -o root -g root "$SRC/share/pm-parent-run" /usr/local/bin/pm-parent-run
    say "  配置: /usr/local/bin/pm-parent-run"
  fi

  # sudoers。root しか読めないので、書いた内容の控えを設定ディレクトリに置いて比較する
  sudoers_tmp="$(mktemp)"
  printf '%s ALL=(%s) NOPASSWD: /usr/local/bin/pm-parent-run "", /usr/local/bin/pm-parent-run --resume, /usr/local/bin/pm-parent-run --check\n' "$OWNER" "$PARENT_USER" > "$sudoers_tmp"
  if [ ! -e /etc/sudoers.d/pm ] || ! cmp -s "$sudoers_tmp" "$CONFIG_DIR/sudoers.installed" 2>/dev/null; then
    need_sudo
    sudo visudo -cf "$sudoers_tmp" >/dev/null
    sudo install -m 440 -o root -g root "$sudoers_tmp" /etc/sudoers.d/pm
    install -m 600 "$sudoers_tmp" "$CONFIG_DIR/sudoers.installed"
    say "  配置: /etc/sudoers.d/pm"
  fi
  rm -f "$sudoers_tmp"

  # 親ユーザーのホームに ~/pm -> 共有ディレクトリ（ラッパの --check が通れば済んでいる）
  if ! sudo -n -H -u "$PARENT_USER" /usr/local/bin/pm-parent-run --check >/dev/null 2>&1; then
    need_sudo
    sudo -u "$PARENT_USER" -H env PM_LINK_TARGET="$SHARED" bash -c '[ -L ~/pm ] || ln -s "$PM_LINK_TARGET" ~/pm'
  fi

  # 利用者のホームを他ユーザーから読めなくする
  home_mode="$(stat -c %a "$HOME")"
  if [ "$((8#$home_mode & 8#007))" -ne 0 ]; then
    say "  $HOME の権限が $home_mode で、$PARENT_USER から案件が読めます。"
    if confirm_always "  chmod 750 $HOME を実行しますか？"; then
      chmod 750 "$HOME"
    else
      warn "案件ディレクトリが親から読める状態のままです（pm check で再確認できます）"
    fi
  fi

  # 親ユーザー用の claude（利用者のホームにある claude は読めないので別に入れる）
  if ! sudo -n -H -u "$PARENT_USER" /usr/local/bin/pm-parent-run --check 2>&1 | grep -q .; then
    : # --check が何も出さなければ claude も ~/pm も揃っている
  elif sudo -n -H -u "$PARENT_USER" /usr/local/bin/pm-parent-run --check 2>&1 | grep -q 'claude が'; then
    say "  $PARENT_USER に claude が入っていません。公式インストーラ（https://claude.ai/install.sh）を $PARENT_USER として実行できます。"
    if confirm_always "  実行しますか？（ネットワークを使います）"; then
      sudo -H -u "$PARENT_USER" bash -lc 'curl -fsSL https://claude.ai/install.sh | bash'
    else
      warn "後で手動で入れてください: sudo -H -u $PARENT_USER bash -lc 'curl -fsSL https://claude.ai/install.sh | bash'"
    fi
  fi
else
  say "== 同一ユーザー構成（共有: $SHARED）"
  if [ -e "$SHARED" ] && [ ! -d "$SHARED" ]; then die "$SHARED がディレクトリではありません"; fi
  mkdir -p "$SHARED/status" "$SHARED/inbox" "$SHARED/.claude"
fi

# ---------------------------------------------------------------- 5. ~/pm と親のファイル
say "== 親の起動場所 $SHARED"
if [ "$SHARED" != "$HOME/pm" ]; then
  if [ -e "$HOME/pm" ] && [ ! -L "$HOME/pm" ]; then
    die "$HOME/pm が既にあり、symlink ではありません。退避してから再実行してください"
  fi
  [ -L "$HOME/pm" ] || ln -s "$SHARED" "$HOME/pm"
fi

render_parent() {  # render_parent <src> <dst> <mode>
  local tmp content; tmp="$(mktemp)"
  content="$(cat "$1")"
  printf '%s\n' "${content//\{\{SHARED\}\}/$SHARED}" > "$tmp"
  install_file "$tmp" "$2" "$3"
  rm -f "$tmp"
}
render_parent "$SRC/share/parent/CLAUDE.md" "$SHARED/CLAUDE.md" 640
render_parent "$SRC/share/parent/.claude/settings.json" "$SHARED/.claude/settings.json" 640
for s in add-task show-task; do
  mkdir -p "$SHARED/.claude/skills/$s"
  render_parent "$SRC/share/parent/.claude/skills/$s/SKILL.md" "$SHARED/.claude/skills/$s/SKILL.md" 640
done
if [ -n "$PARENT_USER" ]; then
  chgrp -R "$GROUP" "$SHARED/.claude" "$SHARED/CLAUDE.md" 2>/dev/null || sudo chgrp -R "$GROUP" "$SHARED/.claude" "$SHARED/CLAUDE.md"
  chmod 2750 "$SHARED/.claude/skills" "$SHARED/.claude/skills"/* 2>/dev/null || sudo chmod 2750 "$SHARED/.claude/skills" "$SHARED/.claude/skills"/*
fi
PM_CONFIG_DIR="$CONFIG_DIR" "$BIN_DIR/pm" list >/dev/null 2>&1 || true
{ echo "# 登録済みの案件名（pm add-workspace が更新する。パスは含まない）"; awk -F'\t' 'NF>=2 && $1 !~ /^#/ {print $1}' "$CONFIG_DIR/workspaces"; } > "$SHARED/workspaces.txt"
chmod 640 "$SHARED/workspaces.txt"
[ -n "$PARENT_USER" ] && { chgrp "$GROUP" "$SHARED/workspaces.txt" 2>/dev/null || sudo chgrp "$GROUP" "$SHARED/workspaces.txt"; }
touch "$SHARED/$MARKER" "$CONFIG_DIR/$MARKER"

# ---------------------------------------------------------------- 6. 仕上げ
say "== 完了"
say "次の手順:"
if [ -n "$PARENT_USER" ]; then
  say "  1. グループ追加を反映するため、一度ログアウトして入り直す（または newgrp $GROUP）"
  say "  2. 親ユーザーで一度ログインする: sudo -H -u $PARENT_USER bash -lc 'cd ~/pm && claude'（root 権限の sudo。パスワードを聞かれます）"
  say "     （ブラウザで承認し、初期設定が終わったら /exit）"
  say "  3. 案件を登録する: pm add-workspace <名前> <パス>"
  say "  4. pm check で前提を点検し、pm init で起動する"
else
  say "  1. 案件を登録する: pm add-workspace <名前> <パス>"
  say "  2. pm check で前提を点検し、pm init で起動する"
fi
