// The client against a running app (test/storehouse/client_multipart_test.exs):
// a file of 12 MiB sent in parts straight to the bucket, put together and
// checked, and what came of it printed as JSON.
import { createUploadQueue } from "../../priv/static/storehouse-client.mjs";

const [base] = process.argv.slice(2);
const absolute = (url) => new URL(url, base).toString();

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

// A ZIP's first bytes, then a pattern: the test checks what the bucket has.
const bytes = new Uint8Array(12 * 1024 * 1024);
bytes.set([0x50, 0x4b, 0x03, 0x04]);
for (let i = 4; i < bytes.length; i++) bytes[i] = i % 251;

const queue = createUploadQueue({
  presignUrl: "/files/presign",
  registerUrl: "/files/register",
  multipartUrl: "/files/multipart",
  multipartThreshold: 1024 * 1024,
  storage: null,
  fetch: fetchJson,
  put,
});

const result = await queue.add(new File([bytes], "export.zip", { type: "application/zip" })).result;
console.log(JSON.stringify(result));
