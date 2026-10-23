# Features

Everything Storehouse does, in one table. Each guide tells more.

| | |
| --- | --- |
| Checking | the type from the file's bytes, not its name: PNG, JPEG, GIF and WebP (with width and height, a phone photo turned as its EXIF says), HEIC, HEIF, AVIF, TIFF, DNG (as a download), PDF, MP4, WebM, ZIP, Office documents and plain text; anything else (HTML, SVG, JavaScript, a page renamed `.png`) is `application/octet-stream` or refused; limits on bytes, pixels and types → [Serving](serving.md) |
| Keys | `yyyy/mm/<uuid>-<safe name><extension>`, the extension from the checked type, so a key never ends in `.html`; a key that could leave the store's root refused; keys under an owner's prefix (an account, a workspace), a key a browser sends back checked to be its → [Stores](stores.md#keys) |
| Stores | the local disk; S3 and the stores that speak its API (Cloudflare R2, MinIO, Tigris, LocalStack), with no other library; your own in three callbacks; named stores (`use Storehouse.S3`), a store per Ecto field → [Stores](stores.md) |
| Moving stores | files copied between stores, in the store itself where it can, run again to copy only what is missing (`mix storehouse.copy`); a mirror that writes to a second store too → [Stores](stores.md#moving-to-another-store) |
| Serving | `Storehouse.Local.Plug`: the checked type, `nosniff`, a sandboxing CSP, a download for every type a browser should not show, byte ranges for video → [Serving](serving.md) |
| A CDN in front | a year's `Cache-Control` on every stored file; purged when deleted, with its variants, by URL, tag or prefix (`Storehouse.Purge`, Cloudflare built in) → [Serving](serving.md#a-cdn-in-front) |
| Private files | signed URLs that expire, from S3 or the local plug; `Storehouse.Redirect`, a lasting URL that checks the person and redirects to a fresh one; `Storehouse.Proxy`, the file streamed through the app with ranges and `304`s → [Private files](private_files.md) |
| Direct uploads | from the browser to the bucket at a URL your app signed (type, size, ten minutes), checked there by the first bytes; in development, to your app's own plug the same way → [Direct uploads](direct_uploads.md) |
| Streamed uploads | through the app with no file on its disk, to S3 in multipart parts as the chunks come, checked on the way, held back when the bucket is slower than the browser → [Direct uploads](direct_uploads.md#streamed-through-the-app-mode-stream) |
| Very large files | in parts, straight to the bucket, a few at a time, each checked by its checksum and retried on its own, resumed after a reload → [Direct uploads](direct_uploads.md#very-large-files-in-parts) |
| tus | resumable uploads through the app for the clients that speak tus (Uppy, tus-js-client, mobile), into the bucket a part at a time → [Uploads from any client](any_client.md#tus-through-the-app) |
| Any client | JSON endpoints that presign and register files in batches; `storehouse/client` (also on npm, as `@hattoriai/storehouse`): checksums in a Web Worker, a few uploads at once, progress → [Uploads from any client](any_client.md) |
| LiveView | `Storehouse.Live.consume/3` stores each finished entry once, cancels the refused ones, and gives a result for each → [LiveView](liveview.md) |
| Ecto | a file in a column (`Storehouse.Ecto.File`), no table; temporary until the record is saved, then permanent; replaced and removed files deleted once the database has the change; metadata of your own (a caption, a credit) → [Ecto](ecto.md) |
| A library of files | optional: one row per file, which records use it, a file in use never deleted → [Ecto](ecto.md#a-library-of-files) |
| The same file again | found by its checksum before the upload, or when it is verified, and the one you have is returned → [Stores](stores.md#the-same-file-again) |
| From a URL | only from the hosts you allow, redirects checked, stopped at the size limit → [Stores](stores.md#files-from-an-address) |
| Reading back | size and type without reading, the bytes, a stream, or a path, each refused past a size limit → [Stores](stores.md#reading-files-back) |
| Archives | zips (compressed, AES-256, past 4 GB) or tars of stored files, streamed into the store or a response, split in parts, their size known before they are made → [Stores](stores.md#archives-a-zip-of-files) |
| Expiring files | an export kept for a week, then deleted by a lifecycle rule or the sweeper; its signed links never outlive it → [Stores](stores.md#files-that-expire) |
| Cleanup | files deleted by prefix, deletions retried until the store answers, temporary files of forms never saved swept (`Storehouse.Sweeper`) → [Stores](stores.md#deleted-files) |
| After the upload | steps of your own (EXIF, a PDF's pages) at once or in the background, their results kept in the record; run again over a table's files (`mix storehouse.reprocess`) → [After the upload](analysis.md) |
| Placeholders | a tiny WebP as a data URI, a ThumbHash or a BlurHash, and the average colour, with libvips → [After the upload](analysis.md#a-placeholder-while-a-photograph-loads) |
| Photo metadata | the location removed, a few tags kept, a credit written in, in JPEG, PNG and WebP, without re-encoding → [After the upload](analysis.md#a-step-that-changes-the-file) |
| Variants | thumbnails and `srcset` sizes in WebP, by preset, at URLs that never change; made with libvips once across a cluster, or signed imgproxy URLs, or your own renderer; deleted with their original → [Variants](variants.md) |
| Responsive images | `src`, `srcset`, size and placeholder as JSON or an `<img>` for HEEx, never larger than the original, made before the first visitor → [Variants](variants.md) |
| Background work | on Oban when your app runs it, on a process of your app's without it, or on your own runner → [Work out of the request](background.md) |
| Events | a file stored, analysed or deleted, sent to a function or broadcast on PubSub, on a topic you choose → [LiveView](liveview.md#what-happens-to-files-live) |
| Checksums | each file's SHA-256, kept with it and checked by S3 as it takes the file |
| Previews | a smaller image of a file from a function of yours, kept with it → [Stores](stores.md#previews) |
| Tests | `Storehouse.Memory`, each test's files its own under `async: true`, with assertions (`Storehouse.Test`) and failures on demand → [Stores](stores.md#in-tests) |
| Telemetry | spans for storing, fetching, signing, checking, reading and deleting, with what was refused and why |
