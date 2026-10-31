# Projects（v0・ローカル）

状態：実装済み（ローカル FS）。リモート同期は未実装。
確認日：2026-10-31。

## 概要

Project はデザイン上「個人のリポジトリ」だが、**v0 の正本は Engine の `data_root` 配下のローカル FS** だけである。asset-server には載せない。セッション・ライブラリ作品向けの asset-server と、履歴・ブランチ・Resources 定義を持つリポジトリとは責務が違う。将来のリモートは **project-server**（仮称）を候補にし、同じクライアント API 境界の裏で差し替える。

配置例：

- `<data_root>/projects/<slug>/project.json` … メタ（slug・表示名・説明・更新時刻）
- `<data_root>/projects/<slug>/world.json` … ワールド快照（Slot 上の ScriptComponent＝状態一体を含む）

## クライアント API（薄い境界）

Godot / Engine からは次だけを見る。v0 実装は Engine 内のローカル FS。

| action | 意味 |
|---|---|
| `projects` | 一覧（query / offset） |
| `create_project` | 作成（空ワールド快照付き） |
| `project` | 詳細 |
| `open_project_workspace` | `create_session`＋`load_world` で快照を開く |

終了時（leave / エンジン停止の既存保存経路）に、開いている Project の `world.json` へ自動上書きする。v0 に Commit UI はない。

## Resources と Script（中間地点）

仮想ファイルとしてはまだ分けない。Resources WorldPanel から作れる単位は **Script と実行状態を一体にした ScriptComponent** で、選択中 Slot へ既存の Attach 経路で付与する。編集は分離した **Script Editor** WorldPanel。インスペクタの Scripts タブ編集は外し、リンクだけ残す。

将来（この文書の範囲外）：Script 定義をプロジェクトの仮想リソースとして保存し、KokoState のクエリで適用先 Slot を選ぶ。

## UI

- 個人 2D：service_panel の Projects（一覧・作成・詳細・ワークスペースで開く）。「ローカルのみ」と明記。共有パネルは個人 UI から自動生成しない。
- セッション内共有：Resources / Script Editor は WorldPanel。入口は Edit ドックとリング（Resources）。

## 後続

- Script 仮想ファイル化と KokoState クエリ
- project-server 本体とリモート同期
- Commit / History / Releases / Members
- Project を asset-server に載せる案は採らない
