# TODO

Work in order. Each task ends with its tests, `docs/architecture.md` and `docs/performance.md` updated, a commit and a push. Done items are ticked.

## 1. Finish the app's prototypes

Everything the app shows must be real (architecture, status paragraph: "The UI shows only real data").

- [x] Settings, storage: "Ask where to store each new collection" does nothing. Make it a device setting the core keeps; creating a collection then asks for the folder.
- [x] Settings, storage: "Space for other people's notes" does nothing. Make it a limit on the events each profile's relay keeps for others, pruning the oldest first.
- [x] Settings, storage: "Space for pictures in notes" refers to Blossom, which does not exist yet. Remove it until Blossom does.
- [x] Settings, sharing: "Hours" says "not available yet". Make it a real window of hours in the sharing limits.
- [x] Settings, circle relay: the whole section only changes switches on screen; circle relays (architecture 4.5) are not built. Remove it until they are.
- [x] Settings, search: "Circle catalogs on this device: 6 circles, 18.4 GB" is made up, and there are no catalogs. Remove it.
- [x] Settings, search: "Clear search history" does nothing, and search history lives only in the search screen's memory. Keep the history per profile in the core and make clearing it work.
- [x] Settings, about: "Arca prototype, Version 0.1.0" is typed in. Show the real version.
- [x] Menu: "My circles". Show the circles this profile is in (Arca Commons, and the test network's circle with its admin, moderators, pool and collections), and create a circle on the test network (the chain burns the fee; the creator keeps its log).
- [x] Menu: "Liked and shared files". Likes (NIP-25 kind 17 on a file, which also means "I share it") do not exist. Build them: like and unlike a file, list what this profile liked.
- [x] Menu: "History". Keep the files this profile opened, show them, clear them.
- [x] Menu: "Help". A page that explains Arca in plain words: profiles and addresses, collections and copies, suggestions and moderators, the test network and marcas.
- [x] Advanced search: similar-file matching (TLSH, PDQ) is announced as "not built yet". The note stays; the feature is listed under Later.

## 2. Settle a day in steps that can each be proven small (done)

A wrong day's settlement is proven with the whole of several namespaces (about 1.5 KB per keeper; `docs/architecture.md` 10). Keep running totals through the day as holding proofs arrive (provers per partition, storage weight, collection keepers and interest), so settling one keeper needs only its own entries and the totals, and settle keepers in bounded batches over the next day's first blocks. Rewards must come out as they do now (`test/chain_rewards_test.dart`), and every settlement step must have a small fraud proof.

Done: running totals in the `tally` namespace, one trace entry per settlement step, lazy lapses. A wrong step is proven with about 13 KB with 400 keepers (was 600 KB). The reward tests pass unchanged in their numbers; two rules moved slightly (pass-on divides by the collections kept the day before; a keeper that missed a day is caught when it next acts, and may still mine).

## 3. Harden I2P and the network

- [x] Commit the `i2p-dart` gateway rotation fix (`docs/performance.md` 3.16) in its own repository, with a test, apart from the changes already pending there. (i2p-dart daa3e41: the rules are in `GatewayClock`, tested in `test/gateway_rotation_test.dart`.)
- [x] Reachability and sync over hours, not minutes (`tool/reach_check.dart`, `tool/live_sync_check.dart`), on the desktop and the C61. Desktop: `live_sync_check --hours=3`, eleven rounds over 1.8 hours before the computer slept, none missed (median 89 s, worst 371 s). C61: 90 minutes following the seed without a gap. Found on the way and fixed: a node that is "up" but deaf (probes and a restart, `docs/performance.md` 3.17), a seed deaf after the computer slept (a heartbeat), a crash when restarting I2P (`i2p-dart` ac150c1), and a restarted seed cut off from its peers (3.16).
- [x] Battery and data use on the C61 with the test network running, in light and full mode (`docs/performance.md` 3.18). Light: 4.9% of a core, 15.9 MB/h in, 9.3 MB/h out, after cutting the wallet's reads (was 36.7 MB/h in). Full: 11%, 11.7 MB/h in, 15.5 MB/h out. With the screen off Android freezes Arca: nothing is used and nothing is followed; it follows again within minutes of waking. The phone charged throughout, so battery is given as processor time.
- [x] Find out what sends long runs on this machine SIGTERM. It is earlyoom (`/etc/default/earlyoom`: `-m 10,5 --prefer=...dart...`): when free memory and swap both fall to 10% it stops a dart process first. It stopped 30 dart processes in a week (test runners, the compiler, `reach_check`). Long checks need free memory; the code is not at fault.

## 4. A public test network

- [x] A seed node: a headless founder (`tool/seed_node.dart`), run as a service, that keeps a public collection and the test network going. Tried on I2P: founds the network, stops cleanly on SIGTERM, resumes where it stopped, and a desktop app joined it with one button. A restart used to cut it off from its peers for up to ten minutes (they held its old tunnels); nodes now remember their peers (`docs/performance.md`, 3.16).
- [x] No invites: the test network is built into the app (`TestnetSpec.builtIn`), and nodes find each other at a meeting point, an I2P address made from the network's spec that every full node answers for; a new full node fetches the corpus by hash from the nodes it met (`docs/architecture.md` 10).
- [x] A newcomer checks the chains it is shown instead of trusting a checkpoint: all answers at the meeting point, header summaries from a trusted anchor, mining proofs checked in full for the newest blocks and a sample drawn by work, the heaviest chain that holds up; checkpoints built into each release (`docs/architecture.md` 10, `test/core_meeting_test.dart`).
- [ ] Run the seed somewhere that stays on, with a public-domain corpus, and put its `spec.json` in `TestnetSpec._builtInSpec`.
- [x] Joining with one button: "Take part in the test network" in the wallet.
- [x] Docs for running a seed node and for joining (`docs/seed-node.md`).

## Later

- The header archive on disk, with only recent headers in memory (`docs/performance.md` 3.19).

- Similar-file matching (TLSH for bytes, PDQ for images).
- Circle relays (architecture 4.5) and Blossom (4.6).
- Data availability: a producer who never publishes a block's transactions cannot be shown wrong to a light client.
