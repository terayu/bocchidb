# 互換性テスト環境

CouchDB 3.x（Docker / Podman）と、基準実装としての PouchDB（Node.js）を使います。
Podman の場合は `docker compose` を `podman compose` に読み替えてください。

```sh
cd interop
docker compose up -d        # CouchDB を http://localhost:45984 で起動（admin / password）
npm install
npm run check               # PouchDB 2 端末で競合を作り、CouchDB に記録されるか確認
```

Swift の互換性テスト（`InteropTests`）は、環境変数を付けて実行します。PouchDB 端末として `pouch-device.mjs` を使うので、先に `npm install` が必要です。

```sh
BOCCHIDB_COUCHDB_URL=http://admin:password@localhost:45984 swift test
```

- 管理画面（Fauxton）: http://localhost:45984/_utils
- 接続先は環境変数 `BOCCHIDB_COUCHDB_URL` で変更できます（既定: `http://admin:password@localhost:45984`）。
- 停止: `docker compose down`
