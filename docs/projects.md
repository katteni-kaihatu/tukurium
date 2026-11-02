# Projects（ローカル + VCS 骨格）

状態：ローカル FS 実装済み。Commit / History / Branches / Releases / Members のサービス API あり。リモート project-server は差替点のみ。
確認日：2026-11-02。

## 概要

Project はデザイン上「個人のリポジトリ」だが、**正本は Engine の `data_root` 配下のローカル FS** である。asset-server には載せない。セッション・ライブラリ作品向けの asset-server と、履歴・ブランチ・Resources 定義を持つリポジトリとは責務が違う。将来のリモートは **project-server**（環境変数 `TUKURIUM_PROJECT_SERVER`）を候補にし、同じクライアント API 境界の裏で差し替える（未実装時は明示エラー）。

配置例：

- `<data_root>/projects/<slug>/project.json` … メタ
- `<data_root>/projects/<slug>/world.json` … ワーキングツリー快照
- `<data_root>/projects/<slug>/commits/` … コミットメタ + `*.world.json`
- `<data_root>/projects/<slug>/branches.json` / `HEAD`
- `<data_root>/projects/<slug>/releases.json`
- `<data_root>/projects/<slug>/members.json` … Host / edit / view

## クライアント API

| action | 意味 |
|---|---|
| `projects` / `create_project` / `project` | 一覧・作成・詳細 |
| `open_project_workspace` | セッション作成＋快照読込 |
| `project_commit` / `project_history` / `project_diff` / `project_checkout` / `project_revert` | ローカルコミット履歴 |
| `project_working_status` | ワーキングツリーが clean か |
| `project_branch_create` / `project_branch_switch` / `project_branch_merge_main` | ブランチ（main への fast-forward のみ） |
| `project_releases` / `project_release_create` / `project_release_withdraw` | ローカルリリースメタ（asset-server 非掲載） |
| `project_members` / `project_member_upsert` | Host / 編集 / 閲覧 |

終了時の自動保存はワーキングツリー（`world.json`）へ。明示コミットと分離する。
セッション中に `project_commit` / `project_working_status` 等を呼ぶと、Engine は先にメモリ上の快照を `world.json` へ書いてから履歴処理する（`active_project` が一致するとき）。

**権限（当面）**：Host（作成者・1人・コミット／ブランチ／リリース／招待）／編集／閲覧。Host 操作は `actor_id`（サインインユーザ）が members の host と一致するときだけ通す。Host migration・オーナー譲渡は後続。

## Resources カタログ

| kind | 意味 |
|---|---|
| `folder` / `material` / `model` / `image` / `script` | 既存 |
| `kokostate` | 定義の仮想ファイル枠（クエリは後続） |
| `shader` / `package` | メタ枠（描画パイプライン未接続） |

## UI

- 個人 2D：service_panel の Projects。セッション窓の **作る / 探す / ライブラリ** ナビ。
- 共有 WorldPanel：Workspace（ピン可）。History / Releases / Members / Debug / Commit / Branch は個人 2D の `workspace_tool_overlay`（Project サービスを読む）。
- Resources / Script Editor / Inspector は共有 WorldPanel。Inspector 内 Hierarchy（Duplicate/Delete）。Play mode では編集ロック表示。

## 後続

- KokoState クエリと Systems 読み取りの Engine 実装
- Script 定義の本格的な仮想ファイル化と Slot 参照
- project-server リモートプロキシ本体
- 3D Diff の重ね合わせ表示
- Project を asset-server に載せる案は採らない
