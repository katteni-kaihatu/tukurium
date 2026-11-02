**tukuriumは、ECSエンジンとGodotクライアントを別プロセスにする案から始める**

設計日：2026-10-22。Rust / bevy_ecs / Godotを採用し、最初の共同編集を実装した。現在の範囲と起動方法は [README](../README.md)、実装の詳細は [runtime.md](runtime.md) を参照。本書は、未実装の段階も含む全体設計を記録する。Tonariumとは独立したプロジェクト、Resoniteのような共同編集、エンジンとレンダラーの分離、デスクトップ優先・VRは後から、KokoSyncはデータパイプとして使う、という方針を維持する。

最初に確かめたい体験は「2人が同じワールドに入り、目の前の箱のインスペクタを開き、名前・色・位置を変更すると、相手にも変更が見える」こと。そのうえで、部品の追加・削除、アイテムの複製、内部の小さなFluxグラフへ広げる。

**技術選定：ECSにはBevyの一部を使い、画面と操作にはGodotを使う**

BevyとGodotを全面的に併用する案ではない。エンジンには独立利用できるRustの `bevy_ecs` を使い、Godotには画面、入力、アセット表示、実行時UIを担当させる。両者の接続コードとプロトコルは自作になる。

| 選択肢 | コアのECS化・独立性 | 実行時のUI作成 | 主な負担 | 判断 |
|---|---|---|---|---|
| Rust / bevy_ecs + Godot | コアから描画依存を排除できる | ControlとSubViewportを利用できる | 2言語、プロセス間通信、表示側への対応付け | 今回の推奨 |
| Rust / bevy_ecs + Bevyクライアント | Rustで型や道具を共有しやすい | Bevy UIなどで製品用UIを作る | UI、文字入力、ワールド内パネルの設計・実装を重点的に検証する必要 | Rustへの統一を重視する場合の候補 |
| Godot中心のクライアントとヘッドレスサーバー | 分離自体は可能。ECSは別途設計が必要 | GodotのUIを利用できる | ワールドモデルがSceneTreeに依存しやすい | ECSコアを重視する今回の第一候補にはしない |

この比較の「作りやすさ」は、本プロトタイプの目的からの判断であり、性能ベンチマークではない。Bevyでも描画を別プロセスにできるが、レンダープラグインを外すだけでプロセス分離や通信が完成するわけではない。

根拠：`bevy_ecs` は単独のcrateとして利用できる。[Bevy ECSの公式文書](https://docs.rs/bevy_ecs/latest/bevy_ecs/)。Bevyの機能はプラグインとして構成できる。[プラグインの公式説明](https://bevy.org/learn/quick-start/getting-started/plugins/)。GodotのControlはUIの基底で、SubViewportはUIを3D空間に表示する用途を持つ。[Control](https://docs.godotengine.org/en/stable/classes/class_control.html)、[SubViewport](https://docs.godotengine.org/en/stable/classes/class_subviewport.html)。

依存バージョンは実装開始時に安定版を選び、ロックファイルなどで固定する。本書のlatest/stableリンクの内容は今後変わり得る。

**エンジンと表示の分離は、各参加者のPC内で行う**

```text
ホストPC                              ゲストPC
Godotクライアント                    Godotクライアント
  描画・入力・インスペクタ             描画・入力・インスペクタ
       ↕ ローカルIPC                       ↕ ローカルIPC
Engineプロセス                       Engineプロセス
  正本のECSワールド                    ECSワールドの複製
  編集検証・Flux・セッション管理         受信状態の反映・表示情報の生成
       ↕────── KokoSync経由の同期 ──────↕
```

ホストはクライアントごとの編集要求を検証し、順序を付けて適用する。ゲストのEngineはホストが確定した変更を反映する。初版では共有状態を変更するFluxもホストでだけ実行する。同じ副作用を参加人数分実行しないための選択で、Resoniteの実行方式をそのまま再現するものではない。

専用サーバーを使うときは、同じEngineを権威側として表示なしで起動し、全員がゲストとして接続する。最初はホスト1人＋ゲスト1人、localhostまたはLANで成立させる。インターネット越しの接続補助やホスト移譲は次の段階で扱う。

プロセス分離の目的は、描画の都合とエンジン更新を切り離すこと。IPCの処理やアセット生成でGodot自身が詰まれば表示は止まるため、分離だけで常に滑らかになるとは保証しない。

**どのデータを誰が持つかを固定する**

| データ・処理 | 所有する場所 |
|---|---|
| ObjectRoot、Slot、部品、フィールドの確定値 | ホストEngineが正本。ゲストEngineが複製 |
| 共有オブジェクトの移動、編集権限、変更履歴 | Engine |
| Flux定義と共有状態を変更する実行 | Engine。初版の実行担当はホスト |
| 描画インスタンス、GodotのNode・RID・Resource | Godotクライアント |
| マウス、キーボード、ローカルカメラ、IME、未公開のコードドラフト | Godotクライアント |
| 表示用の位置補間・操作中プレビュー | Godotクライアント。確定値と別扱い |
| ワールド内インスペクタの位置・対象・サイズ・スクロール | Engineの共有ワールド状態。保存対象 |
| インスペクタのキー入力・IME・ポインター捕捉 | 操作しているGodotクライアント |
| 共有インスペクタの編集者・編集中の表示 | Engineの一時的なセッション状態 |

GodotのSceneTreeを共有ワールドの正本にしない。表示用Nodeのプロパティ変更をそのままネットワーク同期する構造にせず、操作をEngineへの要求に変換する。UIはGodotエディタのInspectorを埋め込むのではなく、ゲーム実行中に動く独自のインスペクタを作る。

Godotの高水準マルチプレイはSceneTreeを基盤にするため、本案のワールド同期には使わない。Godotからは標準TCPなどを通じてローカルEngineと通信する。[高水準マルチプレイ](https://docs.godotengine.org/en/stable/tutorials/networking/high_level_multiplayer.html)、[StreamPeerTCP](https://docs.godotengine.org/en/stable/classes/class_streampeertcp.html)。

**ワールド内では、アイテムの所属と座標の親子関係を分ける**

一つの実行中ワールドにつき一つのECS Worldを持たせる。ObjectRootごとのECS Worldには分割しない。すべてのSlotと部品に所属するObjectInstanceを記録し、アイテム内部の参照範囲を検証する。

```text
ObjectInstance { instance_id, root_slot, revision }
Identity       { owner_instance, local_id }
Slot           { name, local_parent, local_transform }
Component      { host_slot, type_id, enabled }
MeshRenderer   { mesh_asset, material_asset }
Light          { color, intensity, range }
FieldSchema    { field_id, value_type, access, persistence, replication }
```

上は論理モデルであり、すべてを同じstructや汎用Dictionaryに詰める指定ではない。メッシュやライトの値は型付きデータとして格納する。部品のインスタンス自体をEntityにし、同じSlotへ同種の部品を複数付けられる形にする。

アイテムへの所属、内部の親子関係、外部へのAttachmentを区別する。箱をアバターの手に取り付けても所属は変わらない。内部参照は同じObjectInstanceだけを指す。外部参照は明示したポートやハンドルを通し、取り付け関係を含む座標依存には循環を許さない。

保存・同期には `(instance_id, local_id)`、フィールドにはさらに安定した `field_id` を使う。ECSのEntity番号、配列位置、GodotのNodePathはワイヤ形式にしない。削除したlocal_idは同一Instance内で再利用せず、複製では新しいinstance_idを割り当てて内部local_idを維持する。実行用ハンドルはEngine内部で解決し、削除や再構築で失効させる。

**インスペクタはスキーマと購読データから生成する**

部品の型ごとに、フィールドのID、表示名、値の型、読み書き可能性、値域などをEngineへ登録する。Godotはこの定義を受け取り、boolならチェックボックス、floatなら数値欄、色ならカラーピッカーを作る。Godotの表示用ノードを調べて部品一覧を作る方式にはしない。

部品ツリーとフィールド値は、開いているインスペクタの対象について購読する。巨大なワールドの全メタデータを毎フレーム送らない。操作の経路は次のとおり。

```text
インスペクタで値を変更
  → ローカルEngineへEditorCommand
  → ホストが型・値域・権限・競合を検証
  → ECSの値を更新し、revision付きの変更を発行
  → 各Engineが反映
  → 各Godotが表示とインスペクタ値を更新
```

EditorCommandはユーザーの編集権限で対象を操作する。これは、アイテム内部のFluxへ外部参照を無制限に渡すこととは別の権限経路とする。

同じパネルを共有する場合は、PanelId、対象アドレス、位置、サイズを複製し、UIの見た目は各Godotで構築する。2026-10-23の[Resonite調査と実装](resonite-world-inspectors.md)では、最大16枚のパネルと、スクロール・編集中のユーザー・文字表示の共有を追加した。キー入力先やIME処理はローカルに保ち、フィールド単位の編集占有とrevisionで競合を扱う。階層の展開状態の共有は、Slotの親子構造を導入する段階で扱う。

3DパネルはControlをSubViewportへ描き、板状メッシュに貼る。画面上のマウスから板との交点を求め、UVをパネル座標へ変換して入力を渡す。SubViewportの表示だけでは3D空間からの入力転送は完成しないので、この処理も試作範囲に含める。

**編集の同期は、ホストによる順序付けとフィールド単位のrevisionから始める**

```text
SetField {
  command_id,
  target: { instance_id, local_id },
  field_id,
  expected_field_revision,
  typed_value
}
```

ホストは現在のフィールドrevisionと一致した要求だけを適用する。別フィールドの変更で不要な競合を起こさないため、通常のSetFieldにはワールド全体のrevisionを条件にしない。構造編集は対象ObjectInstanceのrevisionを検証する。command_idによる重複排除は接続・ユーザー単位で行う。

同じ色を2人が同時に変更した場合、先に確定した変更が成功し、古いrevisionの要求は現在値とともに拒否される。UIは成功・保留・拒否を区別する。ドラッグでは対象への期限付き編集権を取得し、入力中はローカルプレビューを表示する。切断時に編集権を解放し、拒否されたプレビューは確定値へ戻す。

書き込みの確定経路を共通化し、ユーザー編集、Flux、将来の物理計算で型検証と変更記録を使い回す。ECSライブラリの変更検出だけに、ネットワーク上の権限や競合処理を任せない。

**IPCには、ワールド全体ではなく表示用データと編集用データを渡す**

最初は両PC内のEngineとGodotをloopback TCPで接続し、長さ付きUTF-8 JSONメッセージを使う。RustとGDScriptから確認しやすいことを優先した初期案。最大メッセージ長、protocol_version、接続epoch、sequenceを定義する。共有メモリや独自バイナリ形式は計測後に検討する。

| 種別 | 内容 | 配送・適用 |
|---|---|---|
| Control | 接続、スキーマ、生成・削除、部品変更、編集結果 | 順序を保ち、省略しない |
| RenderFrame | RenderId、位置・回転・スケールなど | 未表示の古いフレームを置き換えられる |
| InspectorUpdate | 購読中の値、revision、削除通知 | 対応する編集結果と整合させる |
| Input / Intent | 移動、選択、操作、編集要求 | 種類ごとに頻度と順序を規定する |

RenderFrameには前提となるControlのsequenceを持たせ、生成・削除が反映されてから適用する。RenderIdは生成世代を含めて古いフレームによる復活を防ぐ。Godotは受信処理をフレームごとに制限し、残りがあるときも入力と描画を継続する。接続が切れたら無制限に差分を蓄積せず、再接続時に表示用スナップショットを取り直す。

アセットはIDで指定する。最初は箱・球・床と少数の標準マテリアルで十分。後から任意アセットを扱うときは、コンテンツハッシュとキャッシュを導入し、大きなアセット転送が制御や位置更新を塞がない経路を追加する。

ホストとゲストのネットワーク配送にはKokoSyncを使い、ローカルIPCとは切り離す。KokoSyncへ渡すアプリのメッセージはtukurium独自の形式にする。Tonariumのメッセージ型、状態モデル、暗号化形式、互換処理は使わない。順序を保つ編集要求・確定変更と、古い値を捨てられる位置・姿勢を別の配送方式へ振り分ける。Rust SDKがない現状ではGo SDKを使う通信プロセスを初期の候補とする。具体的な責務、SDK接続、初回同期は [KokoSyncをデータパイプとして使う設計](kokosync.md) を参照。

**Fluxと物理の担当はコア側に残す**

Fluxは保存用グラフ、コンパイル済み実行計画、Instanceごとの実行状態を分ける。初期ノードは定数、四則演算、比較、イベント、フィールドRead/Write、時間、Drive程度に絞る。任意コードの実行を初版の機能に含めない。

内部のLocalRefはビルド時に型とObjectRoot境界を検証する。外部取得は明示したハンドルを返し、権限と生存状態を使用時にも確認する。削除や編集中に常に参照が存在するとは仮定しない。実行計画の再構築と構造変更は安全な更新境界で反映し、ループには実行ステップ数の上限を設ける。

共有状態を動かす物理計算は将来Engineに導入する。Godotの剛体シミュレーションを共有状態の正本にしない。最初は静的な床とEngine管理の簡単な移動に絞り、Godotの衝突判定は表示・選択用に限定する。

VRを追加するときは、カメラと頭・手の最新姿勢をGodot側で即座に表示する。共有する姿勢はEngineへ入力として送り、表示をEngineやネットワークの往復に待たせない。入力をマウス固有の操作から分離し、ポインター、選択、つかむ、移動などのIntentにしておく。[GodotのXR構成](https://docs.godotengine.org/en/stable/tutorials/xr/setting_up_xr.html)。初期対応はHMDでの見回しと移動に絞る。[VR対応の計画](vr-support-plan.md)で、セッションを維持する表示切り替え、Godot 4.7.2の初期化制約、段階ごとの完了条件を整理する。手と頭の詳細な姿勢同期は後続の対象とする。

**段階ごとの試作で、分離と共同編集を検証する**

| 段階 | 作るもの | 確認する結果 |
|---|---|---|
| 1 | EngineとGodotの2プロセス、箱の表示、ローカルカメラ | Engine更新を意図的に遅らせてもカメラとUIが応答する。Godot再接続で表示を復元できる |
| 2 | ホスト・ゲスト、アバター代用図形、部品ツリー、インスペクタ | 2クライアントで同じ箱の名前・色・位置が一致する。途中参加でも同じ状態になる |
| 3 | 3D空間内の共有パネル、部品の追加削除、複製、編集競合 | 両者から操作でき、同時編集・対象削除・切断を処理できる |
| 4 | 最小Flux、ObjectRoot検証、保存と再ロード | 箱の色や位置を内部グラフで動かせる。複製したアイテムの状態が混ざらない。保存後も内部参照が保たれる |

最初のデスクトップ操作はWASD移動、マウス視点、選択、インスペクタを開く、生成・複製・削除とする。表示用の簡単なドックを段階2で作っても、到達目標には段階3のワールド内パネルを含める。

VR、音声、アバター取り込み、任意アセットの配布、物理の本格実装、全ノード互換、クラウド保存、ユーザーアカウント、ホスト移譲は、最初の共同編集を検証した後に設計する。Resoniteの全機能互換を初期の完了条件にはしない。

実装後の検証には、localhost上の2クライアント、LAN上の2台、途中参加、同時SetField、編集権を保持した切断、参照先削除、複製・再ロード、Godot再起動を含める。Godotの描画用状態とEngineの確定状態がずれたときは、スナップショットから復元できることも確認する。

**想定するディレクトリと、実装前に確認する判断**

```text
kokoverse-proto/
  crates/
    core/          ECSワールド、型、編集、保存
    protocol/      IPC・ネットワークのメッセージ定義
    engine/        起動、ホスト/ゲスト、ループと通信
    flux/          グラフ検証、実行計画、実行状態
  client-godot/    表示、入力、インスペクタ
  tools/
    kokosync-adapter/  Go SDKで通信する初期候補
  schemas/        言語間で共有するワイヤ仕様・テスト例
  tests/          複数プロセスでの統合検証
  docs/
```

上は全体の配置案。core / protocol / engine / client-godot / kokosync-adapterは実装済みで、fluxはまだない。

最初の実装にはRust + Godotを採用した。PC間の配送にはGo SDKを使うアダプターを加えた。ECS化・独立プロセス・ObjectRootの境界を維持し、今後ワールド内の共同編集へ広げる。

最初の実装と検証内容は [runtime.md](runtime.md) と [README](../README.md) に記録する。大規模ワールドの性能測定はまだ行っていない。
