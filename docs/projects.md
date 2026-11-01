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

## Resources カタログ（ローカル）と Script

Resources WorldPanel はデザイン上のエクスプローラ UI で、**ローカル Project（またはワークスペース）のカタログ**を扱う。

配置例：

- `<data_root>/projects/<slug>/resources/catalog.json` … フォルダ／項目メタ
- `<data_root>/projects/<slug>/resources/files/<id>.<ext>` … 取り込んだメッシュ・テクスチャ実体
- Project 未オープン時は `<data_root>/workspace-resources/` を使う

| kind | 意味 | 操作 |
|---|---|---|
| `folder` | フォルダ | New → Folder |
| `material` | 色マテリアル | New で追加。選択物体の `color` へ適用 |
| `model` | メッシュ（glTF/FBX） | 外部インポート。ワールドへ配置は既存 `ImportAsset` |
| `image` | テクスチャ | 外部インポート。ワールドへ画像 Slot を置く |
| `script` | Script の控え | New から選択 Slot へ ScriptComponent を Attach（編集は Script Editor） |

サービス action：`project_resources` / `project_resource_upsert` / `project_resource_remove`（必要なら `project_resource_store_file`）。asset-server にはカタログ本体を載せない。モデル配置時のバイナリ共有は既存のアセット転送を使う。

将来（この文書の範囲外）：Script 定義の仮想ファイル化、KokoState クエリ、prefab / shader / node system。

## UI

- 個人 2D：service_panel の Projects（一覧・作成・詳細・ワークスペースで開く）。「ローカルのみ」と明記。共有パネルは個人 UI から自動生成しない。
- セッション内共有：ワークスペース・メインパネル（[workspace_view.gd](../client-godot/workspace_view.gd)）は WorldPanel。配置とピンを共有。Edit ドックから開く。Project／セッション入口・Edit/Play・Inspector／Resources 起動は既存操作へのショートカット（History 等は非活性）。
- セッション内共有：Resources / Script Editor は WorldPanel。入口は Edit ドックとリング（Resources）。

## 後続

- Script 仮想ファイル化と KokoState クエリ
- project-server 本体とリモート同期
- Commit / History / Releases / Members
- Project を asset-server に載せる案は採らない
