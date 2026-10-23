# Changelog

All notable changes to Storehouse are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and Storehouse follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
