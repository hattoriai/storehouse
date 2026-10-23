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
  assert.deepEqual(w.calls.presign[0].map((i) => [i.name, i.type, i.bytes]), [["a.jpg", "image/jpeg", 3], ["b.jpg", "image/jpeg", 4]]);
  assert.match(w.calls.presign[0][0].checksum, /^[0-9a-f]{64}$/);
  assert.equal(w.calls.register.length, 1);
  assert.deepEqual(w.calls.register[0], [{ key: "k/a.jpg", name: "a.jpg" }, { key: "k/b.jpg", name: "b.jpg" }]);
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
