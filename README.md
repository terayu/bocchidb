# BocchiDB

[日本語版はこちら](README.ja.md)

BocchiDB is a native Swift document database that syncs with [Apache CouchDB](https://couchdb.apache.org/) 3.x.
It is inspired by [PouchDB](https://pouchdb.com/): your app reads and writes a local database that keeps working
offline, and BocchiDB replicates changes with CouchDB using the standard CouchDB replication protocol.

The goal is compatibility with CouchDB replication, not a re-creation of the PouchDB JavaScript API.
Devices running BocchiDB, PouchDB and CouchDB can share the same database.

> **Status:** early (0.x). The API may change before 1.0.

## Features

- JSON document store on SQLite with CouchDB-style revisions (`_rev`), conflicts and deletions
- One-shot `pull` / `push` / `sync` and continuous **live sync** with CouchDB
- Sync status (`connecting` / `active` / `idle` / `offline` / `stopped`) for your UI
- Change notifications as an `AsyncStream`, for both local writes and replicated changes
- Mango queries, written the same way as CouchDB's `_find`
- Attachments (photos, PDFs, …), transferred as stubs when unchanged so they are not re-sent
- Automatic retry with exponential backoff; live sync keeps going through offline periods
- Basic and cookie (`_session`) authentication
- No third-party dependencies (Foundation, SQLite3 and CryptoKit only)

## Requirements

- iOS / iPadOS 17+ or macOS 14+
- Swift 6 (Xcode 16 or later)
- Apache CouchDB 3.x as the sync target

## Installation

BocchiDB is distributed with the Swift Package Manager.

**In an Xcode app:** choose **File › Add Package Dependencies…**, enter
`https://github.com/terayu/bocchidb`, pick a version rule (for example *Up to Next Minor* from `0.0.4`)
and add the `BocchiDB` library to your app target.

**In a Swift package:** add it to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/terayu/bocchidb", .upToNextMinor(from: "0.0.4")),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "BocchiDB", package: "bocchidb")]),
]
```

## Quick start

```swift
import BocchiDB

let url = URL.applicationSupportDirectory.appending(path: "inspections.sqlite")
let db = try BocchiDB(url: url)

// Create, read, update, delete
let rev = try await db.put(id: "inspection-001", body: ["temperature": 25.5, "ok": true])
let doc = try await db.get(id: "inspection-001")          // winning revision, or nil
let rev2 = try await db.put(id: "inspection-001", body: ["temperature": 26.0, "ok": true], rev: rev)
try await db.remove(id: "inspection-001", rev: rev2)
```

Updating or deleting a document requires its current `rev`. Writing with an outdated `rev`
throws `BocchiDBError.conflict`, as in CouchDB.

### Open modes

Choose how to open the file with `mode`.

```swift
let db = try BocchiDB(url: url)                      // .create: create the file if missing (default)
let db = try BocchiDB(url: url, mode: .readWrite)    // open an existing BocchiDB file only
let db = try BocchiDB(url: url, mode: .readOnly)     // read-only; writes and sync throw BocchiDBError.readOnly
```

`.readWrite` and `.readOnly` throw `BocchiDBError.fileNotFound` if the file does not exist. In every mode,
non-BocchiDB files and unsupported schema versions throw `BocchiDBError.unsupportedDatabase`, and missing
access to the file or folder throws `BocchiDBError.permissionDenied`.

`.readOnly` can safely read a file another app is writing to. It needs the `-wal` file next to the database
(otherwise it throws `BocchiDBError.walFileMissing`), and creates the `-shm` file if missing, which then
requires write access to the folder.

### Sync with CouchDB

```swift
let replicator = Replicator(
    local: db,
    remote: URL(string: "https://couch.example.com/inspections")!,
    auth: .session(username: "user", password: "secret"))

try await replicator.sync()   // push, then pull, once
```

### Live sync and status

`live()` keeps both directions in sync until its task is cancelled. Remote changes arrive through a
longpoll feed and local changes are pushed as soon as they are written. Transient errors (no network,
HTTP 5xx / 429, a server restart) are retried; permanent errors such as a wrong password stop it and are thrown.

```swift
let (statuses, continuation) = AsyncStream.makeStream(of: SyncStatus.self)
let live = Task { try await replicator.live { continuation.yield($0) } }

for await status in statuses {   // e.g. on the main actor, to update your UI
    switch status {
    case .connecting, .active: print("Syncing…")
    case .idle: print("Up to date")
    case .offline: print("Offline – will retry")
    case .stopped: print("Stopped")
    }
}
```

Cancel the task when your app moves to the background, and call `live()` again when it returns
to the foreground. In SwiftUI, starting it from `.task { }` does this for you.

### Observe changes

```swift
for await change in await db.observeChanges() {
    // Local writes and changes pulled from CouchDB alike
    print(change.id, change.revs.first!, change.deleted)
}
```

### Queries (Mango)

Search with the same selectors as CouchDB's `_find`. Comparison and sort order also match CouchDB.

```swift
let docs = try await db.find(FindQuery(
    selector: ["type": "inspection", "temperature": ["$gte": 25]],
    sort: [SortField("temperature", .descending)],
    limit: 10,
    fields: ["temperature", "site.name"]))

// Or build it from the JSON you would send to CouchDB
let query = try FindQuery(json: Data(#"{"selector": {"tags": {"$in": ["urgent"]}}}"#.utf8))
```

- Supported operators: `$eq` `$ne` `$gt` `$gte` `$lt` `$lte` `$in` `$nin` `$all` `$exists` `$type` `$size` `$mod`
  `$regex` `$beginsWith` `$elemMatch` `$allMatch` `$and` `$or` `$nor` `$not`
- Queries cover the winning revision of non-deleted documents. `_design/` documents are excluded.
- With `sort`, documents missing a sort field are left out of the results, as in CouchDB.
- Unlike CouchDB, `limit` defaults to unlimited and `sort` needs no index. `Document.id` and `rev` are always set,
  even when `fields` is given.
- `$regex` is evaluated with `NSRegularExpression`, so some patterns may differ from CouchDB (PCRE).
- There are no indexes yet; every document is read and matched. As a guide, 10,000 documents take about 0.3 s
  (Apple silicon Mac, release build).

### Attachments

```swift
try await db.putAttachment(id: "inspection-002", name: "photo.jpg",
                           contentType: "image/jpeg", data: jpeg, rev: current)
let photo = try await db.attachment(id: "inspection-002", name: "photo.jpg")
```

Updating a document's body with `put` keeps its attachments.

### Conflicts

When two devices edit the same document offline, both versions are kept after sync.
Every replica deterministically picks the same winner, which `get(id:)` returns. The others are
listed by `conflicts(id:)`. To resolve a conflict, delete the losing revisions, or update the
winner with merged content and then delete the losers.

```swift
for loser in try await db.conflicts(id: "inspection-001") {
    try await db.remove(id: "inspection-001", rev: loser)
}
```

## Limitations and notes

- **CouchDB 3.x only.** Other CouchDB-compatible servers (Cloudant, Couchbase Sync Gateway, …) are not targeted.
- **Mango queries only, without indexes yet.** Map/reduce views are not implemented. `_design/` documents
  are stored and replicated as ordinary documents.
- **Old revision bodies are discarded.** Only leaf revisions keep their body and attachments, as if
  compaction ran on every write. Fetching an old `rev` returns `nil`.
- **History is limited to `revsLimit` generations** (default 1000, the same as CouchDB). If one device edits
  the same document more than `revsLimit` times between syncs, a spurious conflict can appear. This is
  the same behavior as CouchDB. No data is lost, and the conflict can be resolved as usual.
- **Numbers** are kept as `Int64` or `Double` and compared by value (`26 == 26.0`). Integers beyond `Int64`
  or decimals beyond `Double` precision are not preserved.
- **Attachment digests** (`AttachmentInfo.digest`) are the MD5 of the raw data. CouchDB computes digests of
  gzip-compressed data for types it compresses (such as `text/*`), so the two values can differ.
- **Attachments are stored inside the SQLite file.** This works well for photos of a few MB. Very large files
  may be better kept outside the database.
- **Pull needs write access to the remote database**, because sync checkpoints are stored on both sides.
- **No background sync on iOS yet.** Run `live()` while the app is in the foreground. Running a one-shot
  `sync()` from a background task is possible but not built in.
- CouchDB temporarily locks an account after repeated authentication failures. Since BocchiDB does not
  retry authentication errors, a misconfigured password does not keep hitting the server.

## Development

```sh
swift test                       # unit and property-based tests
```

Interoperability tests run against a real CouchDB, with PouchDB acting as a second device:

```sh
cd interop
docker compose up -d             # or: podman compose up -d (CouchDB on localhost:45984)
npm install
cd ..
BOCCHIDB_COUCHDB_URL=http://admin:password@localhost:45984 swift test
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

BocchiDB is licensed under the [Apache License 2.0](LICENSE). See [NOTICE](NOTICE).

Apache CouchDB and CouchDB are trademarks of The Apache Software Foundation. BocchiDB is not affiliated
with or endorsed by the Apache Software Foundation or the PouchDB project.
