// 互換性テスト環境の動作確認。
// PouchDB の 2 端末（A / B）でオフライン中に同じ文書を更新し、CouchDB に同期して競合が記録されることを確かめる。
// BocchiDB の互換性テストでは、端末の片方を BocchiDB に置き換えて同じ結果になることを検証する。
import PouchDB from 'pouchdb-core';
import memory from 'pouchdb-adapter-memory';
import http from 'pouchdb-adapter-http';
import replication from 'pouchdb-replication';

PouchDB.plugin(memory).plugin(http).plugin(replication);

const base = process.env.BOCCHIDB_COUCHDB_URL ?? 'http://admin:password@localhost:45984';
const remoteURL = `${base}/bocchidb_interop_check`;

// 単一ノード用のシステム DB を作成（作成済みなら 412 が返るので無視）
for (const name of ['_users', '_replicator']) {
  await new PouchDB(`${base}/${name}`).info();
}

const remote = new PouchDB(remoteURL);
await remote.destroy().catch(() => {});
const couch = new PouchDB(remoteURL);

const a = new PouchDB('device-a', { adapter: 'memory' });
const b = new PouchDB('device-b', { adapter: 'memory' });

// A が作成 → CouchDB → B に配布
await a.put({ _id: 'inspection-001', temperature: 25.5 });
await a.replicate.to(couch);
await b.replicate.from(couch);

// オフライン中にそれぞれ更新
const docA = await a.get('inspection-001');
await a.put({ ...docA, temperature: 26.0 });
const docB = await b.get('inspection-001');
await b.put({ ...docB, temperature: 27.0 });

// 両方を同期
await a.replicate.to(couch);
await b.replicate.to(couch);

const result = await couch.get('inspection-001', { conflicts: true });
console.log(JSON.stringify(result, null, 2));

if (!result._conflicts || result._conflicts.length !== 1) {
  console.error('NG: 競合が 1 件記録されていません');
  process.exit(1);
}
console.log(`OK: 勝者 ${result._rev} / 競合 ${result._conflicts.join(', ')}`);
