// PouchDB を「もう 1 台の端末」として動かす。Swift の互換性テストから子プロセスとして呼ばれる。
//
//   node pouch-device.mjs <dbURL> get <docId>
//     CouchDB から同期し、文書の _rev と _conflicts を JSON で出力する。
//   node pouch-device.mjs <dbURL> update <docId> '<json>'
//     CouchDB から同期し、文書に json の内容を上書きして保存し、CouchDB へ同期する。新しい _rev を出力する。
import PouchDB from 'pouchdb-core';
import memory from 'pouchdb-adapter-memory';
import http from 'pouchdb-adapter-http';
import replication from 'pouchdb-replication';

PouchDB.plugin(memory).plugin(http).plugin(replication);

const [dbURL, command, docId, json] = process.argv.slice(2);
const remote = new PouchDB(dbURL);
const device = new PouchDB(`device-${Date.now()}`, { adapter: 'memory' });

await device.replicate.from(remote);

if (command === 'get') {
  const doc = await device.get(docId, { conflicts: true });
  console.log(JSON.stringify({ _rev: doc._rev, _conflicts: doc._conflicts ?? [], doc }));
} else if (command === 'update') {
  const current = await device.get(docId).catch(() => ({ _id: docId }));
  const result = await device.put({ ...current, ...JSON.parse(json) });
  await device.replicate.to(remote);
  console.log(JSON.stringify({ _rev: result.rev }));
} else {
  console.error(`unknown command: ${command}`);
  process.exit(2);
}
