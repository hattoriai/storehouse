# Changelog

All notable changes to Storehouse are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and Storehouse follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- Storehouse takes plug_crypto 2.2.1 or later, for EEF-CVE-2026-105963
  (GHSA-ffw9-w85g-f2vh): with an argument of the wrong type,
  `Plug.Crypto`'s functions could write the secret they were given to the
  logs, in the stack trace. Storehouse's own call
  (`Storehouse.Local.signed?/4`) gives it binaries only, but an app that
  updates Storehouse now gets the fixed plug_crypto too.

### Added

- Resumable uploads by the tus protocol (1.0.0, with creation,
  creation-with-upload, termination and expiration):
  `Storehouse.Tus.Plug`, through the app, into a bucket's multipart
  upload a part at a time (the adapter's `multipart_put/4`), or into a
  file stored when it is whole, checked as every upload is; the uploads
  in progress kept in ETS by `Storehouse.Tus`, which gives up those that
  expired, or in a `Storehouse.Tus.State` of the app's. Tested against
  tuspy, a tus client.

- Very large files sent from the browser straight to the bucket in parts:
  `Storehouse.presign_multipart/4` (checked as `presign_upload/4` is,
  with parts of a size S3 takes), `presign_parts/4` (each part signed
  with its SHA-256), `multipart_parts/3` (what the store has, to go on
  after a reload), `complete_multipart/4` (put together from the store's
  parts, never the browser's word, a missing part or another size
  refused, then checked as `verify_upload/2` checks) and
  `abort_multipart/3`; the adapter callbacks behind them, which
  `Storehouse.S3` has; `Storehouse.Plug.Multipart`, the same as JSON
  endpoints; and the JavaScript client sending large files in parts, a
  few at a time, each tried again, remembered across reloads.
  `Storehouse.Sweeper` gives up multipart uploads never completed.
- A library of files, optional: `Storehouse.Ecto.Migrations` makes a
  table of files (`storehouse_blobs`, or the app's own names) and of
  which records use them; `Storehouse.Ecto.Blob` puts a stored file in
  it (the same file of the same owner one row, `{:existing, blob}`),
  gives it back as a file, and checks ids are an owner's
  (`owned/4`, `validate_owned/5`); `Storehouse.Ecto.Usage` keeps each
  record's set of files (`record/4`, from ids in JSON as much as in
  columns), says what uses a file (`used_by/3`), and refuses to delete
  one in use (`delete/3`, `{:error, {:in_use, records}}`), with the
  database's foreign key behind it. `Storehouse.Ecto.Blob.Schema` for a
  schema of the app's own.
- A CDN in front: `:cache_control` on `Storehouse.S3` (and per call, on
  `store/2` and `presign_upload/4`) keeps a `Cache-Control` with each
  file, however it came in (stored, presigned and signed, streamed,
  copied or promoted); `Storehouse.Local.Plug` takes `:cache_control`
  too. `Storehouse.Purge` tells the CDN to forget a file deleted, its
  variants and the app's routes to it, by URL, `Cache-Tag` or prefix, as
  a job of the runner whose arguments never hold the credentials;
  `Storehouse.Purge.Cloudflare` is one purger. `Storehouse.Proxy` streams
  a file the app authorises through the app, with ranges, `ETag`,
  `Last-Modified` and `304`s. A store's `head` gives `:modified_at`.
- Responsive images: `Storehouse.Responsive.resolve/3`, a photograph's
  `src`, `srcset`, `sizes`, size, placeholder, colour and hashes from a
  preset's ladder (never wider than the original, each width at its
  step), as JSON or as `Storehouse.Components.img/1`; `urls/3`, `warm/3`
  and `warm_later/3`, which make its sizes before the first visitor asks
  (in the app, or over HTTP through imgproxy and a CDN), on the app's
  runner, off unless configured; and `Storehouse.Analyzer.Warm`.
- Variants: `Storehouse.variant_url/3` and `Storehouse.variant/3`, by
  presets only (`Storehouse.Variants`: widths or a ladder of them, a box
  to fit or fill, a crop's focus, formats chosen by `Accept`, quality,
  colour profile, metadata), at URLs that change only when their preset
  does. A renderer (`Storehouse.Renderer`) makes them in the app
  (`Storehouse.Renderer.Vix`, libvips: never enlarged, turned per EXIF,
  without metadata), once across a cluster's nodes, stored under
  `variants/<key>/` and served by `Storehouse.Variants.Plug` for a year;
  or gives URLs of a service (`Storehouse.Renderer.Imgproxy`, signed), or
  is the app's own. Deleting an original deletes its variants.
- Placeholders: `Storehouse.Analyzer.Placeholder`, a step that makes a
  photograph's placeholder while it loads (a tiny WebP, JPEG or PNG as a
  data URI) and its average colour, with libvips through Vix (optional),
  shrinking it as it loads, turned as its EXIF says, in sRGB, with none of
  its metadata. Or as a hash, for a frontend to decode:
  `Storehouse.Analyzer.ThumbHash` and `Storehouse.Analyzer.BlurHash`, of
  `Storehouse.ThumbHash` and `Storehouse.BlurHash`, encoders in plain
  Elixir that give the reference implementations' bytes.
- Archives: `Storehouse.Archive` makes an archive of stored files,
  binaries, the app's functions and streams as a stream (`stream/2`), into
  the store as it is made (`store/3`, S3's multipart upload), or out of
  the request as a job of the app's runner, then the app's function with
  it (`store_later/3`), with nothing on the disk and no more than a chunk
  in memory. Its formats are of `Storehouse.Archive.Format`: zip
  (`Storehouse.Archive.Zip`, the default: deflate where it shrinks,
  AES-256 with a password, ZIP64 past 4 GB or 65,535 files), tar
  (`Storehouse.Archive.Tar`, pax headers, gzipped when it shrinks), or the
  app's. `max_bytes:` splits it in whole archives, `expires_in:` makes it
  expire, and `size/2` gives its size before it is made. Names that could
  leave the folder are refused, and a stored file whose size changed
  stops it.
- Files that expire: `store/2`'s `:expires_in` keeps a file under an
  expiring key (`Storehouse.expiring_key/2`: the prefix
  `Storehouse.expiring_prefix/0`, the days it is kept, when it expires),
  for a bucket's lifecycle rule of that many days; `Storehouse.Sweeper`
  deletes them on stores with none, `Storehouse.expires_at/1` says when,
  and `signed_url/2` never signs past it (`{:error, :expired}` after).
- Reprocessing: `Storehouse.Ecto.reprocess/5` runs analysis steps over
  the files of a field in every record a query gives, a batch at a time
  in the order of the primary key, skipping files that have every step's
  result already (or with `:force`, none), so it can be stopped and run
  again; as jobs of the app's runner, or `now: true` where it is called,
  with `:after` to start after a primary key and `:on_progress`.
  `mix storehouse.reprocess` runs it with its progress.
- Work out of the request, on a runner the app chooses
  (`Storehouse.Runner`): a file's analysis later, deletions later and a
  mirror's copies are jobs (`Storehouse.Job`, a worker and arguments JSON
  holds), kept and retried by the runner. `Storehouse.Runner.Oban` keeps
  them in Oban, through deploys, on the queue and instance of
  `config :storehouse, Storehouse.Runner.Oban`, and is the default when
  the app runs Oban; `Storehouse.Runner.Memory` keeps them in a process of
  the app's otherwise; an app's own module (another job system, a
  workflow engine) takes either's place, in `config :storehouse, :runner`
  or a call's `:runner`. Telemetry `[:storehouse, :job, ...]` for each
  run and each job given up.
- Moving between stores: `Storehouse.copy/2` copies a file from one
  store to another (in S3 itself between buckets the same credentials
  reach, on the disk between two local stores, else a chunk at a time
  with its checksum checked) and `Storehouse.copy_prefix/2` copies many,
  several at once, skipping those already there, so it can run again;
  `mix storehouse.copy` runs it with its progress. `Storehouse.Mirror` is
  a store that writes to a primary and copies each file to its mirrors
  as jobs of the app's runner, retried until they answer, never failing
  the primary's write. The optional adapter callback `uploaded/1` is told
  of a file uploaded straight to the store once `verify_upload/2` keeps
  it. A file streamed to S3 in one request now keeps its checksum there
  too.
- Editing a photo's metadata without re-encoding it, only when asked:
  `Storehouse.JPEG` removes the location (`strip(jpeg, :gps)`, the Exif
  GPS directory zeroed and XMP's GPS properties removed), keeps only the
  tags named (`strip(jpeg, {:keep, tags})`), and writes the author's
  name, copyright and description (`put_tags/2`), in a JPEG's own
  segments, its tables and image data copied byte for byte and an MPF
  index of the pictures after it kept right. `Storehouse.Analyzer.EditMetadata`
  is the step that writes the edited file back over the original, its
  checksum and size now in its result, while the file's `:checksum`
  stays the upload's. It reads only a photo's metadata into memory
  (`Storehouse.JPEG.edit_file/3`). What makes the changes is a
  `Storehouse.MetadataEditor`, Storehouse's own (`Builtin`, JPEG) unless
  the step's `:editor` or `config :storehouse, :metadata_editor` names
  one of the app's, around ExifTool for other types. A step may now give
  `{:ok, result, path}`: the steps after it read the file it left.
- PNG and WebP metadata, edited as a JPEG's: `Storehouse.PNG` (Exif,
  XMP and text chunks, each with its checksum; written tags also as the
  `Author`, `Copyright` and `Description` text readers show; an APNG's
  frames copied) and `Storehouse.WebP` (Exif and XMP chunks, and the
  `VP8X` header's flags; a simple WebP given a header when it is given
  Exif; an animation's frames copied), both reading only the metadata
  chunks into memory. `Storehouse.MetadataEditor.Builtin` edits all
  three.
- Reading a file back: `Storehouse.head/2` (its size, stored type and
  checksum, without reading it), `Storehouse.read/2` (all of it, refused
  past `:max_bytes` before a byte is read), `Storehouse.stream/2` (a chunk
  at a time, as the stream is taken; `Storehouse.ReadError` when the
  store fails halfway) and `Storehouse.download/3` (to a path). The
  optional adapter callbacks `head/1` and `read_range/3`
  (`Storehouse.Local`, `Storehouse.S3`), and telemetry spans for each.
- Cleanup: `Storehouse.list/2` (the files under a prefix, a page at a
  time) and `Storehouse.delete_prefix/2` (a thousand at a time, with S3's
  DeleteObjects), with the optional adapter callbacks `list/1` and
  `delete_many/1`. `Storehouse.delete_later/2` and
  `Storehouse.delete_prefix_later/2` delete as jobs of the app's runner,
  tried again until the store answers, and `Storehouse.Sweeper` deletes
  the temporary files older than a day on stores with no lifecycle rules
  (one node of a cluster at a time; `Storehouse.Sweeper.sweep/1` at
  once).
- `Storehouse.Memory`, a store in memory for tests: every callback, each
  test's files its own (`checkout/0`, `allow/2`, `$callers`) so async
  tests never share them, `fail_next/2` for error paths, and
  `put_upload/2` for the browser's part of a direct upload.
  `Storehouse.Test`: `assert_stored/1`, `refute_stored/1` and
  `stored_files/0`.
- A file's own metadata: `metadata` on `Storehouse.File` (`%{}` by
  default), kept by `Storehouse.Ecto.File`, given with `store/2`'s and
  `verify_upload/2`'s `:metadata` and merged with
  `Storehouse.File.put_metadata/2` and `Storehouse.Ecto.put_metadata/3,4`.
  `Storehouse.Metadata` keeps it to what JSON and `jsonb` hold. Every key
  of it is the app's.
- `Storehouse.File` as JSON (`JSON.Encoder`, and `Jason.Encoder` with
  Jason), without its analysis; `Storehouse.File.to_map/2` chooses what
  goes.
- Work after the upload: `Storehouse.Analyzer`, a step of the app's that
  reads a stored file. What it made of the file is the file's `:analysis`,
  by step name: a `Storehouse.Analysis` (status, result, error, when),
  apart from the metadata, read with `Storehouse.File.analysis/2` and
  `analyzed/2` and kept in the column by `Storehouse.Ecto.File`. `Storehouse.analyze/3` runs steps at once, each once (or again
  with `force: true`), a failure kept with why; `store/2`'s `:analyze`
  runs them on the file just stored, from its path.
  `Storehouse.analyze_later/3` runs them as a job of the app's runner,
  then calls the app's `:then`.
  `Storehouse.Ecto.analyze_later/5`, and `insert/3` and `update/3` with
  `:analyze`, save the results in the record's column. A span per step,
  `[:storehouse, :analyze, ...]`. `Storehouse.Analyzer.Size`, a step that
  asks the store a file's real size and type.
- Files of an owner: `:owner` on `store/2`, `presign_upload/4`,
  `verify_upload/2`, `Storehouse.Live.allow/3` and `consume/3`, and
  `Storehouse.Ecto.put_file/4`, puts keys under the owner's prefix and
  refuses another's (`:not_owner`); `Storehouse.owns?/2` and
  `owner_key/2`. `:room` refuses a file larger than the room left
  (`:storage_full`): at presign by the size declared, at `verify_upload/2`
  by the size the store gives. `Storehouse.usage/2` counts an owner's
  files in the store.
- What happens to files, told as it happens (`Storehouse.Notify`): `:stored`
  (`store/2`, `verify_upload/2`), `:analyzed` (with the steps that ran;
  later analysis once the app's `:then` has it), `:failed` (a step, with
  why) and `:deleted` (a key, or a prefix and its count), to the app's
  `config :storehouse, notify: {module, function, args}`, or a call's
  `notify:`. `Storehouse.Notify.PubSub` broadcasts them on the app's
  `Phoenix.PubSub`, on a topic of the app's.
- The images of cameras and phones, checked by their bytes: HEIC and
  HEIF, AVIF (the primary image's size, cropped and turned as its `clap`
  and `irot` say), TIFF in either byte order (turned as its orientation
  says), and DNG as `image/x-adobe-dng`, a download. `Storehouse.Check.photos/0`
  lists those a page can show beside PNG, JPEG, GIF and WebP;
  `images/0` is as it was.
- The same file again: `:existing`, a function of a checksum, on
  `store/2`, `presign_upload/4` and `verify_upload/2` gives
  `{:existing, file}` for a file the app has, never another owner's, with
  nothing stored (and, at verify, the copy just uploaded deleted).
  `presign_upload/4`'s `:checksum` (hex or Base64,
  `Storehouse.claimed_checksum/1`) signs the upload with it: S3, the local
  plug and `Storehouse.Memory` take only those bytes.
- The JavaScript is on npm as `@hattoriai/storehouse` (the name
  `storehouse` there is another's), published from CI when a release is
  published, by npm's trusted publishing (no token) and with provenance;
  a Phoenix app imports it from `deps/storehouse` as before.
- Several stores: `use Storehouse.S3` and `use Storehouse.Local` define a
  store of the app's own, with its config under its name (or another
  app's, `otp_app:`), usable wherever a store is (`adapter:`). An Ecto
  field's `store:` (`Storehouse.Ecto.File` is now a parameterized type)
  makes its files permanent, deletes them and analyzes them there;
  `Storehouse.Ecto.store/2`. `Storehouse.Local.Plug`'s `:store` serves a
  second local store.
- Uploads from any client: `Storehouse.Batch.presign/2` and `register/2`
  sign and check a batch of uploads straight to the store, one result per
  file (`{:ok, _}`, `{:existing, file}` or `{:error, code}`), the room
  shared by the batch, the same bytes twice in a batch one file.
  `Storehouse.Plug.Presign` and `Storehouse.Plug.Register` answer them in
  JSON, with the owner, the room and the files the app has asked of
  functions of the conn, and the app's own JSON of its records from
  `:then`.
- `storehouse/client`, in the npm package: the browser's part of uploads
  from any client (`createUploadQueue`), for the presign and register
  plugs, with no dependencies. Each file's SHA-256 read in a Web Worker
  and sent with its presign, the files added together presigned in one
  request, a few sent at once and each tried again on a network error or
  the store's 5xx, registered in batches; a result, progress and cancel
  for each. Types in `storehouse-client.d.mts`.

### Fixed

- The plugs of uploads from any client (`Storehouse.Plug.Presign`,
  `Register`, `Multipart`) lost their options when a server called their
  `init/1` again on options already made (Bandit with `plug: {plug, opts}`).
- `Storehouse.S3` sent a `PUT` without a body (a copy) as
  `application/octet-stream`, whatever type it signed.

### Changed

- A file with a HEIF `ftyp` box was `application/octet-stream`; it is now
  `image/heic`, `image/heif` or `image/avif`.
- Storehouse's JSON is in one place, a module of its own: the app's
  `config :storehouse, :json_library`, else Elixir's own `JSON` when it
  is there, else Jason. No other part of it calls a JSON library.
- Storehouse takes Elixir 1.17 (with Jason, which 1.17 needs for JSON),
  and CI tests it there too.
- `Storehouse.Ecto.delete_files/2` (and so `update/3` and `delete/3`)
  deletes through `Storehouse.delete_later/2`: retried by the cleaner when
  it runs, at once as before when it does not.

## [0.1.0]

The first release: the storage of Kotoba and Hakushi, taken out of them.

### Added

- `Storehouse.store/2`: a file checked by its bytes and stored under a
  new, safe key, as a `Storehouse.File`, with `:accept`, `:max_bytes`,
  `:max_pixels`, `:key` and `:preview`.
- `Storehouse.Check`: the type of a file from its bytes (PNG, JPEG, GIF
  and WebP images with their width and height, a JPEG's turned as its
  EXIF says; PDF; MP4 and WebM video; ZIP and Office documents; plain
  text), and every other file as `application/octet-stream`.
- `Storehouse.Adapter`, the behaviour of a store (Kotoba's and Hakushi's
  callbacks), `Storehouse.Local` and `Storehouse.Local.Plug`, which serves
  files with their checked type, safe headers and byte ranges.
- `Storehouse.fetch/2`: a file from an address of the hosts an app
  allows, with redirects checked and the download stopped at
  `:max_bytes`.
- `Storehouse.S3`: Amazon S3, and the stores that speak its API
  (Cloudflare R2, MinIO, Tigris, LocalStack), with no other library: it
  signs its requests itself (Signature Version 4).
- Direct uploads: `Storehouse.presign_upload/4` signs an upload the
  browser makes straight to the store (its key, type and size), and
  `Storehouse.verify_upload/2` checks the file there by its first bytes,
  and deletes it when it is not what it said. `Storehouse.Live.allow/3`
  does both for a LiveView upload, with the uploader of `storehouse.js`.
  `Storehouse.Local.Plug` takes direct uploads too, for development.
- Private files: `Storehouse.signed_url/2`, from S3 or the local plug
  (`private: true` serves only signed URLs), and `Storehouse.Redirect`,
  a lasting URL that checks the person and redirects to a signed one.
- `Storehouse.Live.consume/3`: the files of a LiveView upload, each
  stored once, with a result for each.
- Streamed uploads: `Storehouse.Live.allow/3` with `mode: :stream` sends
  a file through the LiveView and on to the store as each chunk comes
  (`Storehouse.Live.Writer`), with no file on the app's disk: to S3 in
  the parts of a multipart upload, each with its checksum, two in flight
  from a process of their own, the upload held back when they are; its
  first bytes checked on the way. The optional adapter callbacks
  `stream_open/2`, `stream_write/2`, `stream_close/1` and `stream_abort/1`
  (`Storehouse.S3`, `Storehouse.Local`).
- Temporary, then permanent: `cache: true` stores a file under the
  temporary prefix (`Storehouse.cache_prefix/0`), and `Storehouse.promote/2`
  makes it permanent with a copy in the store (the optional adapter
  callback `copy/2`: S3's CopyObject, the local disk's copy).
- `Storehouse.Ecto`: files in a record's columns (`Storehouse.Ecto.File`,
  or a list of them), put with `put_file/4`, checked against the field's
  limits, made permanent in the save's transaction, and, with `update/3`
  and `delete/3`, deleted from the store once the record no longer has
  them.
- Checksums: each `Storehouse.File` has the SHA-256 of its bytes
  (`checksum`, Base64), sent to S3 with the file
  (`x-amz-checksum-sha256`), which checks and keeps it;
  `Storehouse.checksum/1` gives it of a copy, and the optional adapter
  callback `checksum/1` gives a stored file's.
- Telemetry: `[:storehouse, :store | :fetch | :presign_upload |
  :verify_upload | :delete, :start | :stop | :exception]` spans, with the
  file or the reason a file was refused.
- Keys (`Storehouse.key/2`, `safe_name/2`, `valid_key?/1`), display names
  (`clean_name/1`) and `safe_url?/1`.
