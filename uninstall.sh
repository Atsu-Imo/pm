#!/usr/bin/env bash
# uninstall.sh — pm を取り除く
#
# 使い方: ./uninstall.sh [--prefix DIR] [--purge] [--yes]
#   --purge  設定（~/.config/pm: 対応表・引き継ぎメモ）、共有ディレクトリ、親ユーザーも消す
#   --yes    確認を省略する
#
# 既定では、コマンド本体と sudoers の規則だけを消し、課題ファイルと引き継ぎメモは残す。

set -euo pipefail

PREFIX="$HOME/.local"
PURGE=""
YES=""
CONFIG_DIR="${PM_CONFIG_DIR:-$HOME/.config/pm}"

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --purge) PURGE=1; shift ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "不明な引数: $1" >&2; exit 1 ;;
  esac
done

say() { printf '%s\n' "$*"; }
confirm() { [ -n "$YES" ] && return 0; printf '%s [y/N] ' "$1"; read -r a; [ "$a" = y ] || [ "$a" = Y ]; }

PM_SHARED=""; PM_PARENT_USER=""
# shellcheck disable=SC1091
[ -f "$CONFIG_DIR/config" ] && . "$CONFIG_DIR/config"

if command -v tmux >/dev/null && tmux has-session -t "=pm" 2>/dev/null; then
  say "tmux セッション pm が起動中です。先に終了してください: tmux kill-session -t pm"
  exit 1
fi

say "== コマンドを削除"
for f in pm pm-lib.sh pm-child pm-hook; do
  [ -e "$PREFIX/bin/$f" ] && rm -f "$PREFIX/bin/$f" && say "  削除: $PREFIX/bin/$f"
done
[ -d "$PREFIX/share/pm" ] && rm -rf "$PREFIX/share/pm" && say "  削除: $PREFIX/share/pm"

if [ -e /etc/sudoers.d/pm ] || [ -e /usr/local/bin/pm-parent-run ]; then
  say "== /etc/sudoers.d/pm と /usr/local/bin/pm-parent-run を削除（sudo）"
  sudo rm -f /etc/sudoers.d/pm /usr/local/bin/pm-parent-run
fi

if [ -L "$HOME/pm" ]; then
  rm -f "$HOME/pm" && say "  削除: $HOME/pm (symlink)"
fi

if [ -z "$PURGE" ]; then
  say "== 残したもの"
  say "  $CONFIG_DIR （対応表、引き継ぎメモ）"
  [ -n "$PM_SHARED" ] && say "  $PM_SHARED （課題ファイル、親の設定）"
  [ -n "$PM_PARENT_USER" ] && say "  ユーザー $PM_PARENT_USER"
  say "  すべて消すには --purge を付けて再実行してください"
  exit 0
fi

say "== --purge: 設定と共有ディレクトリを削除"
confirm "本当に消しますか？（引き継ぎメモと課題ファイルも消えます）" || exit 1
# pm が置いた目印 .pm-managed があるディレクトリしか消さない
if [ -e "$CONFIG_DIR/.pm-managed" ]; then
  rm -rf "$CONFIG_DIR" && say "  削除: $CONFIG_DIR"
else
  say "  $CONFIG_DIR に目印 .pm-managed が無いので消しません"
fi
if [ -n "$PM_SHARED" ] && [ -d "$PM_SHARED" ]; then
  if [ -e "$PM_SHARED/.pm-managed" ]; then
    if [ -w "$(dirname "$PM_SHARED")" ] && [ -O "$PM_SHARED" ]; then rm -rf "$PM_SHARED"; else sudo rm -rf "$PM_SHARED"; fi
    say "  削除: $PM_SHARED"
  else
    say "  $PM_SHARED に目印 .pm-managed が無いので消しません"
  fi
fi
if [ -n "$PM_PARENT_USER" ] && id "$PM_PARENT_USER" >/dev/null 2>&1; then
  if confirm "ユーザー $PM_PARENT_USER とそのホームを削除しますか？"; then
    sudo userdel -r "$PM_PARENT_USER" && say "  削除: ユーザー $PM_PARENT_USER"
  fi
fi
if getent group pm >/dev/null && confirm "グループ pm を削除しますか？"; then
  sudo groupdel pm && say "  削除: グループ pm"
fi
say "完了。$HOME の権限（chmod 750）は戻していません。必要なら手で戻してください"
