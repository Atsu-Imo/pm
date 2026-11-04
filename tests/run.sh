#!/usr/bin/env bash
# tests/run.sh — pm の自動テスト
#
# tmux と claude は tests/stubs の代役に差し替える。実際のプロセスは起動しない。
# 使い方: bash tests/run.sh

set -u
SRC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export PM_CONFIG_DIR="$TMP/config"
export PM_SHARED="$TMP/home/pm"
export PM_SHARE_DIR="$SRC/share"
export PM_TMUX_BIN="$SRC/tests/stubs/tmux"
export PM_CLAUDE_BIN="$SRC/tests/stubs/claude"
export PM_PARENT_USER=""
export STUB_STATE="$TMP/stub"
export PATH="$SRC/bin:$SRC/tests/stubs:$PATH"
unset TMUX
mkdir -p "$HOME" "$PM_SHARED" "$STUB_STATE"
chmod +x "$SRC/bin"/* "$SRC/tests/stubs"/*

pass=0; fail=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
ng()   { fail=$((fail + 1)); printf 'NG   %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else ng "$1" "$2"; fi; }
reset_stub() { rm -rf "$STUB_STATE"; mkdir -p "$STUB_STATE"; }

wsA="$TMP/work/案件 A with space"; wsB="$TMP/work/b-repo"; wsC="$TMP/work/c_repo"
mkdir -p "$wsA" "$wsB" "$wsC"

# ---- 案件名の検証
check "英数字・ハイフン・アンダースコア以外は拒否" '! pm add-workspace "bad name" "$wsA"'
check "ドットを含む名前は拒否"                     '! pm add-workspace "a.b" "$wsA"'
check "先頭ハイフンは拒否"                         '! pm add-workspace -x "$wsA"'
check "予約名 parent は拒否"                       '! pm add-workspace parent "$wsA"'
check "存在しないパスは拒否"                       '! pm add-workspace a "$TMP/nope"'
mkdir -p "$TMP/work/has\"quote" "$TMP/work/has	tab" "$TMP/work/100%done"
check "二重引用符を含むパスは拒否"                 '! pm add-workspace q "$TMP/work/has\"quote"'
check "タブを含むパスは拒否"                       '! pm add-workspace q "$TMP/work/has	tab"'

# ---- 登録
check "空白を含むパスを登録できる" 'pm add-workspace a "$wsA"'
check "対応表に絶対パスが入る"     'grep -qF "$(printf "a\t%s" "$wsA")" "$PM_CONFIG_DIR/workspaces"'
check "対応表の権限は 600"         '[ "$(stat -c %a "$PM_CONFIG_DIR/workspaces")" = 600 ]'
check "課題ファイルが作られる"     'grep -q "^# a$" "$PM_SHARED/status/a.md" && grep -q "^状態：入力待ち" "$PM_SHARED/status/a.md"'
check "引き継ぎメモが作られる"     '[ -f "$PM_CONFIG_DIR/handoff/a.md" ] && [ "$(stat -c %a "$PM_CONFIG_DIR/handoff/a.md")" = 600 ]'
check "同じ登録を繰り返しても重複しない" 'pm add-workspace a "$wsA" && [ "$(grep -c "^a	" "$PM_CONFIG_DIR/workspaces")" = 1 ]'
check "同名で別パスは拒否"         '! pm add-workspace a "$wsB"'
echo "- [ ] 手で書いた既存タスク" >> "$PM_SHARED/status/a.md"
check "既存の課題ファイルは上書きしない" 'pm add-workspace a "$wsA" && grep -q "手で書いた既存タスク" "$PM_SHARED/status/a.md"'
pm add-workspace b "$wsB" >/dev/null
pm add-workspace c "$wsC" >/dev/null
check "list は名前だけを返す"      '[ "$(pm list | tr "\n" " ")" = "a b c " ]'
check "--model 付きで登録できる"    'mkdir -p "$TMP/work/m" && pm add-workspace m "$TMP/work/m" --model opus | grep -q "モデル: opus" && grep -q "^m	$TMP/work/m	opus$" "$PM_CONFIG_DIR/workspaces"'
check "モデル列があってもパスは正しく読める" 'pm-child m >/dev/null 2>&1; [ "$(grep "^cwd=" "$STUB_STATE/claude.log" | tail -1)" = "cwd=$TMP/work/m" ]'
check "pm-child は --model を渡す"   'tail -1 "$STUB_STATE/claude.log" | grep -q -- "--model opus"'
check "set-model で変更できる"       'pm set-model m sonnet >/dev/null && grep -q "^m	$TMP/work/m	sonnet$" "$PM_CONFIG_DIR/workspaces" && pm-child m >/dev/null 2>&1; tail -1 "$STUB_STATE/claude.log" | grep -q -- "--model sonnet"'
check "set-model default で指定を外す" 'pm set-model m default >/dev/null && grep -q "^m	$TMP/work/m$" "$PM_CONFIG_DIR/workspaces" && pm-child m >/dev/null 2>&1; ! tail -1 "$STUB_STATE/claude.log" | grep -q -- "--model"'
check "set-model は不正なモデル名を拒否" '! pm set-model m "op us" 2>/dev/null && ! pm set-model zzz opus 2>/dev/null'
check "status にモデル列が出る"      'pm set-model m haiku >/dev/null && pm status --brief | grep -E "^m .*haiku$" && pm status --brief | grep -E "^a .*既定$"'
check "モデル指定のない案件は --model なし" 'pm-child a >/dev/null 2>&1; ! tail -1 "$STUB_STATE/claude.log" | grep -q -- "--model"'
sed -i '/^m	/d' "$PM_CONFIG_DIR/workspaces"; rm -rf "$PM_CONFIG_DIR/generated/m"; pm add-workspace c "$wsC" >/dev/null
check "親設定のモデルは opus"        'grep -q "\"model\": \"opus\"" "$SRC/share/parent/.claude/settings.json"'
check "workspaces.txt にパスが無い" '! grep -q "$TMP" "$PM_SHARED/workspaces.txt" && grep -qx a "$PM_SHARED/workspaces.txt"'

# ---- 生成物
gen="$PM_CONFIG_DIR/generated"
check "子の settings.json が JSON として妥当"    'python3 -m json.tool "$gen/a/settings.json"'
check "子 a は b の課題ファイルを編集できない"     'grep -q "Edit(//$PM_SHARED/status/b.md)" "$gen/a/settings.json"'
check "子 a は b の引き継ぎメモを読めない"         'grep -q "Read(//$PM_CONFIG_DIR/handoff/b.md)" "$gen/a/settings.json"'
check "子 a は自分の課題ファイルを編集できる"     'grep -q "\"Edit(//$PM_SHARED/status/a.md)\"" "$gen/a/settings.json" && ! grep -q "deny.*status/a.md" "$gen/a/settings.json"'
check "子は対応表を読めない"                       'grep -q "Read(//$PM_CONFIG_DIR/workspaces)" "$gen/a/settings.json"'
check "子は sudo と tmux を使えない"               'grep -q "\"Bash(sudo \*)\"" "$gen/a/settings.json" && grep -q "\"Bash(tmux \*)\"" "$gen/a/settings.json"'
check "% を含むパスでも生成 JSON が壊れない"       'pm add-workspace pct "$TMP/work/100%done" >/dev/null && python3 -m json.tool "$gen/parent.settings.json" >/dev/null && grep -qF "Read(//$TMP/work/100%done/**)" "$gen/parent.settings.json" && python3 -m json.tool "$gen/a/settings.json" >/dev/null'
sed -i '/^pct	/d' "$PM_CONFIG_DIR/workspaces"; rm -rf "$gen/pct"; pm add-workspace c "$wsC" >/dev/null
check "子の設定に受信拒否とフックがある"           'grep -q "\"crossSessionInbound\": \"refuse\"" "$gen/a/settings.json" && grep -q "pm-hook a SessionStart" "$gen/a/settings.json" && grep -q PreCompact "$gen/a/settings.json"'
check "子のルールに案件名とファイル名が入る"       'grep -q "案件: a" "$gen/a/rules.md" && grep -qF "$PM_SHARED/status/a.md" "$gen/a/rules.md"'
check "同一ユーザー用の親設定に案件パスの deny がある" 'python3 -m json.tool "$gen/parent.settings.json" && grep -qF "Read(//$wsA/**)" "$gen/parent.settings.json" && grep -qF "\"$wsB\"" "$gen/parent.settings.json"'
check "親設定の原本が JSON として妥当"            'sed "s#{{SHARED}}#/srv/pm#g" "$SRC/share/parent/.claude/settings.json" | python3 -m json.tool'
check "親設定が ListAgents と SendMessage を拒否" 'grep -q "\"ListAgents\"" "$SRC/share/parent/.claude/settings.json" && grep -q "\"SendMessage\"" "$SRC/share/parent/.claude/settings.json"'
check "親設定で bypassPermissions を使っていない"  '! grep -q -i "bypass\|dangerously" "$SRC/share/parent/.claude/settings.json"'
check "Write() 規則を使っていない（Edit が全編集を覆う）" '! grep -q "Write(" "$SRC/share/parent/.claude/settings.json" && ! grep -q "Write(" "$gen/a/settings.json"'
check "スキルは disable-model-invocation" 'grep -q "disable-model-invocation: true" "$SRC/share/parent/.claude/skills/add-task/SKILL.md" && grep -q "disable-model-invocation: true" "$SRC/share/parent/.claude/skills/show-task/SKILL.md"'

# ---- status
cat > "$PM_SHARED/status/b.md" <<'EOF'
# b
更新：2026-11-04 10:00
状態：作業中

- [ ] #1 一つ目
  期限：2000-01-01
  直近：11-04 09:50 受領
- [ ] #2 二つ目
  期限：なし
  直近：11-04 09:55 調査中
- [x] #3 済み
  期限：2099-12-31
  直近：11-04 10:00 完了
- [ ] 旧形式の行
EOF
check "status が未完了数を数える"        'pm status --brief | grep -E "^b +作業中 +3/1 +2026-11-04 10:00"'
check "status は既定で未完了タスクを展開" 'pm status | grep -q "一つ目" && pm status | grep -q "直近 11-04 09:55 調査中" && ! pm status | grep -q "済み"'
check "status は期限超過に ! を付ける"    'pm status | grep -q "\[ \] !01/01  #1 一つ目" && pm status | grep -q "\[ \]     --  #2 二つ目"'
check "status --all は完了も出す"         'pm status --all | grep -q "\[x\]  12/31  #3 済み"'
check "status --brief は展開しない"       '! pm status --brief | grep -q "一つ目"'
check "status は期限・直近の無い行も出す" 'pm status | grep -q "旧形式の行"'
check "status にパスが出ない"            '! pm status | grep -qF "$TMP"'
check "status は課題ファイルが無くても落ちない" 'rm -f "$PM_SHARED/status/c.md"; pm status | grep -q "c.*課題ファイルなし"; pm add-workspace c "$wsC"'

# ---- init
reset_stub
check "init でセッションを作る"            'pm init && grep -q "^new-session" "$STUB_STATE/tmux.log"'
log="$STUB_STATE/tmux.log"
check "親ペインの起動コマンドに案件パスが無い" '! grep "^respawn-pane" "$log" | grep -qF "$TMP/work"'
check "親は --settings で生成設定を受け取る" 'grep "^respawn-pane" "$log" | grep -q "parent.settings.json" && grep "^respawn-pane" "$log" | grep -q -- "--name.\{1,2\}parent"'
check "課題一覧ペインは watch pm status"    'grep -q "watch -t -n 5 pm status" "$log"'
check "子3つが pm-child で起動される"       '[ "$(grep -c "pm-child [abc]" "$log")" = 3 ]'
check "子の起動コマンドにパスが無い"         '! grep "pm-child" "$log" | grep -qF "$TMP/work"'
check "inbox 監視ウィンドウがある"           'grep -q "pm dispatch" "$log"'
check "マウスはセッション限定で有効"         'grep -q "^set-option -t pm: mouse on" "$log"'
check "ペインにタイトルを付ける"             'grep -q -- "@pm_title 親AI" "$log" && grep -q -- "@pm_title 子：a" "$log"'
check "ペイン対応表が記録される"             'grep -q "^a	%" "$PM_CONFIG_DIR/state/panes.tsv" && grep -q "^parent	%" "$PM_CONFIG_DIR/state/panes.tsv"'
check "最後に接続する"                       'tail -1 "$log" | grep -q "^attach-session"'

n_before="$(wc -l < "$log")"
check "init 再実行では作り直さない"          'pm init && [ "$(grep -c "^new-session" "$log")" = 1 ] && [ "$(grep -c "pm-child" "$log")" = 3 ]'
check "init 再実行でも接続する"              'tail -1 "$log" | grep -q "^attach-session"'
check "init --resume は起動中なら無視して接続" 'pm init --resume 2>&1 | grep -q "無視" '

check "親ペインが無い壊れたセッションには接続せず止まる" 'cp "$PM_CONFIG_DIR/state/panes.tsv" "$TMP/panes.bak" && : > "$PM_CONFIG_DIR/state/panes.tsv" && out="$(pm init 2>&1)"; rc=$?; cp "$TMP/panes.bak" "$PM_CONFIG_DIR/state/panes.tsv"; [ $rc -ne 0 ] && grep -q "kill-session" <<<"$out"'

# ---- 起動中に add-workspace
mkdir -p "$TMP/work/d"
check "起動中の add-workspace はペインを追加" 'pm add-workspace d "$TMP/work/d" | grep -q "ペインを追加" && grep -q "pm-child d" "$log"'
check "5件目はウィンドウ ws-2 に入る"         'mkdir -p "$TMP/work/e" && pm add-workspace e "$TMP/work/e" >/dev/null && grep -q "^new-window.*-n ws-2" "$log" && grep -q "^respawn-pane.*pm-child e" "$log"'
check "既存の子の deny が新しい案件分も含む"   'grep -q "status/e.md" "$gen/a/settings.json"'

# ---- restart
touch -d '10 minutes ago' "$PM_CONFIG_DIR/handoff/a.md"
( sleep 1; touch "$PM_CONFIG_DIR/handoff/a.md" ) &
check "restart は更新依頼を送ってから respawn"  'PM_RESTART_WAIT=10 pm restart a && grep -q "send-keys.*pm restart" "$log" && grep "^respawn-pane" "$log" | grep -q "pm-child a"'
wait
check "restart は他のペインに触らない"          '[ "$(grep -c "^respawn-pane.*pm-child a" "$log")" = 2 ] && [ "$(grep -c "^kill" "$log")" = 0 ]'
check "restart 対象の pane_id は変わらない"     'grep -q "^a	%2$" "$PM_CONFIG_DIR/state/panes.tsv"'
check "未登録案件の restart は拒否"             '! pm restart zzz'
printf 'Do you want to proceed?\n❯ 1. Yes\n' > "$STUB_STATE/screen"
n_sk="$(grep -c "^send-keys" "$log")"
check "選択待ちの子には restart しない"          '! PM_RESTART_WAIT=4 pm restart a 2>/dev/null && [ "$(grep -c "^send-keys" "$log")" = "$n_sk" ] && [ "$(grep -c "^respawn-pane.*pm-child a" "$log")" = 2 ]'
rm -f "$STUB_STATE/screen"

# ---- ペイン対応表を失ったとき
reset_stub; pm init >/dev/null; rm -f "$PM_CONFIG_DIR/state/panes.tsv"
printf '%%0\t%s\n%%2\tpm-child a\n%%3\tpm-child b\n' "$(PM_RESUME= bash -c '. "$SRC/bin/pm-lib.sh"; printf "bash -lc %q" "cd $(printf %q "$PM_SHARED") && exec $(printf %q "$PM_CLAUDE_BIN") --name parent --settings $(printf %q "$PM_CONFIG_DIR/generated/parent.settings.json")"')" > "$STUB_STATE/pane_cmds"
check "対応表が無くても起動中の子を二重に作らない" 'pm init >/dev/null && [ "$(grep -c "pm-child a" "$STUB_STATE/tmux.log")" = 1 ] && grep -q "^a	%2$" "$PM_CONFIG_DIR/state/panes.tsv"'
rm -f "$STUB_STATE/pane_cmds"

# ---- --resume
reset_stub; rm -f "$PM_CONFIG_DIR/state/panes.tsv"
check "init --resume で親子とも --resume 付き" 'pm init --resume && grep "^respawn-pane" "$STUB_STATE/tmux.log" | grep -q -- "--resume.\{1,2\}parent" && grep -q "pm-child a --resume" "$STUB_STATE/tmux.log"'

# ---- pm-child
reset_stub
check "pm-child は案件ディレクトリで claude を起動" 'pm-child a >/dev/null && grep -qF "cwd=$wsA" "$STUB_STATE/claude.log"'
check "pm-child の引数にルールと設定と add-dir"   'grep "^args=" "$STUB_STATE/claude.log" | grep -q -- "--name a --append-system-prompt-file $gen/a/rules.md --settings $gen/a/settings.json --add-dir $PM_SHARED/status --add-dir $PM_CONFIG_DIR/handoff"'
check "pm-child --resume"                         'pm-child a --resume >/dev/null && tail -1 "$STUB_STATE/claude.log" | grep -q -- "--resume a"'
check "pm-child は未登録名を拒否"                 '! pm-child zzz'

# ---- pm-hook
check "SessionStart が課題と引き継ぎを出す"  'echo "{}" | pm-hook b SessionStart | grep -q "一つ目" && echo "{}" | pm-hook b SessionStart | grep -q "作業を始めないでください"'
check "Stop: メモが新しければ何も出さない"    'touch "$PM_CONFIG_DIR/handoff/b.md" && [ -z "$(echo "{\"stop_hook_active\": false}" | pm-hook b Stop)" ]'
check "Stop: メモが古ければ更新を促す"        'touch -d "2 hours ago" "$PM_CONFIG_DIR/handoff/b.md" && echo "{\"stop_hook_active\": false}" | pm-hook b Stop | python3 -c "import json,sys; d=json.load(sys.stdin); assert \"更新\" in d[\"hookSpecificOutput\"][\"additionalContext\"]"'
check "Stop: 連続時は止めない"                '[ -z "$(echo "{\"stop_hook_active\": true}" | pm-hook b Stop)" ]'
check "PreCompact manual: 古ければ一度だけ exit 2" 'rm -f "$PM_CONFIG_DIR/state/b.compact-pending"; ! echo "{\"trigger\": \"manual\"}" | pm-hook b PreCompact 2>/dev/null; echo "{\"trigger\": \"manual\"}" | pm-hook b PreCompact'
check "PreCompact auto: 止めない"            'rm -f "$PM_CONFIG_DIR/state/b.compact-pending"; echo "{\"trigger\": \"auto\"}" | pm-hook b PreCompact && [ -f "$PM_CONFIG_DIR/state/b.compact-pending" ]'
check "UserPromptSubmit: 圧縮後に確認を促す"  'echo "{}" | pm-hook b UserPromptSubmit | grep -q "圧縮" && [ -z "$(echo "{}" | pm-hook b UserPromptSubmit)" ]'

# ---- dispatch（1 周だけ回して止める）
reset_stub; rm -f "$PM_CONFIG_DIR/state/"*.inbox.seen
pm init >/dev/null
mkdir -p "$PM_SHARED/inbox"
printf '# a inbox\n- [ ] 2026-11-04 10:00 テストを追加する\n' > "$PM_SHARED/inbox/a.md"
check "dispatch は inbox の追記を子へ送る" 'timeout 3 env PM_DISPATCH_INTERVAL=1 pm dispatch >/dev/null 2>&1; grep "^send-keys" "$STUB_STATE/tmux.log" | grep -q "親からの依頼.*テストを追加する"'
check "dispatch は送ったぶんを記録する"     '[ "$(cat "$PM_CONFIG_DIR/state/a.inbox.seen")" = "$(stat -c %s "$PM_SHARED/inbox/a.md")" ]'
: > "$PM_CONFIG_DIR/state/a.inbox.seen"
check "送信済み記録が空でも止まらず再送する" 'timeout 3 env PM_DISPATCH_INTERVAL=1 pm dispatch >/dev/null 2>&1; [ "$(cat "$PM_CONFIG_DIR/state/a.inbox.seen")" = "$(stat -c %s "$PM_SHARED/inbox/a.md")" ]'
n1="$(grep -c "^send-keys" "$STUB_STATE/tmux.log")"
check "dispatch は同じ内容を二度送らない"   'timeout 3 env PM_DISPATCH_INTERVAL=1 pm dispatch >/dev/null 2>&1; [ "$(grep -c "^send-keys" "$STUB_STATE/tmux.log")" = "$n1" ]'
printf -- '- [ ] 2026-11-04 10:05 二件目\n' >> "$PM_SHARED/inbox/a.md"
printf 'Do you want to proceed?\n❯ 1. Yes\n' > "$STUB_STATE/screen"
check "dispatch は選択待ちの子へ送らない"   'timeout 3 env PM_DISPATCH_INTERVAL=1 pm dispatch 2>&1 | grep -q "選択待ち"; [ "$(grep -c "^send-keys" "$STUB_STATE/tmux.log")" = "$n1" ]'
rm -f "$STUB_STATE/screen"
check "dispatch は選択が終われば送る"       'timeout 3 env PM_DISPATCH_INTERVAL=1 pm dispatch >/dev/null 2>&1; grep "^send-keys" "$STUB_STATE/tmux.log" | grep -q "二件目"'
printf -- '- [ ] 10:10 制御\r文字\033[Aあり\n' >> "$PM_SHARED/inbox/a.md"
check "dispatch は制御文字を落とす"           'timeout 3 env PM_DISPATCH_INTERVAL=1 pm dispatch >/dev/null 2>&1; grep "^send-keys" "$STUB_STATE/tmux.log" | grep -q "制御文字\[Aあり" && ! grep "^send-keys" "$STUB_STATE/tmux.log" | grep -q -P "\r"'

# ---- 構文
check "bash -n で全スクリプトが通る" 'for f in "$SRC"/bin/pm "$SRC"/bin/pm-lib.sh "$SRC"/bin/pm-child "$SRC"/bin/pm-hook "$SRC"/install.sh "$SRC"/uninstall.sh "$SRC"/share/pm-parent-run; do bash -n "$f" || exit 1; done'
check "pm-parent-run は不明な引数を拒否"  '! bash "$SRC/share/pm-parent-run" --evil 2>/dev/null'

# ---- 別ユーザー構成の親コマンド
reset_stub; rm -f "$PM_CONFIG_DIR/state/panes.tsv"
check "別ユーザー構成では sudo でラッパだけを呼ぶ" 'PM_PARENT_USER=pm-parent pm init >/dev/null && grep "^respawn-pane" "$STUB_STATE/tmux.log" | grep -q "sudo -n -H -u pm-parent /usr/local/bin/pm-parent-run$" && ! grep "^respawn-pane.*pm-parent-run" "$STUB_STATE/tmux.log" | grep -q "bash"'

# ---- install.sh の防御（実行はしない。引数検証だけ）
check "install.sh は --shared \$HOME を拒否"  'HOME="$TMP/home" bash "$SRC/install.sh" --shared "$TMP/home" --yes 2>&1 | grep -q "指定できません"'
mkdir -p "$TMP/notmine" && touch "$TMP/notmine/keep"
check "install.sh は中身のある既存ディレクトリを拒否" 'HOME="$TMP/home" bash "$SRC/install.sh" --shared "$TMP/notmine" --yes 2>&1 | grep -q "管理下ではありません" && [ -f "$TMP/notmine/keep" ]'
check "uninstall --purge は目印の無いディレクトリを消さない" 'mkdir -p "$TMP/cfg2" && printf "PM_SHARED=\"$TMP/notmine\"\n" > "$TMP/cfg2/config" && HOME="$TMP/home" PM_CONFIG_DIR="$TMP/cfg2" bash "$SRC/uninstall.sh" --prefix "$TMP/nowhere" --purge --yes >/dev/null 2>&1; [ -f "$TMP/notmine/keep" ] && [ -f "$TMP/cfg2/config" ]'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
