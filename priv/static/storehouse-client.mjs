// Storehouse's upload client, for a frontend that is not a LiveView (React,
// Vue, Svelte, plain JavaScript): files sent straight to the store, around
// the app's Storehouse.Plug.Presign and Storehouse.Plug.Register (see the
// guide "Uploads from any client"). No dependencies.
//
//     import {createUploadQueue} from "storehouse/client"  // "@hattoriai/storehouse/client" from npm
//
//     const queue = createUploadQueue({
//       presignUrl: "/files/presign",
//       registerUrl: "/files/register",
//       headers: {"x-csrf-token": csrfToken},
//     })
//
//     for (const upload of queue.add(input.files)) {
//       upload.onProgress((fraction) => bar.style.width = `${fraction * 100}%`)
//       upload.result.then(({status, value}) => ...)
//     }
//
// Each file is read for its SHA-256 (in a Web Worker), presigned with the
// others added at the same time, sent to the store (a few at once, each
// tried again on a network error), then registered with the others that
// finish about then. A file the app has already is not sent: its result is
// "existing".
//
// With multipartUrl (Storehouse.Plug.Multipart), a file of multipartThreshold
// or more goes in parts, a few at a time, each with its checksum and each
// tried again on its own, then is put together and checked by the app.
// Its upload is remembered (localStorage): after a reload, the same file
// added again goes on from the parts the store has.

const DEFAULTS = {
  concurrency: 4,
  presignBatchSize: 50,
  registerBatchSize: 10,
  registerMaxWaitMs: 400,
  retries: 2,
  checksum: true,
  checksumMaxBytes: 512 * 1024 * 1024,
  multipartThreshold: 100 * 1024 * 1024,
  partConcurrency: 4,
  partRetries: 3,
};

/**
 * The SHA-256 of a file, in hex, read off the main thread in a Web Worker
 * where there is one; null where the browser cannot (no crypto.subtle, an
 * insecure origin).
 * @param {Blob} file
 * @returns {Promise<string | null>}
 */
export async function checksum(file) {
  if (!globalThis.crypto?.subtle) return null;
  try {
    const worker = digestWorker();
    if (worker) return await worker(file);
    return hex(await crypto.subtle.digest("SHA-256", await file.arrayBuffer()));
  } catch {
    return null;
  }
}

function hex(buffer) {
  return Array.from(new Uint8Array(buffer), (b) => b.toString(16).padStart(2, "0")).join("");
}

// One worker for every file, made from a Blob: nothing to serve beside this.
let digest = undefined;

function digestWorker() {
  if (digest !== undefined) return digest;
  digest = null;
  if (typeof Worker === "undefined" || typeof Blob === "undefined" || !globalThis.URL?.createObjectURL) return digest;

  const source = `onmessage = async ({data: {id, file}}) => {
    try {
      const sum = await crypto.subtle.digest("SHA-256", await file.arrayBuffer())
      postMessage({id, hex: Array.from(new Uint8Array(sum), b => b.toString(16).padStart(2, "0")).join("")})
    } catch (error) { postMessage({id, hex: null}) }
  }`;

  try {
    const worker = new Worker(URL.createObjectURL(new Blob([source], { type: "text/javascript" })));
    const waiting = new Map();
    let next = 0;
    worker.onmessage = ({ data }) => {
      waiting.get(data.id)?.(data.hex);
      waiting.delete(data.id);
    };
    digest = (file) =>
      new Promise((resolve) => {
        const id = next++;
        waiting.set(id, resolve);
        worker.postMessage({ id, file });
      });
  } catch {
    digest = null;
  }
  return digest;
}

/**
 * An image's width and height, as the browser draws it; null for a file
 * that is not one it can read.
 * @param {Blob} file
 * @returns {Promise<{width: number, height: number} | null>}
 */
export async function dimensions(file) {
  if (typeof createImageBitmap !== "function" || !file.type?.startsWith("image/")) return null;
  try {
    const bitmap = await createImageBitmap(file);
    const size = { width: bitmap.width, height: bitmap.height };
    bitmap.close?.();
    return size;
  } catch {
    return null;
  }
}

// The browser's part of an upload: the file, with the method and headers
// signed, reporting how much is sent.
function xhrPut({ method, url, headers }, file, onProgress, signal) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open(method, url, true);
    for (const [name, value] of Object.entries(headers || {})) xhr.setRequestHeader(name, value);
    xhr.upload.onprogress = (event) => event.lengthComputable && onProgress(event.loaded / event.total);
    xhr.onload = () => (xhr.status >= 200 && xhr.status < 300 ? resolve() : reject(new StoreError(xhr.status)));
    xhr.onerror = () => reject(new StoreError(0));
    signal.addEventListener("abort", () => xhr.abort());
    xhr.onabort = () => reject(new CancelledError());
    xhr.send(file);
  });
}

class StoreError extends Error {
  constructor(status) {
    super(`the store answered ${status || "nothing"}`);
    this.status = status;
  }
}

class CancelledError extends Error {
  constructor() {
    super("cancelled");
  }
}

/**
 * A queue of uploads: see the top of this file.
 * @param {import("./storehouse-client.mjs").QueueOptions} options
 * @returns {import("./storehouse-client.mjs").UploadQueue}
 */
export function createUploadQueue(options) {
  const opts = { ...DEFAULTS, ...options };
  const fetchJson = opts.fetch || defaultFetch(opts);
  const put = opts.put || xhrPut;
  const listeners = new Map();

  const emit = (event, ...args) => (listeners.get(event) || []).forEach((fn) => fn(...args));

  let toPresign = [];
  let presignTimer = null;
  let toRegister = [];
  let registerTimer = null;
  const waiting = [];
  let sending = 0;

  function add(files) {
    const list = files instanceof Blob ? [files] : Array.from(files);
    const uploads = list.map(newUpload);
    for (const upload of uploads) prepare(upload);
    return files instanceof Blob ? uploads[0] : uploads;
  }

  function newUpload(file) {
    const progress = [];
    let settle;
    const controller = new AbortController();
    const upload = {
      file,
      status: "pending",
      key: null,
      fraction: 0,
      result: new Promise((resolve) => (settle = resolve)),
      onProgress: (fn) => progress.push(fn),
      cancel: () => {
        if (upload.done) return;
        controller.abort();
        finish(upload, { status: "cancelled" });
        // A large file's parts are given up, and it is forgotten.
        if (upload.abortParts) {
          upload.abortParts();
          forget(opts.storage === undefined ? globalThis.localStorage : opts.storage, `storehouse:${file.name}:${file.size}:${file.lastModified ?? ""}`);
        }
      },
    };
    upload.signal = controller.signal;
    upload.setProgress = (fraction) => {
      upload.fraction = fraction;
      progress.forEach((fn) => fn(fraction));
      emit("progress", upload, fraction);
    };
    upload.settle = settle;
    return upload;
  }

  function finish(upload, result) {
    if (upload.done) return;
    upload.done = true;
    upload.status = result.status;
    upload.settle(result);
    emit(result.status, upload, result.value ?? result.error);
  }

  async function prepare(upload) {
    const sum = opts.checksum && upload.file.size <= opts.checksumMaxBytes ? await checksum(upload.file) : null;
    if (upload.done) return;
    upload.checksum = sum;
    if (opts.multipartUrl && upload.file.size >= opts.multipartThreshold) {
      upload.multipart = true;
      waiting.push(upload);
      return sendNext();
    }
    toPresign.push(upload);
    if (toPresign.length >= opts.presignBatchSize) presignNow();
    else presignTimer ??= setTimeout(presignNow, 0);
  }

  async function presignNow() {
    clearTimeout(presignTimer);
    presignTimer = null;
    const batch = toPresign.splice(0, opts.presignBatchSize).filter((u) => !u.done);
    if (toPresign.length) presignTimer = setTimeout(presignNow, 0);
    if (!batch.length) return;

    const items = batch.map(({ file, checksum: sum }) => {
      const item = { name: file.name || "file", type: file.type || null, bytes: file.size };
      return sum ? { ...item, checksum: sum } : item;
    });

    let results;
    try {
      results = (await fetchJson(opts.presignUrl, { uploads: items })).uploads;
    } catch (error) {
      for (const upload of batch) finish(upload, { status: "error", error: error.code || "upload_failed" });
      return;
    }

    batch.forEach((upload, i) => {
      const result = results[i] || { error: "upload_failed" };
      if (result.upload) {
        upload.key = result.upload.key;
        upload.signed = result.upload;
        waiting.push(upload);
        sendNext();
      } else if (result.existing) {
        upload.setProgress(1);
        finish(upload, { status: "existing", value: result.existing });
      } else {
        finish(upload, { status: "error", error: result.error || "upload_failed" });
      }
    });
  }

  function sendNext() {
    while (sending < opts.concurrency && waiting.length) {
      const upload = waiting.shift();
      if (upload.done) continue;
      sending++;
      send(upload).finally(() => {
        sending--;
        sendNext();
      });
    }
  }

  async function send(upload, attempt = 0) {
    if (upload.multipart) return sendParts(upload);
    upload.status = "uploading";
    try {
      await put(upload.signed, upload.file, (fraction) => upload.setProgress(Math.min(fraction, 0.99)), upload.signal);
    } catch (error) {
      if (upload.done) return;
      // A network error, or the store's own (5xx): again, after a while.
      const again = typeof error?.status === "number" && (error.status === 0 || error.status >= 500);
      if (again && attempt < opts.retries) {
        await sleep(500 * 2 ** attempt);
        return send(upload, attempt + 1);
      }
      return finish(upload, { status: "error", error: "upload_failed" });
    }
    if (upload.done) return;
    upload.status = "uploaded";
    upload.setProgress(1);
    emit("uploaded", upload);
    toRegister.push(upload);
    if (toRegister.length >= opts.registerBatchSize) registerNow();
    else registerTimer ??= setTimeout(registerNow, opts.registerMaxWaitMs);
  }

  async function registerNow() {
    clearTimeout(registerTimer);
    registerTimer = null;
    const batch = toRegister.splice(0, opts.registerBatchSize).filter((u) => !u.done);
    if (toRegister.length) registerTimer = setTimeout(registerNow, opts.registerMaxWaitMs);
    if (!batch.length) return;

    let results;
    try {
      const items = batch.map((u) => ({ key: u.key, name: u.file.name || "file" }));
      results = (await fetchJson(opts.registerUrl, { uploads: items })).uploads;
    } catch (error) {
      for (const upload of batch) finish(upload, { status: "error", error: error.code || "upload_failed" });
      return;
    }

    batch.forEach((upload, i) => {
      const value = results[i];
      if (value && typeof value === "object" && "error" in value && Object.keys(value).length === 1)
        finish(upload, { status: "error", error: value.error });
      else if (value && typeof value === "object" && "existing" in value)
        finish(upload, { status: "existing", value: value.existing });
      else finish(upload, { status: "registered", value });
    });
  }

  // A large file in parts: started (or found again, after a reload), its
  // parts the store lacks sent a few at a time, then completed.
  async function sendParts(upload) {
    const { file } = upload;
    const url = (action) => `${opts.multipartUrl.replace(/\/$/, "")}/${action}`;
    const storage = opts.storage === undefined ? globalThis.localStorage : opts.storage;
    const remembered = `storehouse:${file.name}:${file.size}:${file.lastModified ?? ""}`;
    upload.status = "uploading";

    try {
      let started = recall(storage, remembered);
      let have = [];

      if (started) {
        try {
          have = (await fetchJson(url("list"), { key: started.key, upload_id: started.upload_id })).parts;
        } catch {
          started = null;
        }
      }

      if (!started) {
        const item = { name: file.name || "file", type: file.type || null, bytes: file.size };
        const answer = await fetchJson(url("start"), upload.checksum ? { ...item, checksum: upload.checksum } : item);
        if (answer.existing) {
          upload.setProgress(1);
          return finish(upload, { status: "existing", value: answer.existing });
        }
        started = answer.upload;
        remember(storage, remembered, started);
      }

      upload.key = started.key;
      upload.uploadId = started.upload_id;
      upload.abortParts = () => fetchJson(url("abort"), { key: started.key, upload_id: started.upload_id }).catch(() => {});

      const size = started.part_bytes;
      const count = Math.max(Math.ceil(file.size / size), 1);
      const done = new Set(have.map((part) => part.number));
      const sent = new Map(have.map((part) => [part.number, part.bytes]));
      const progress = () => upload.setProgress(Math.min([...sent.values()].reduce((a, b) => a + b, 0) / file.size, 0.99));
      progress();

      const todo = [];
      for (let n = 1; n <= count; n++) if (!done.has(n)) todo.push(n);

      const sendPart = async (n) => {
        const part = file.slice((n - 1) * size, Math.min(n * size, file.size));
        const sum = await partChecksum(part);
        for (let attempt = 0; ; attempt++) {
          if (upload.done) return;
          try {
            const [signed] = (await fetchJson(url("sign"), { key: started.key, upload_id: started.upload_id, parts: [sum ? { number: n, checksum: sum } : { number: n }] })).parts;
            await put(signed, part, (fraction) => {
              sent.set(n, part.size * fraction);
              progress();
            }, upload.signal);
            sent.set(n, part.size);
            progress();
            return;
          } catch (error) {
            if (upload.done) return;
            const again = error?.status === 0 || error?.status >= 500 || error?.code === "upload_failed";
            if (!again || attempt >= opts.partRetries) throw error;
            await sleep(500 * 2 ** attempt);
          }
        }
      };

      const workers = Array.from({ length: Math.min(opts.partConcurrency, todo.length) }, async () => {
        while (todo.length && !upload.done) await sendPart(todo.shift());
      });
      await Promise.all(workers);
      if (upload.done) return;

      const answer = await fetchJson(url("complete"), { key: started.key, upload_id: started.upload_id, bytes: file.size, name: file.name || "file" });
      forget(storage, remembered);
      upload.setProgress(1);
      if (answer.existing) finish(upload, { status: "existing", value: answer.existing });
      else finish(upload, { status: "registered", value: answer });
    } catch (error) {
      // Remembered still: added again, it goes on from where it stopped.
      finish(upload, { status: "error", error: error?.code || "upload_failed" });
    }
  }

  return {
    add,
    on(event, fn) {
      listeners.set(event, [...(listeners.get(event) || []), fn]);
      return () => listeners.set(event, (listeners.get(event) || []).filter((f) => f !== fn));
    },
  };
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// A part's SHA-256, in Base64, as the store checks it; null where the
// browser cannot.
async function partChecksum(blob) {
  if (!globalThis.crypto?.subtle) return null;
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", await blob.arrayBuffer()));
  return btoa(String.fromCharCode(...digest));
}

// Uploads remembered across reloads, where the browser keeps them.
function recall(storage, name) {
  try {
    const saved = storage?.getItem(name);
    return saved ? JSON.parse(saved) : null;
  } catch {
    return null;
  }
}

function remember(storage, name, started) {
  try {
    storage?.setItem(name, JSON.stringify({ key: started.key, upload_id: started.upload_id, part_bytes: started.part_bytes }));
  } catch {}
}

function forget(storage, name) {
  try {
    storage?.removeItem(name);
  } catch {}
}

// JSON to the app, with its headers (a CSRF token); an error code from its
// answer when it refuses the whole batch.
function defaultFetch(opts) {
  return async (url, body) => {
    const response = await fetch(url, {
      method: "POST",
      credentials: "same-origin",
      headers: { "content-type": "application/json", accept: "application/json", ...(opts.headers || {}) },
      body: JSON.stringify(body),
    });
    const data = await response.json().catch(() => ({}));
    if (!response.ok) throw Object.assign(new Error(data.error || `the app answered ${response.status}`), { code: data.error || "upload_failed" });
    return data;
  };
}
