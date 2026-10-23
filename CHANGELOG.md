# Changelog

All notable changes to Storehouse are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and Storehouse follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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
  `Storehouse.delete_prefix_later/2` queue deletions in
  `Storehouse.Cleaner`, a process of the app's that tries them again until
  the store answers, and sweeps the temporary files older than a day on
  stores with no lifecycle rules (`:sweep`, one node of a cluster at a
  time; `Storehouse.Cleaner.sweep/1` at once).
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
  `Storehouse.analyze_later/3` runs them in `Storehouse.Tasks`, a
  supervisor of the app's, or in Oban (`runner: :oban`,
  `Storehouse.Oban.Analyze`), then calls the app's `:then`.
  `Storehouse.Ecto.analyze_later/5`, and `insert/3` and `update/3` with
  `:analyze`, save the results in the record's column. A span per step,
  `[:storehouse, :analyze, ...]`. `Storehouse.Analyzer.Size`, a step that
  asks the store a file's real size and type.
- What happens to files, told as it happens (`Storehouse.Notify`): `:stored`
  (`store/2`, `verify_upload/2`), `:analyzed` (with the steps that ran;
  later analysis once the app's `:then` has it), `:failed` (a step, with
  why) and `:deleted` (a key, or a prefix and its count), to the app's
  `config :storehouse, notify: {module, function, args}`, or a call's
  `notify:`. `Storehouse.Notify.PubSub` broadcasts them on the app's
  `Phoenix.PubSub`, on a topic of the app's.

### Changed

- Storehouse's JSON is in one place, `Storehouse.JSON`: the app's
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
