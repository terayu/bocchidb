# Contributing to BocchiDB

[日本語は下にあります](#日本語)

Thank you for your interest in BocchiDB. Issues and pull requests are welcome.

## Before you start

- For a bug, please include the steps to reproduce it, and the CouchDB version if sync is involved.
- For a larger change or a new feature, please open an issue first so the design can be discussed.

## Development setup

- Xcode 16 or later (Swift 6), macOS 14 or later
- For the interoperability tests: Docker or Podman, and Node.js

```sh
swift test                       # unit and property-based tests

cd interop && docker compose up -d && npm install && cd ..
BOCCHIDB_COUCHDB_URL=http://admin:password@localhost:45984 swift test   # including interop tests
```

## Guidelines

- **Tests first.** Every change needs tests. Changes to sync behavior should include an interoperability
  test against CouchDB (`Tests/BocchiDBTests/InteropTests.swift`), using PouchDB as another device
  (`interop/pouch-device.mjs`) where it helps.
- **Keep it dependency-free.** The library uses only Foundation, SQLite3 and CryptoKit. Please discuss
  before adding a dependency.
- **Match CouchDB.** When behavior is in doubt, the [CouchDB documentation](https://docs.couchdb.org/)
  and the behavior of a real CouchDB 3.x server are the reference.
- **Keep changes focused.** Avoid unrelated refactoring and formatting changes in the same pull request.

## Using code from other projects

- The CouchDB documentation (replication protocol, HTTP API) is the specification.
- Reading the PouchDB or CouchDB source to understand behavior is fine.
- If you port code from PouchDB or CouchDB (both Apache-2.0), state the origin in the file and add the
  attribution to `NOTICE` in the same pull request.
- Do not add code under licenses incompatible with Apache-2.0.

## License

By contributing, you agree that your contributions are licensed under the Apache License 2.0.

---

## 日本語

BocchiDB への関心をお寄せいただき、ありがとうございます。Issue や Pull Request を歓迎します。

### はじめる前に

- 不具合の報告には、再現手順を書いてください。同期に関係する場合は CouchDB のバージョンも書いてください。
- 大きな変更や新機能は、設計を相談するため、先に Issue を作ってください。

### 開発環境

- Xcode 16 以降（Swift 6）、macOS 14 以降
- 互換性テストには Docker または Podman と、Node.js が必要です

コマンドは英語版の「Development setup」と同じです。

### 方針

- **テストを先に書いてください。** すべての変更にテストが必要です。同期の動作を変える場合は、CouchDB に対する互換性テスト
  （`Tests/BocchiDBTests/InteropTests.swift`）を追加してください。必要に応じて、PouchDB を別の端末として使えます
  （`interop/pouch-device.mjs`）。
- **外部依存を増やさないでください。** ライブラリが使うのは Foundation・SQLite3・CryptoKit だけです。依存を追加したい場合は先に相談してください。
- **CouchDB に合わせてください。** 動作に迷ったら、[CouchDB のドキュメント](https://docs.couchdb.org/)と、実際の CouchDB 3.x の動作を基準にします。
- **変更は目的を絞ってください。** 関係のないリファクタリングや書式の変更は、同じ Pull Request に混ぜないでください。

### ほかのプロジェクトのコードの扱い

- 仕様は CouchDB のドキュメント（レプリケーションプロトコル、HTTP API）を正とします。
- 動作を確かめるために PouchDB や CouchDB のソースコードを読むことは問題ありません。
- PouchDB や CouchDB（どちらも Apache-2.0）からコードを移植した場合は、そのファイルに出典を書き、同じ Pull Request で `NOTICE` に表示を追加してください。
- Apache-2.0 と両立しないライセンスのコードは追加しないでください。

### ライセンス

貢献したコードは Apache License 2.0 で提供されることに同意したものとみなします。
