# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- The first release of the Rubicon iOS SDK: `track`, `screen`, `identify`, `reset`, super
  properties, `flush`, consent (`optOut`, `optIn`, `isOptedOut`), `clearLocalData`, `deviceId`;
  automatic lifecycle, install and update, session, screen view, deep link and network request
  events; `beforeSend` hooks; a configurable logger and an event observer; `SDK Diagnostics`.
- Durable on-device storage (JSON Lines segments), batched gzip uploads with retry and
  `Retry-After`, a background flush inside a background task, and remote configuration.
- The `RubiconObjC` wrapper for Objective-C apps, with `NSException`-safe blocks.
- A privacy manifest with the collected data types and the two required-reason APIs.
