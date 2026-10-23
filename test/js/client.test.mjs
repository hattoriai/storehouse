// The upload client, with the app and the store played by the test.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createUploadQueue, checksum } from "../../priv/static/storehouse-client.mjs";

const file = (name, body, type = "image/jpeg") => new File([body], name, { type });

// An app that signs every file but those named "refused…", knows the file
// "kept", and registers each as {photo: key}; a store that takes every PUT.
function world({ putFails = 0, existingSum = null, register } = {}) {
  const calls = { presign: [], register: [], put: [] };
  let failures = putFails;

  const fetch = async (url, body) => {
    if (url === "/presign") {
      calls.presign.push(body.uploads);
      return {
        uploads: body.uploads.map((item) => {
          if (item.name.startsWith("refused")) return { error: "not_accepted" };
          if (existingSum && item.checksum === existingSum) return { existing: { key: "kept" } };
          return { upload: { key: `k/${item.name}`, method: "PUT", url: `https://store/${item.name}`, headers: { "content-type": item.type } } };
        }),
      };
    }
    calls.register.push(body.uploads);
    if (register) return register(body);
    return { uploads: body.uploads.map((item) => ({ photo: item.key })) };
  };

  const put = async (signed, blob, onProgress) => {
    calls.put.push(signed.key);
    if (failures-- > 0) throw Object.assign(new Error("network"), { status: 0 });
    onProgress(0.5);
    onProgress(1);
  };

  return { calls, fetch, put };
}

const queueOf = (w, opts = {}) =>
  createUploadQueue({ presignUrl: "/presign", registerUrl: "/register", fetch: w.fetch, put: w.put, registerMaxWaitMs: 5, ...opts });

test("presigns the files added together, sends them, and registers them in a batch", async () => {
  const w = world();
  const queue = queueOf(w);
  const uploads = queue.add([file("a.jpg", "aaa"), file("b.jpg", "bbbb")]);

  const results = await Promise.all(uploads.map((u) => u.result));
  assert.deepEqual(results, [
    { status: "registered", value: { photo: "k/a.jpg" } },
    { status: "registered", value: { photo: "k/b.jpg" } },
  ]);

  assert.equal(w.calls.presign.length, 1);
  // In the order their hashes are done, which is not the order added.
  const byName = (a, b) => (a.name < b.name ? -1 : 1);
  assert.deepEqual([...w.calls.presign[0]].sort(byName).map((i) => [i.name, i.type, i.bytes]), [["a.jpg", "image/jpeg", 3], ["b.jpg", "image/jpeg", 4]]);
  assert.match(w.calls.presign[0][0].checksum, /^[0-9a-f]{64}$/);
  assert.equal(w.calls.register.length, 1);
  assert.deepEqual([...w.calls.register[0]].sort(byName), [{ key: "k/a.jpg", name: "a.jpg" }, { key: "k/b.jpg", name: "b.jpg" }]);
  assert.equal(uploads[0].fraction, 1);
});

test("a file refused, and a file the app has, are never sent", async () => {
  const known = await checksum(file("x", "kept bytes"));
  const w = world({ existingSum: known });
  const queue = queueOf(w);
  const errors = [];
  queue.on("error", (_upload, code) => errors.push(code));

  const [refused, kept] = queue.add([file("refused.exe", "x"), file("again.jpg", "kept bytes")]);

  assert.deepEqual(await refused.result, { status: "error", error: "not_accepted" });
  assert.deepEqual(await kept.result, { status: "existing", value: { key: "kept" } });
  assert.deepEqual(w.calls.put, []);
  assert.deepEqual(errors, ["not_accepted"]);
});

test("no more uploads at once than :concurrency", async () => {
  let running = 0, most = 0;
  const w = world();
  const put = async () => {
    running++;
    most = Math.max(most, running);
    await new Promise((r) => setTimeout(r, 5));
    running--;
  };
  const queue = createUploadQueue({ presignUrl: "/presign", registerUrl: "/register", fetch: w.fetch, put, concurrency: 2, registerMaxWaitMs: 1 });
  const uploads = queue.add(Array.from({ length: 6 }, (_, i) => file(`${i}.jpg`, `${i}`)));
  await Promise.all(uploads.map((u) => u.result));
  assert.equal(most, 2);
});

test("registers as soon as :registerBatchSize are done", async () => {
  const w = world();
  const queue = queueOf(w, { registerBatchSize: 2, registerMaxWaitMs: 10_000 });
  const uploads = queue.add([file("a.jpg", "a"), file("b.jpg", "b"), file("c.jpg", "c"), file("d.jpg", "d")]);
  await Promise.all(uploads.map((u) => u.result));
  assert.deepEqual(w.calls.register.map((b) => b.length), [2, 2]);
});

test("a network error or the store's 5xx is tried again, then given up after :retries", async () => {
  const w = world();
  let failures = 1;
  const flaky = async () => {
    if (failures-- > 0) throw Object.assign(new Error("network"), { status: 0 });
  };
  const queue = createUploadQueue({ presignUrl: "/presign", registerUrl: "/register", fetch: w.fetch, put: flaky, registerMaxWaitMs: 1 });
  assert.deepEqual(await queue.add(file("a.jpg", "a")).result, { status: "registered", value: { photo: "k/a.jpg" } });

  let tries = 0;
  const down = async () => {
    tries++;
    throw Object.assign(new Error("unavailable"), { status: 503 });
  };
  const giving = createUploadQueue({ presignUrl: "/presign", registerUrl: "/register", fetch: w.fetch, put: down, retries: 1 });
  assert.deepEqual(await giving.add(file("b.jpg", "b")).result, { status: "error", error: "upload_failed" });
  assert.equal(tries, 2);

  // A 403 (an upload refused by the store) is not tried again.
  tries = 0;
  const refusing = createUploadQueue({ presignUrl: "/presign", registerUrl: "/register", fetch: w.fetch, put: async () => { tries++; throw Object.assign(new Error("no"), { status: 403 }); } });
  assert.deepEqual(await refusing.add(file("c.jpg", "c")).result, { status: "error", error: "upload_failed" });
  assert.equal(tries, 1);
});

test("the app's own error for a file at register, and for a whole batch", async () => {
  const w = world({ register: (body) => ({ uploads: body.uploads.map(() => ({ error: "not_owner" })) }) });
  assert.deepEqual(await queueOf(w).add(file("a.jpg", "a")).result, { status: "error", error: "not_owner" });

  const failing = world();
  const fetch = async (url, body) => {
    if (url === "/presign") return failing.fetch(url, body);
    throw Object.assign(new Error("too many"), { code: "too_many" });
  };
  const queue = createUploadQueue({ presignUrl: "/presign", registerUrl: "/register", fetch, put: failing.put, registerMaxWaitMs: 1 });
  assert.deepEqual(await queue.add(file("a.jpg", "a")).result, { status: "error", error: "too_many" });
});

test("cancelled before it is sent: nothing sent, nothing registered", async () => {
  const w = world();
  const queue = queueOf(w);
  const upload = queue.add(file("a.jpg", "a"));
  upload.cancel();
  assert.deepEqual(await upload.result, { status: "cancelled" });
  await new Promise((r) => setTimeout(r, 20));
  assert.deepEqual(w.calls.put, []);
  assert.deepEqual(w.calls.register, []);
});

test("progress is reported, and 1 only once the store has the file", async () => {
  const w = world();
  const seen = [];
  const upload = queueOf(w).add(file("a.jpg", "a"));
  upload.onProgress((f) => seen.push(f));
  await upload.result;
  assert.deepEqual(seen, [0.5, 0.99, 1]);
});

test("checksum is the file's SHA-256, in hex", async () => {
  assert.equal(await checksum(file("e", "")), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
});

// An app of Storehouse.Plug.Multipart, and a store whose parts it keeps;
// a storage that outlives the queue, as localStorage outlives a reload.
function multipartWorld({ partFails = {}, existing = false } = {}) {
  const calls = { start: 0, sign: [], list: 0, complete: [], abort: 0 };
  const stored = new Map();
  const failures = { ...partFails };

  const fetch = async (url, body) => {
    const action = url.split("/").pop();
    if (action === "start") {
      calls.start++;
      if (existing) return { existing: { key: "kept" } };
      return { upload: { key: `k/${body.name}`, upload_id: "u1", part_bytes: 4, parts: Math.ceil(body.bytes / 4) } };
    }
    if (action === "list") {
      calls.list++;
      return { parts: [...stored.entries()].map(([number, bytes]) => ({ number, bytes, checksum: null })) };
    }
    if (action === "sign") {
      calls.sign.push(body.parts[0]);
      return { parts: body.parts.map((p) => ({ number: p.number, method: "PUT", url: `https://store/part/${p.number}`, headers: {} })) };
    }
    if (action === "complete") {
      calls.complete.push(body);
      return { file: { key: body.key, bytes: body.bytes } };
    }
    if (action === "abort") {
      calls.abort++;
      return { ok: true };
    }
  };

  const put = async (signed, blob, onProgress) => {
    const n = Number(signed.url.split("/").pop());
    if (failures[n]-- > 0) throw Object.assign(new Error("network"), { status: failures.status ?? 0 });
    onProgress(1);
    stored.set(n, blob.size);
  };

  return { calls, stored, fetch, put };
}

function memoryStorage() {
  const items = new Map();
  return { items, getItem: (k) => items.get(k) ?? null, setItem: (k, v) => items.set(k, v), removeItem: (k) => items.delete(k) };
}

const multipartQueue = (w, storage, opts = {}) =>
  createUploadQueue({
    presignUrl: "/presign",
    registerUrl: "/register",
    multipartUrl: "/multipart/",
    multipartThreshold: 8,
    fetch: w.fetch,
    put: w.put,
    storage,
    ...opts,
  });

test("a large file in parts, each with its checksum, then completed", async () => {
  const w = multipartWorld();
  const storage = memoryStorage();
  const upload = multipartQueue(w, storage).add(file("film.mov", "0123456789", "video/quicktime"));

  assert.deepEqual(await upload.result, { status: "registered", value: { file: { key: "k/film.mov", bytes: 10 } } });
  assert.equal(w.calls.start, 1);
  assert.deepEqual([...w.stored.entries()].sort(), [[1, 4], [2, 4], [3, 2]]);
  assert.deepEqual(w.calls.sign.map((p) => p.number).sort(), [1, 2, 3]);
  for (const part of w.calls.sign) assert.match(part.checksum, /^[A-Za-z0-9+/]{43}=$/);
  assert.deepEqual(w.calls.complete, [{ key: "k/film.mov", upload_id: "u1", bytes: 10, name: "film.mov" }]);
  assert.equal(storage.items.size, 0);
  assert.equal(upload.fraction, 1);
});

test("a part that fails is tried again on its own", async () => {
  const w = multipartWorld({ partFails: { 2: 2 } });
  const upload = multipartQueue(w, memoryStorage()).add(file("film.mov", "0123456789", "video/quicktime"));

  assert.equal((await upload.result).status, "registered");
  assert.equal(w.calls.sign.filter((p) => p.number === 2).length, 3);
  assert.equal(w.calls.sign.filter((p) => p.number === 1).length, 1);
});

test("after a reload, the same file goes on from the parts the store has", async () => {
  const w = multipartWorld({ partFails: { 3: 99, status: 400 } });
  const storage = memoryStorage();
  const bytes = "0123456789";

  // The first page: parts 1 and 2 sent, part 3 refused, the upload remembered.
  // The same file from the disk twice: the same name, size and time.
  const film = () => new File([bytes], "film.mov", { type: "video/quicktime", lastModified: 1_790_000_000_000 });
  const first = multipartQueue(w, storage).add(film());
  assert.equal((await first.result).status, "error");
  assert.equal(storage.items.size, 1);

  // Reloaded: added again, only part 3 is sent.
  const again = multipartWorld();
  again.stored.set(1, 4).set(2, 4);
  const second = multipartQueue(again, storage).add(film());

  assert.equal((await second.result).status, "registered");
  assert.equal(again.calls.start, 0);
  assert.equal(again.calls.list, 1);
  assert.deepEqual(again.calls.sign.map((p) => p.number), [3]);
  assert.equal(storage.items.size, 0);
});

test("a large file the app has is not sent; a small one goes whole", async () => {
  const w = multipartWorld({ existing: true });
  const upload = multipartQueue(w, memoryStorage()).add(file("film.mov", "0123456789", "video/quicktime"));
  assert.deepEqual(await upload.result, { status: "existing", value: { key: "kept" } });
  assert.equal(w.calls.sign.length, 0);

  const small = world();
  const queue = multipartQueue({ ...small, fetch: small.fetch, put: small.put }, memoryStorage(), { registerMaxWaitMs: 5 });
  assert.equal((await queue.add(file("a.jpg", "abc")).result).status, "registered");
  assert.equal(small.calls.presign.length, 1);
});
