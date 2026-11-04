---
name: show-task
description: 案件の課題ファイルを表示する
argument-hint: <案件名>
disable-model-invocation: true
allowed-tools: Read Glob
---

案件 `$0` の課題ファイル `status/$0.md` を Read で読み、内容をそのまま表示してください。

- ファイルが無ければ、`workspaces.txt` の案件名を列挙して「未登録の案件です」と答える。
- 要約や解釈を加えず、ファイルの内容を先に出す。補足するなら未完了件数を 1 行だけ。
- 案件のパスやファイルを探さない。
