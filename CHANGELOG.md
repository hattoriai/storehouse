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
- `Storehouse.Live.consume/3`: the files of a LiveView upload, each
  stored once, with a result for each.
- Keys (`Storehouse.key/2`, `safe_name/2`, `valid_key?/1`), display names
  (`clean_name/1`) and `safe_url?/1`.
