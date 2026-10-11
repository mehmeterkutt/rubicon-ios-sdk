<!-- Title: Conventional Commits, for example "feat(queue): segmented event store". -->

**Public API change:** none <!-- or: list the changed symbols; API/*.txt is updated in this pull request -->

## Problem

<!-- What is missing or wrong, and which plan steps this is. -->

## Change

<!-- What this pull request does, one paragraph per step. -->

## Decisions implemented

<!-- For example "Queue 4, iOS Queue 1, Disk 1". Name any implementation decision added to section 15 of the plan. -->

## How it was tested

<!-- The tests added, and anything checked by hand (simulator, consumer apps, demo app). -->

## Checklist

- [ ] `Scripts/check.sh` is green; `Scripts/check.sh --all` when `Sources/Rubicon`, `Sources/RubiconObjC` or `ConsumerApps` changed
- [ ] Every test the plan lists for the steps exists
- [ ] New dependencies: none <!-- or: test-only or tool-only additions named here -->
- [ ] Every new WARN or ERROR has a `Code` in `docs/issue-codes.md` with its Platform column; every new way to lose an event has a `DropReason`
- [ ] No value, id, key, header, body or query string reaches a log line
- [ ] Every required-reason API call is under `Sources/Rubicon/Platform` and in a declared category of `PrivacyInfo.xcprivacy`
- [ ] `CLAUDE.md` updated if a rule changed; plan status, traceability and decisions log updated
