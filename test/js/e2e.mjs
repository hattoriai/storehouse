// The client against a running app (test/storehouse/client_test.exs): its
// files presigned, sent to the app's local store and registered, and what
// came of each printed as JSON.
import { createUploadQueue } from "../../priv/static/storehouse-client.mjs";
import { readFile } from "node:fs/promises";

const [base, fixtures] = process.argv.slice(2);
const absolute = (url) => new URL(url, base).toString();

// Node has no XMLHttpRequest: the browser's PUT, with fetch.
const put = async (signed, file, onProgress) => {
  const response = await fetch(absolute(signed.url), { method: signed.method, headers: signed.headers, body: file });
  if (!response.ok) throw Object.assign(new Error("store"), { status: response.status });
  onProgress(1);
};

const fetchJson = async (url, body) => {
  const response = await fetch(absolute(url), { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
  const data = await response.json();
  if (!response.ok) throw Object.assign(new Error(data.error), { code: data.error });
  return data;
};

const harbour = await readFile(`${fixtures}/harbour.jpg`);
const files = [
  new File([harbour], "harbour.jpg", { type: "image/jpeg" }),
  new File([harbour], "again.jpg", { type: "image/jpeg" }),
  new File(["<script>alert(1)</script>"], "page.html", { type: "text/html" }),
  new File([new Uint8Array(200_000)], "big.png", { type: "image/png" }),
];

const queue = createUploadQueue({ presignUrl: "/files/presign", registerUrl: "/files/register", fetch: fetchJson, put, registerMaxWaitMs: 50 });
const results = await Promise.all(queue.add(files).map((u) => u.result));
console.log(JSON.stringify(results));
