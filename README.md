# Arca

**A Wikipedia for files.** Arca is a shared library that people
everywhere build together: anyone can add files, anyone can search and
read them, and the people who keep them safe are paid for it. There are
no servers: every app is a relay, every byte travels over I2P, and a
phone is a full participant.

Radio archives, maps, books, recordings, manuals, family photos and
community records live today on single servers and personal drives, and
they vanish when one person stops paying or one service shuts down.
Arca gives files what Wikipedia gave articles: one place to add them, one
way to find them, and many hands keeping them.

Status: a working prototype (version 0.1.0) for Linux and Android,
running on the live I2P network and on a public test network of its own
chain. The design is in [arca-whitepaper.md](arca-whitepaper.md), the
implementation in [docs/architecture.md](docs/architecture.md).

---

## What makes Arca different

### 1. Proof of Keeping: mining is keeping what people want kept

Arca has one coin, the **marca**, created by one global blockchain with
fixed rules and no owner. Its mining input is not electricity or raw
disk space but **keeping files that people chose to keep**: keepers store
collections on their disks, prove every day that they still hold them,
and earn marcas for it. The more meaningful data people keep, the
stronger the network.

- **Every copy is unique to its keeper.** Each chunk is stored XOR a
  memory-hard keystream of the keeper's key (Argon2id), so one disk
  cannot pretend to be a hundred: remaking a slice costs 1,355 times
  reading it (measured, testnet setting).
- **Speed buys nothing.** A clock names random slices once a second; a
  faster disk reads no more of them. A Raspberry Pi with used disks
  competes with a data center.
- **Rare data gets company.** Rewards follow a replication curve that
  rises up to ten copies and freezes after, so the incentive is to be
  one of the first ten keepers of something worth keeping.
- **Interest beats bulk.** 70% of each day's issuance pays for what the
  wider library wants (keepers from other circles, paid reading); junk
  kept only by its author earns almost nothing, and fake popularity
  always loses half to burning.

### 2. Circles and collections, edited like Wikipedia

Every file in the library has passed some community's curation.
**Circles** are communities with their own members, moderators, rules and
reward pool; **collections** are trees of folders and files they build
together. Anyone proposes additions and edits; moderators accept or
reject them; every version is signed and kept. Members who dislike their
moderators take their disks and fork the circle the same day: forking
is the real check on power.

### 3. Every client is a relay, over I2P only

Identities, comments, likes, follows, suggestions and moderation are
**Nostr** events signed with the profile's key. There are no relay
servers: every Arca app stores and answers Nostr requests itself, and
every byte between two apps travels over **I2P**, so no server ever
learns anyone's IP address. The I2P router is
[i2p-dart](https://github.com/x1watt/i2p-dart), a pure Dart I2P node
embedded in the app. Nothing that maps a node to a place or a time is
ever published.

### 4. Phones are full participants

The chain keeps **state only**, not history: blocks carry their
transactions, full nodes apply them and keep them for a 24-hour
challenge window. A phone follows headers, reads its balance with
Merkle proofs, and rejects any block an honest full node proves wrong
with a **fraud proof** (a few KB). Finality for a phone needs one honest
full node, not an honest majority. A newcomer checks the chains it is
shown (signatures, claimed work, a sample of mining proofs) instead of
trusting anyone.

### 5. Private money, public keeping

Payments between people are **private, in the manner of Mimblewimble**:
amounts hidden in Pedersen commitments with Bulletproof range proofs,
every output to a one-time stealth key, so a payment names neither payer
nor payee and the receiver may be offline. What earns is public, because
it must be checked to be rewarded: keeping, pools, payouts, issuance and
burns. Anyone can check from the chain's state alone that no marca was
ever made from nothing. A wallet can hand an auditor a view key.

### 6. Files that carry their own knowledge

A collection is an ordinary folder. Everything Arca knows about a file
is written **next to it**: `Talk.arca.json` (title, description, tags,
SHA-256, layers) and `Talk.en.srt` (subtitles), so the folder can be
copied, backed up or opened by any player without losing anything.
Videos and recordings get **subtitles made on the device** by
whisper.cpp, which make speech searchable; nothing leaves the device.

---

## Status: what works today

| Area | Working now | Planned |
|---|---|---|
| Profiles | Create, import (nsec), rename, switch, export, delete; several per device, each with its own key and I2P address; encrypted vaults | ncryptsec import, passphrases |
| Network | Embedded I2P node (i2p-dart), one destination per profile, self-healing ("up" is probed, not trusted) | tunnel pools per destination, end-to-end encryption at the I2P layer |
| Nostr | Events, signatures, relays in every client over I2P, comments (NIP-22), likes and shares (NIP-25), deletions | circle relays (always-on members), Blossom media |
| Collections | Create from a folder, add files (SHA-256, SHA-1, type from content), edit metadata, moderators, suggestions accepted or rejected, follow and keep a copy fetched in chunks over I2P | review queues and quotas in circles |
| Media | Video stills and hover previews (ffmpeg), playback (libmpv), subtitles with whisper.cpp on the device | text extraction, OCR |
| Search | By words in titles, paths, tags and descriptions; by SHA-256 or SHA-1 | full-text over subtitles and text layers, similarity (TLSH, PDQ), circle catalogs |
| Chain | Corpus and packing, clock-limited mining, daily holding proofs, rewards with the replication curve and both budgets, circles with logs and anchors, pool payouts and claims, passes and serving rules, fraud proofs, light clients, private marcas | the seed on an always-on machine, faster curve arithmetic for phones |
| Test network | Built into the app: "Take part in the test network" in the wallet, nothing to type | a public-domain corpus on an always-on seed |

The test network's marcas have no value.

---

## How it works

```
 contributor --proposes--> moderators --accept--> collection (signed version)
                                                     |
                                     keepers follow it, pack it, keep it
                                                     |
                         daily holding proofs --> global chain (Proof of Keeping)
                                                     |
                                   marcas --> the circle's pool --> members
                                                     |
 readers <-- download from keepers: free allowance, 24-hour pass, or member access
```

| Role | Does | Gets |
|---|---|---|
| Reader | browses, searches, downloads | a free daily allowance; a 24-hour pass for more |
| Contributor | proposes files, folders, descriptions | nothing from the chain; a share of the circle's pool if its policy says so |
| Keeper | keeps collections on disk, proves it daily, serves downloads | marcas through the circle's pool, free access, pass revenue for bytes served |
| Moderator | reviews proposals, admits members, signs the circle's index | a share of the pool if the policy says so |
| Circle | curates collections under its own rules | marcas through its members' keeping, and trust shown in search |

The whitepaper explains the economics, the defences against abuse and
the open problems: [arca-whitepaper.md](arca-whitepaper.md).

---

## Getting started

### Build

```sh
git clone --recursive https://github.com/x1watt/arca
git clone https://github.com/x1watt/i2p-dart     # next to arca: ../i2p-dart
cd arca/app
flutter build linux                              # or: flutter build apk
```

Linux needs `cmake`, `patchelf`, `libmpv2` and `ffmpeg` to build (on
Ubuntu: `sudo apt install cmake patchelf libmpv-dev ffmpeg`). The Linux
bundle carries libmpv, ffmpeg and their libraries
(`app/linux/packaging/bundle_media.sh`), so it runs without them
installed. To add Arca to the desktop's application list, run
`app/linux/packaging/install_desktop.sh` after building (`--remove`
takes it out).

### First run

The app creates a profile without asking anything, starts its I2P node
and is ready: publish nothing until you act. From there:

1. **Create a collection** from a folder (or an empty one), add files,
   give them titles, descriptions and tags.
2. **Share your address** (`arca:npub...@....b32.i2p`); others follow you
   and your collections over I2P, comment, like, and suggest edits you
   accept or reject.
3. **Keep a copy** of a collection you follow: Arca fetches it in chunks
   from whoever serves it and keeps it in sync.
4. **Download a speech model** in Settings, Subtitles, and every video
   and recording in your collections gets subtitles made on the device.
5. **Take part in the test network** from the wallet: a computer keeps
   the network's files and earns test marcas for keeping them; a phone
   follows lightly and keeps nothing unless you ask.

### Speech models

Subtitles are made with whisper.cpp. The models are not part of the app:
from Settings, under Subtitles, the app downloads the one that suits the
device from this repository's
[models-v1 release](https://github.com/x1watt/arca/releases/tag/models-v1)
and checks its SHA-256. They are unchanged copies of the quantized models
from [ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp)
(MIT license):

| Model | Size | For |
|---|---|---|
| `ggml-tiny-q5_1.bin` | 31 MB | older phones |
| `ggml-base-q5_1.bin` | 57 MB | phones |
| `ggml-small-q5_1.bin` | 181 MB | recent phones, older computers |
| `ggml-large-v3-turbo-q5_0.bin` | 547 MB | computers with 8 GB of memory or more |

### Running a seed node

The test network is started and kept going by a headless founder, the
seed node: see [docs/seed-node.md](docs/seed-node.md).

---

## Privacy principles

- **I2P only.** No clearnet path, no WebSocket relay on the internet, no
  server that learns anyone's address. The one exception is the speech
  model download, a plain HTTPS download from GitHub that carries no
  profile key or address.
- **Profiles are separate accounts**, each with its own key and I2P
  address; nothing links two profiles unless their owner does. (Two
  profiles on one device go online together; the app says so.)
- **Nothing that locates a node is published**: latency and throughput
  stay on the client that measured them; serving limits (Wi-Fi only,
  while charging, hours) never leave the device.
- **Search history and opened files never leave the device.**
- **Private payments** hide amounts, payers and payees.

---

## Inside

- `app/`: the Flutter app (Linux and Android). The UI only renders and
  forwards actions; it never touches keys, sockets or files.
- `packages/arca_core/`: the core in pure Dart, on its own isolate:
  `profiles` (keys, vaults), `nostr` and `relay` (events, the relay in
  every client), `transport` (I2P, file transfer), `library`
  (collections, manifests, previews, subtitles), `chain` (corpus,
  packing, mining, state, rewards, circles, passes, fraud proofs, light
  clients, wallets), `crypto` (Schnorr, Pedersen commitments,
  Bulletproofs).
- `native/arca_whisper/`: a small C interface over whisper.cpp
  (`third_party/whisper.cpp`, a submodule).
- Isolates: UI, core, I2P, chain, plus workers for transcription,
  packing and hashing, so nothing heavy ever runs where the screen is
  drawn.

Tested in process and on the live I2P network
(`packages/arca_core/tool/live_*_check.dart`): profiles fetching each
other's events through real tunnels, collaboration between an admin, a
moderator and followers, a chain of three keepers over five days with
forks healed within a block, a phone following as a light client and
dropping a bad block one second after a fraud proof.

Documents:

- [arca-whitepaper.md](arca-whitepaper.md): Proof of Keeping, circles,
  collections, marcas, search, abuse and defences, open problems.
- [docs/architecture.md](docs/architecture.md): how the client is built,
  section by section, with what is done and what is not.
- [docs/performance.md](docs/performance.md): measured costs and the
  mistakes not to repeat.
- [docs/seed-node.md](docs/seed-node.md): running the test network's
  seed.
- [docs/formats/web-archive.md](docs/formats/web-archive.md): a draft
  format for archiving websites as timelines.
- [docs/TODO.md](docs/TODO.md): the work in order.

## Credits

Arca builds on [i2p-dart](https://github.com/x1watt/i2p-dart) (the I2P
node), the Nostr protocol and its NIPs, [whisper.cpp](https://github.com/ggerganov/whisper.cpp)
by Georgi Gerganov, [media_kit](https://github.com/media-kit/media-kit)
and libmpv, ffmpeg, and on ideas from Arweave and Signum (proof of
capacity), and Mimblewimble (Grin, Beam, Litecoin's MWEB).

## License

BSD 3-clause, Copyright (c) 2026 Max Brito. See [LICENSE](LICENSE); the third
party code included (whisper.cpp and a patched media_kit_video, both MIT)
is listed in [NOTICE](NOTICE).
