# BocchiDB

[English](README.md)

BocchiDB は、[Apache CouchDB](https://couchdb.apache.org/) 3.x と同期できる、Swift ネイティブの文書データベースです。
[PouchDB](https://pouchdb.com/) から着想を得ています。アプリはオフラインでも動くローカルのデータベースを読み書きし、
BocchiDB が CouchDB 標準のレプリケーションプロトコルで変更を同期します。

目指しているのは CouchDB のレプリケーションとの互換性で、PouchDB の JavaScript API を再現することではありません。
BocchiDB・PouchDB・CouchDB を使う端末同士で、同じデータベースを共有できます。

> **状態：** 初期段階（0.x）です。1.0 までは API が変わる可能性があります。

## 機能

- SQLite 上の JSON 文書ストア。CouchDB と同じ Revision（`_rev`）、競合、削除の仕組み
- CouchDB との一回きりの `pull` / `push` / `sync` と、継続的な **Live Sync**
- 画面表示に使える同期状態（`connecting` / `active` / `idle` / `offline` / `stopped`）
- 変更の通知（`AsyncStream`）。ローカルでの書き込みも、同期で取り込んだ変更も通知されます
- Mango クエリ（CouchDB の `_find` と同じ書き方）による検索
- 添付ファイル（写真、PDF など）。変わっていない添付は stub で送り、送り直しません
- 指数バックオフによる自動再試行。Live Sync はオフラインの間も止まりません
- Basic 認証と Cookie（`_session`）認証
- 外部ライブラリへの依存なし（Foundation・SQLite3・CryptoKit のみ）

## 動作環境

- iOS / iPadOS 17 以上、または macOS 14 以上
- Swift 6（Xcode 16 以降）
- 同期先は Apache CouchDB 3.x

## インストール

Swift Package Manager で配布しています。

**Xcode のアプリの場合：** メニューの **File › Add Package Dependencies…** を選び、
`https://github.com/terayu/bocchidb` を入力します。バージョンの規則（例：`0.0.5` から *Up to Next Minor*）を選び、
`BocchiDB` ライブラリをアプリのターゲットに追加します。

**Swift パッケージの場合：** `Package.swift` に追加します。

```swift
dependencies: [
    .package(url: "https://github.com/terayu/bocchidb", .upToNextMinor(from: "0.0.5")),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "BocchiDB", package: "bocchidb")]),
]
```

## 使い方

```swift
import BocchiDB

let url = URL.applicationSupportDirectory.appending(path: "inspections.sqlite")
let db = try BocchiDB(url: url)

// 作成・取得・更新・削除
let rev = try await db.put(id: "inspection-001", body: ["temperature": 25.5, "ok": true])
let doc = try await db.get(id: "inspection-001")          // 勝者 Revision。なければ nil
let rev2 = try await db.put(id: "inspection-001", body: ["temperature": 26.0, "ok": true], rev: rev)
try await db.remove(id: "inspection-001", rev: rev2)
```

文書を更新・削除するには、現在の `rev` を渡します。古い `rev` で書き込むと、CouchDB と同じく
`BocchiDBError.conflict` になります。

### ファイルの開き方

`mode` で開き方を選べます。

```swift
let db = try BocchiDB(url: url)                      // .create: なければ作成（既定）
let db = try BocchiDB(url: url, mode: .readWrite)    // 既存の BocchiDB ファイルだけを開く
let db = try BocchiDB(url: url, mode: .readOnly)     // 読み取り専用。書き込みと同期は BocchiDBError.readOnly
```

`.readWrite` と `.readOnly` は、ファイルがなければ `BocchiDBError.fileNotFound` になります。どのモードでも、
BocchiDB 以外のファイルや対応していないスキーマのバージョンでは `BocchiDBError.unsupportedDatabase`、
ファイルやフォルダへのアクセス権が足りなければ `BocchiDBError.permissionDenied` になります。

`.readOnly` は、他のアプリが書き込み中のファイルも安全に読めます。ただし隣に `-wal` ファイルが必要で
（なければ `BocchiDBError.walFileMissing`）、`-shm` ファイルがなければ作るため、そのときはフォルダへの書き込み権限が要ります。

### CouchDB との同期

```swift
let replicator = Replicator(
    local: db,
    remote: URL(string: "https://couch.example.com/inspections")!,
    auth: .session(username: "user", password: "secret"))

try await replicator.sync()   // push してから pull を 1 回
```

### Live Sync と同期状態

`live()` は、タスクがキャンセルされるまで双方向の同期を続けます。CouchDB の変更は longpoll で受け取り、
ローカルの変更は書き込まれるとすぐに送ります。一時的なエラー（通信できない、HTTP 5xx / 429、サーバーの再起動）は
再試行します。パスワードの誤りなど一時的でないエラーでは止まり、そのエラーを投げます。

```swift
let (statuses, continuation) = AsyncStream.makeStream(of: SyncStatus.self)
let live = Task { try await replicator.live { continuation.yield($0) } }

for await status in statuses {   // MainActor 上で画面を更新するなど
    switch status {
    case .connecting, .active: print("同期中…")
    case .idle: print("最新")
    case .offline: print("オフライン（自動で再接続します）")
    case .stopped: print("停止")
    }
}
```

アプリがバックグラウンドに回るときにタスクをキャンセルし、フォアグラウンドに戻ったら `live()` をもう一度呼びます。
SwiftUI では `.task { }` から始めると、この扱いが自動で行われます。

### 変更の通知

```swift
for await change in await db.observeChanges() {
    // ローカルでの書き込みも、CouchDB から取り込んだ変更も届く
    print(change.id, change.revs.first!, change.deleted)
}
```

### 検索（Mango クエリ）

CouchDB の `_find` と同じセレクタで検索できます。比較と並べ替えの順序も CouchDB と同じです。

```swift
let docs = try await db.find(FindQuery(
    selector: ["type": "inspection", "temperature": ["$gte": 25]],
    sort: [SortField("temperature", .descending)],
    limit: 10,
    fields: ["temperature", "site.name"]))

// CouchDB に送る JSON からも作れます
let query = try FindQuery(json: Data(#"{"selector": {"tags": {"$in": ["urgent"]}}}"#.utf8))
```

- 対応する演算子：`$eq` `$ne` `$gt` `$gte` `$lt` `$lte` `$in` `$nin` `$all` `$exists` `$type` `$size` `$mod`
  `$regex` `$beginsWith` `$elemMatch` `$allMatch` `$and` `$or` `$nor` `$not`
- 削除されていない文書の勝者 Revision が対象です。`_design/` の文書は含みません。
- `sort` を指定すると、並べ替えるフィールドがない文書は結果に含まれません（CouchDB と同じ）。
- CouchDB と違い、`limit` の既定は無制限で、`sort` に索引は要りません。`fields` を指定しても `Document.id` と `rev` は常に入ります。
- `$regex` は `NSRegularExpression` で評価するため、CouchDB（PCRE）と書き方が異なる場合があります。

索引を作ると、条件に合う文書だけを読むので速くなります。索引がなければ全文書を読んで照合します（1 万件で約 0.2〜0.3 秒）。

```swift
try await db.createIndex(fields: ["site"])
try await db.createIndex(fields: ["type", "temperature"])
try await db.indexes()                 // [IndexInfo(name:fields:)]
try await db.deleteIndex(name: "...")
```

- 索引の有無で `find` の結果は変わりません。索引は候補を絞るためだけに使い、最終的な照合はいつも同じ方法で行います。
- 索引は書き込みのたびには更新せず、次の `find` で変わった文書の分だけ反映します（CouchDB と同じ）。
- 索引が使われるのは、トップレベルの条件（`$and` でつないだもの）に、索引のすべてのフィールドへの条件があるときです。
  `$or` だけのセレクタや、`$exists: false` では使われません。
- 効果が大きいのは、数値・真偽値・null の等価と範囲、文字列の等価、`$beginsWith`、`$in` です。
  文字列の範囲（`"$gte": "a"` など）は、文字列の照合順序が OS の ICU に依存するため索引で絞り込まず、文字列を持つ文書すべてを候補にします。
  ASCII・かな・漢字・Latin-1 以外の文字を含む文字列も、同じ理由で常に候補に入ります。
- 目安（M 系 Mac、release ビルド、5 万件）：条件に合う文書が 1〜3% の検索は約 0.9 秒 → 約 0.02〜0.03 秒。
  索引の作成は 1 つあたり約 1 秒です。
- `.readOnly` で開いた DB では索引を作成・削除できません。最新の状態まで反映済みの索引だけを使い、そうでなければ全文書を読みます。

### 添付ファイル

```swift
try await db.putAttachment(id: "inspection-002", name: "photo.jpg",
                           contentType: "image/jpeg", data: jpeg, rev: current)
let photo = try await db.attachment(id: "inspection-002", name: "photo.jpg")
```

`put` で本文だけを更新しても、添付はそのまま残ります。

### 競合

2 台の端末がオフラインで同じ文書を編集すると、同期後も両方の版が残ります。どの端末でも同じ規則で同じ勝者が選ばれ、
`get(id:)` はその勝者を返します。それ以外の版は `conflicts(id:)` で取得できます。競合を解消するには、
敗者の Revision を削除するか、内容をまとめて勝者を更新してから敗者を削除します。

```swift
for loser in try await db.conflicts(id: "inspection-001") {
    try await db.remove(id: "inspection-001", rev: loser)
}
```

## 制約と注意点

- **同期先は CouchDB 3.x のみです。** CouchDB 互換のほかのサーバー（Cloudant、Couchbase Sync Gateway など）は対象外です。
- **検索は Mango クエリのみです。** map/reduce の View は未実装です。`_design/` の文書は、通常の文書として保存・同期します。
- **古い Revision の本文は残しません。** 本文と添付を保持するのはリーフの Revision だけで、書き込みのたびに
  Compaction が行われている状態です。古い `rev` を指定して取得すると `nil` になります。
- **履歴は `revsLimit` 世代まで**（既定 1000、CouchDB と同じ）です。同期の合間に 1 台の端末で同じ文書を `revsLimit` 回を超えて
  編集すると、偽の競合が出ることがあります。これは CouchDB と同じ動作です。データは失われず、通常の競合と同じ手順で解消できます。
- **数値**は `Int64` か `Double` で保持し、値として比較します（`26 == 26.0`）。`Int64` を超える整数や、`Double` の精度を超える小数は保持できません。
- **添付の digest**（`AttachmentInfo.digest`）は元データの MD5 です。CouchDB は圧縮して保存する種類（`text/*` など）について
  圧縮後のデータから digest を計算するため、値が一致しないことがあります。
- **添付は SQLite ファイルの中に保存します。** 数 MB 程度の写真なら問題ありませんが、非常に大きなファイルはデータベースの外に置くほうがよい場合があります。
- **pull にもリモートのデータベースへの書き込み権限が必要です。** 同期のチェックポイントを両側に保存するためです。
- **iOS のバックグラウンド同期にはまだ対応していません。** `live()` はアプリがフォアグラウンドにある間に動かしてください。
  バックグラウンドタスクから一回きりの `sync()` を呼ぶことはできますが、組み込みの仕組みはありません。
- CouchDB は認証の失敗が続くとアカウントを一時的にロックします。BocchiDB は認証エラーを再試行しないので、パスワードを誤設定しても
  サーバーに失敗を送り続けることはありません。

## 開発

```sh
swift test                       # 単体テストとプロパティベーステスト
```

互換性テストは、実際の CouchDB に対して、PouchDB を 2 台目の端末として動かして行います。

```sh
cd interop
docker compose up -d             # または podman compose up -d（CouchDB が localhost:45984 で起動）
npm install
cd ..
BOCCHIDB_COUCHDB_URL=http://admin:password@localhost:45984 swift test
```

開発に参加する際は [CONTRIBUTING.md](CONTRIBUTING.md) を参照してください。

## ライセンス

[Apache License 2.0](LICENSE) で提供しています。[NOTICE](NOTICE) も参照してください。

Apache CouchDB と CouchDB は The Apache Software Foundation の商標です。BocchiDB は Apache Software Foundation や
PouchDB プロジェクトとは関係がなく、それらの承認を受けたものではありません。
