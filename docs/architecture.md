# Arca architecture

This document describes how the Arca client is built: identities and profiles, Nostr as the protocol for people and their messages, I2P as the only network, and how data is stored on the device. It is written before implementation and is the reference the code must follow. The economic and consensus design (marcas, Proof of Stewardship, the global chain) is in `arca-whitepaper.md`; this document covers the client and its communication, and points to the whitepaper where the two meet.

Status: implemented in `packages/arca_core` (pure Dart, tested) and wired into the app: BIP-340 keys and signatures, NIP-19, NIP-01 events, filters and relay messages, an event store, a relay and client over a message link, the profile store with encrypted vaults, and the network manager, all on a core isolate. The app creates a profile on first run; can create, import (nsec), rename, switch, export and delete profiles; starts an I2P node with `i2p-dart`; and puts the active profile and those set to stay online on the network, each with its own destination and relay. A rename publishes the profile as a kind 0 event in its own relay. Every profile starts in the built-in catch-all circle, Arca Commons; it can create collections (a new folder under the default storage folder, or an existing folder), add files and folders (copied in, hashed with SHA-256 and SHA-1, type detected from content), edit titles, descriptions and tags, and comment on files and collections. Each collection is published as an addressable event (provisional kind 30780) and each comment as a kind 1111 event in the profile's relay. Verified end to end on the live I2P network (`packages/arca_core/tool/live_i2p_check.dart`): one profile fetched another's signed kind 0 through real tunnels. Until circles exist, a profile's relay only keeps its own events and events that tag it. Videos get a still preview and an animated hover preview made with ffmpeg run from the core isolate, and play in the app through libmpv (media_kit). Both ship with the app: Android bundles libmpv, and the Linux bundle carries libmpv, ffmpeg and ffprobe with their libraries (app/linux/packaging/bundle_media.sh, run by the CMake install step), so nothing has to be installed on the system. A profile can follow someone by Arca address (`arca:npub...@....b32.i2p`), fetch their profile and collection events from their relay over I2P, and suggest title, description and tag changes to their files: the suggestion is a signed event (provisional kind 4781, tagged with the owner, the collection and the file hash) delivered to the owner's relay; the owner accepts or rejects it, which republishes the collection and publishes a kind 7 reaction (+ or -) the suggester can read back. Verified end to end with two instances on the live I2P network. Collections can have moderators, whose signed changes are folded into the admin's collection; others' changes are refused; followers can keep a copy, fetched in chunks over I2P (4.7, 5.7). Subtitles are made on the device with whisper.cpp from a speech model downloaded on demand (9.3). The UI shows only real data. Not yet: creating circles, circle relays, and Blossom.

## 1. Principles

1. **I2P only.** Every byte between two Arca clients travels over I2P. There is no clearnet path, no WebSocket relay on the internet and no server that learns anyone's IP address. The pure-Dart I2P node in `../i2p-dart` is the transport.
2. **Nostr for people.** Identities, profiles, comments, likes, replies, follows, moderation and settings that others must see are Nostr events (NIP-01), signed with the profile's key. We use existing NIPs wherever one fits and define Arca kinds only where none does.
3. **Every client is a relay.** Each client stores events and answers Nostr requests from other clients, over I2P. There are no dedicated relay servers; a well-connected client with a lot of storage is simply a bigger relay.
4. **Authors keep their own data, circles keep it available.** Every event a profile creates is kept by that profile's client, and copies go to whoever owns the thing it is about and to the relays of the author's circles. Phones and laptops are often off; a circle's always-on machines (circle relays, 4.5) are where others find a member's notes when the member is offline.
5. **Profiles are separate accounts.** One device can hold several profiles. Each has its own key, I2P address, settings, circles, collections and history, and nothing links two profiles on the network unless their owner links them.
6. **Nothing heavy on the UI isolate.** Signing, verification, hashing, database access and the I2P node run on background isolates. The UI isolate only renders and forwards user actions.

## 2. Layers

From top to bottom:

- **UI (Flutter).** Screens and widgets only. Talks to the core through a narrow async API and streams of state. Never touches keys, sockets or the database directly.
- **Core.** Profiles, collections, circles, search, transfers, moderation rules. Runs on a core isolate.
- **Nostr layer.** Event model, signing and verification, the local relay (storage and query), the relay protocol over I2P, the outbox that delivers our events to their destinations, and the Blossom media server that works beside the relay (4.6).
- **Transport.** `i2p-dart`, running in its own isolate (`I2pWorker`). Carries Nostr messages as I2P application messages, and file content as content-addressed blobs and swarms.
- **Storage.** A per-device area (I2P state, shared content store, storage folders) and one area per profile (encrypted keys, settings, event database).
- **Chain (later).** The global chain and circle logs from the whitepaper. Out of scope for the first implementation, but the identity and relay design here is chosen so the chain can reuse it: the same keys sign circle log entries, and the same I2P links carry blocks and proofs.

## 3. Identity and profiles

### 3.1 What a profile is

A profile is a Nostr key pair (secp256k1, BIP-340 Schnorr signatures) plus everything the device keeps for it. The public key, shown as an `npub` (NIP-19), is the profile's identity everywhere in Arca: author of comments, member of circles, admin of collections, owner of a wallet. The secret key, shown as an `nsec`, never leaves the device except when the user explicitly exports it.

Each profile also has its own I2P destination on each device where it is used (section 5.3), so peers can reach it and cannot tie it to other profiles on the same device.

### 3.2 First run

On first launch the app creates a profile without asking anything:

1. Generate a new key pair from the platform's secure random source.
2. Generate the profile's I2P destination seeds.
3. Pick a placeholder display name (for example "Arca user" plus the first characters of the npub) and publish nothing yet; the kind 0 profile is published the first time the user edits it or interacts with others.
4. Store the secrets in the profile vault (3.5) and make the profile active.

The user can use the app immediately. Later they can rename it, add a picture and an about text (published as kind 0), or replace the key entirely by importing another one.

### 3.3 Importing an account

The user can import an existing Nostr identity:

- **nsec** (NIP-19 bech32 secret key), pasted or scanned as a QR code.
- **ncryptsec** (NIP-49, the key encrypted with a password), for safer transfer between devices.

Importing creates a new profile on the device with that key. It does not overwrite the auto-generated one; the user may delete that one afterwards. After import the client fetches the profile's latest kind 0, kind 3, kind 10002 and Arca lists from the relays it can reach (the profile's own previous devices, circle members it knows), so settings that live on the network come back.

An imported key used on another device at the same time is supported: each device gets its own I2P destination for the profile, and the profile's relay list (5.4) lists all of them.

### 3.4 Changing the key of a profile

"Change account" means importing another key into a new profile and switching to it. Profiles do not rotate keys in place, because an npub is an identity others have referenced in comments, memberships and admin roles; silently replacing it would orphan all of that. If a user wants to move to a new key, the old profile can publish a note pointing to the new npub, and circles may move roles by their normal governance.

### 3.5 Keeping secrets

Each profile has a vault file holding its nsec and its I2P destination seeds, encrypted at rest:

- Key derivation with Argon2id from a device secret kept in the platform keystore (Android Keystore, Linux Secret Service where available), optionally combined with a user passphrase.
- Encryption with XChaCha20-Poly1305.
- The decrypted key lives only in the core isolate's memory while the profile is active, and is wiped when the profile is locked or the app stops.

Export (showing the nsec or an ncryptsec) requires confirmation and, if set, the passphrase, with a clear warning that anyone with the nsec controls the account.

### 3.6 Several profiles on one device

Profiles behave as separate accounts. Each one has, of its own:

- key pair, vault and I2P destination;
- display settings, notification and privacy choices, sharing limits;
- joined circles, followed collections and their hold mode (on disk, sharing, or both);
- search history and recommendations;
- its own event database (its notes, comments, likes, the events it relays for others);
- wallet and marca balance (later, with the chain).

Some things are shared on the device, because they describe the machine rather than the person:

- the I2P router (one node per device, with one destination per active profile);
- the content store of blobs and chunks, deduplicated by hash;
- storage folders (the base folders on each disk);
- circle catalogs already downloaded (public data, identical for everyone).

When two profiles follow the same collection, its files exist once on disk and in the content store; each profile keeps its own record of following it, its own role and its own sharing choice. What a profile shares on the network is always served under that profile's own I2P destination, never under another profile's, so sharing a common collection does not reveal that two profiles are on the same device. The one leak a user must accept is timing: two profiles on one device go online and offline together. The profile screen says so.

Switching profiles is instant in the UI. Profiles the user marks as "stay online" keep answering requests and sharing in the background even when not selected; the others are offline while not selected.

## 4. Nostr in Arca

### 4.1 Event kinds

Standard kinds, used as the NIPs define them:

- **Kind 0, profile metadata** (NIP-01): name, picture, about, and optionally a NIP-05 identifier (only meaningful where the user has a web domain; Arca never needs it).
- **Kind 3, follow list** (NIP-02): people the profile follows, used for recommendations and web-of-trust ranking.
- **Kind 1111, comments** (NIP-22): comments on files and collections. The root is the file or collection, referenced with an `I` tag using NIP-73 external identifiers (below). Replies to comments are kind 1111 events whose parent is the comment, following NIP-22's root and parent tags.
- **Kind 7, reactions** (NIP-25): likes on comments and other events.
- **Kind 17, reactions to external content** (NIP-25): "Like and share" on a file or collection, referenced by its `i` tag. A kind 17 like from a profile means that profile shares the item; the client publishes it when the user likes and deletes it (kind 5) when they stop sharing.
- **Kind 5, deletion requests** (NIP-09): withdrawing one's own comments and likes.
- **Kind 10000, mute list** (NIP-51): people a profile does not want to see.
- **Kind 10002, relay list** (NIP-65): where the profile can be reached, with I2P entries (5.4).
- **Kind 30078, application data** (NIP-78): per-item moderation settings published by admins (4.4).
- **NIP-44 encryption, NIP-17 and NIP-59 gift wraps**: private messages and anything else only one recipient may read.
- **NIP-42 authentication**: proving membership when asking a relay for members-only data.
- **NIP-13 proof of work**: optional, required by a relay from unknown authors when it is under spam pressure.

External identifiers (NIP-73 `i` tags) for Arca items:

- a file: `arca:sha256:<hex>`, the SHA-256 of the whole file;
- a collection: `arca:collection:<owner pubkey hex>:<collection id>`;
- a circle: `arca:circle:<circle id>`.

Arca kinds, to be allocated when the protocol is fixed: the collection head (an addressable event by the owner pointing to the current tree root, its circle and its settings), catalog announcements, and circle log entries. The whitepaper's circle log is a natural fit for moderator-signed Nostr events; that decision belongs to the chain design and is left open here.

### 4.2 Every client is a relay

Each client runs a relay with the NIP-01 message set (`EVENT`, `REQ`, `CLOSE`, `EOSE`, `OK`, `NOTICE`, plus `AUTH` from NIP-42). The difference from ordinary Nostr is the carrier: messages travel as I2P application messages instead of WebSocket frames.

- **Framing.** Each I2P message on the Nostr port carries one NIP-01 JSON message, UTF-8. I2P application messages are limited to 32 KiB; an event larger than that is refused (Nostr events are small; files never travel as events). A `REQ` answer is split across as many messages as needed, ending with `EOSE`.
- **Reliability.** I2P delivery is best effort, like UDP. The `OK` message is the acknowledgement for `EVENT`; the outbox (4.3) retries with backoff until it arrives or the event expires. Subscriptions carry an id and a lifetime; the requester renews them and the relay drops them when they lapse, so no state leaks when a peer vanishes.
- **What a relay keeps.** Its own profile's events, always. Events addressed to things it owns (comments on its collections, replies to its notes, likes of its files), subject to its moderation rules. Events of profiles it follows and of collections it follows, as a cache, within a storage budget the user sets.
- **What a relay serves.** Anything it keeps that the requester is allowed to see. Public events to anyone; members-only items only after `AUTH` proves circle membership.
- **Limits.** Per-author and per-destination rate limits, a size limit, and optional NIP-13 proof of work for unknown authors.

### 4.3 Where events go

Every event is stored first in the author's own relay. The outbox then delivers copies:

- **Comments, replies and likes on a file or collection** go to the relays of the collection's owner and its moderators. The owner's relay is the authoritative home of the thread: readers fetch comments from it first, and it applies the item's moderation rules.
- **Replies and reactions to someone's comment** also go to that comment author's relays, so people see answers to what they wrote.
- **Everything public a member publishes** (profile events kind 0, 3, 10002 and lists, comments, likes) also goes to the circle relays (4.5) of every circle the member belongs to. This is what keeps a member's notes reachable while their own devices are off.
- **Private messages** go only to the recipient's relays, gift-wrapped.

Readers look for an event in this order: the circle relays of the circle it belongs to (or of the author's circles, for profile data), then the owner's own relays, then followers who cache. The author's own device is tried last, because it is the one most likely to be off. Every event is verified (id and signature) before it is stored or shown, whoever delivered it.

When the author's device comes back online, its outbox finishes any delivery that was still pending, so events written offline reach the circle relays and owners eventually.

### 4.4 Moderation

An admin or moderator of a file or collection sets, per item:

- who can comment: everyone, circle members only, or nobody;
- whether comments may include pictures and other media (4.6), and from whom;
- whether new comments are held for approval;
- blocked words;
- banned people.

These settings are published by the admin as a kind 30078 event with `d` tag `arca/moderation/<item id>`, so every relay that hosts the thread applies the same rules. Bans are also shared per circle: a circle's moderators publish a ban list (a NIP-51 list scoped to the circle), and the owner's relay rejects events from banned authors on all the circle's items. Removing a single comment is a moderation event that the owner's relay applies by no longer serving it; the author's own copy stays with the author, as with any Nostr event.

For circles, NIP-72 (moderated communities, kinds 34550 and 4550) is the closest existing model: a community definition lists its moderators, and approval events mark accepted posts. Arca should follow it where it fits and only diverge where the whitepaper's circle rules require.

### 4.5 Circle relays

Personal devices cannot be expected to be online. A circle therefore uses some of its members' machines as **circle relays**: computers that are almost always on and have the storage and bandwidth to answer requests from outside the circle. They are where others find a member's notes while the member is offline.

A circle may have hundreds or thousands of members, so relays are chosen automatically, never by hand.

**Volunteering.** In Settings, a member can volunteer the machine as a circle relay for some or all of their circles and set how much storage it gives to notes. Volunteering is required: no machine becomes a relay without its owner's consent, because being a relay reveals that the machine is online most of the time.

**Capability profile.** A volunteering client publishes, per circle, a small signed capability profile: that it volunteers, the storage it offers, and its declared availability class, taken from its own sharing settings. A machine set to share only on WiFi while charging declares itself "intermittent"; a machine with no such limits declares itself "always on". Phones default to intermittent and are rarely chosen; desktops, home servers and single-board computers on mains power are the natural relays.

**Measured uptime.** Declarations are only a claim, so the circle's active relays check them. At random moments each active relay sends a small request to every volunteer and counts the answers. Once a day it publishes a signed attestation per volunteer: how many of its checks were answered, as a count for the day, never with the times of the checks. A volunteer's uptime score is the share of checks answered over the last seven days, combined across the relays that checked it.

**Selection.** Every day, from the published capability profiles and attestations, a deterministic rule picks the active relays: volunteers ranked by uptime score, weighted by the storage they offer and their declared class, keeping the best N (for example 8, more for large circles) plus a few spares. Because the rule and its inputs are public, every member computes the same list and nobody has to be trusted to publish it; each active relay also publishes the list it computed so clients can use it directly and check it when they want. A new volunteer starts as a candidate and becomes eligible after a week of attestations. A relay whose score drops is replaced the next day.

**Bootstrap.** A new circle has no active relays to check anyone. Until it has enough measured volunteers, the machines of its admin and moderators act as its relays and do the first checks. Moderators can still exclude a machine that misbehaves (serves bad data, refuses the circle's moderation rules); they do not pick relays.

**What relays receive.** Every public event from the circle's members (4.3), and every event about the circle's files and collections: comments, replies, likes, moderation settings and bans. They apply the same moderation rules as the owner's relay, so a banned author's events are refused everywhere in the circle.

**Keeping each other in sync.** Active relays reconcile their stores continuously, using set reconciliation over event ids (Negentropy, NIP-77), so only missing events travel. An event that reaches any one relay reaches all of them within minutes. A member's client delivers to one or two active relays; the outbox's retries and the reconciliation do the rest. When the active list changes, a newly selected relay fills its store from the others before it is listed first.

**What readers do.** To read a member's notes or the comments on a collection, a client asks the circle's active relays, starting from the published order, moving on when one does not answer, and keeps its own private table of which relays answered well.

**Privacy.** The whitepaper rules out publishing anything that maps a node to a time. Relays are the one place where Arca publishes availability, and it does so narrowly: only for machines whose owners volunteered, only as daily counts and a seven-day share, never timestamps, latency or location, and always behind I2P so no IP address is involved. Machines that do not volunteer are never checked and never scored. The settings screen says this where the user volunteers.

**Load and abuse.** Relays rate-limit per author and per requesting address, may require NIP-13 proof of work from authors who are not members, and serve members-only data only after NIP-42 authentication. Only circle members can volunteer, and only active relays' attestations count, so a member cannot inflate their own score with fake checkers. A relay that stops answering loses score within days and drops out automatically.

**Relation to the whitepaper.** Active circle relays are the natural candidates for the circle's other always-on duties: anchoring the circle log to the global chain, building the circle's index and catalog, and serving as search gateways. The whitepaper's economics can reward that work later through the circle's pool payout policy, using the same uptime score.

### 4.6 Blossom: media for notes

Nostr events are small text; the pictures that go with them are not. Every client therefore runs a **Blossom server** beside its relay, following the Blossom protocol (BUD-01 to BUD-06): blobs addressed by their SHA-256, uploaded and deleted with signed authorization events, listed per author, and mirrored between servers.

**What it is for.** Small media that belongs to Nostr-style activity: profile pictures and banners, pictures attached to comments, forum posts, blog articles and circle pages, where the item's settings allow it. It is not how Arca shares files. Collections, their files, screenshots and text layers travel through Arca's own mechanism (the corpus, packing, the swarm and passes from the whitepaper). A blob on a Blossom server is never mined, never counted for marcas or stewardship, and never part of a collection.

**Limits.** A blob has a size cap (for example 5 MB by default; a circle can lower it) and must be an allowed media type: images (JPEG, PNG, WebP, AVIF, GIF), and optionally short audio or video if the circle allows. Anything larger or of another kind belongs in a collection.

**Privacy before upload.** The client strips metadata from every image before hashing and uploading it: EXIF, GPS position, camera serial numbers, editing history. Principle 9 applies to pictures as much as to network measurements.

**How it runs over I2P.** Blossom is defined over HTTP; Arca carries the same operations over I2P, reusing what `i2p-dart` already provides for content addressed by SHA-256:

- *Get* (BUD-01): fetch a blob by its hash from a server's I2P address with `fetchByB32`, or from anyone who has it with `discover`. The hash verifies the bytes, whoever served them.
- *Upload* (BUD-02): the client stores the blob locally and sends the target server a signed upload request (a kind 24242 authorization event naming the hash and size) on the control port. The server checks the author, size, type and policy, then pulls the blob from the uploader by hash. Nothing large ever travels as a message.
- *List and delete* (BUD-02): signed kind 24242 requests on the control port; a server deletes a blob when no author who uploaded it still wants it kept.
- *Mirror* (BUD-04): servers copy a blob from each other by hash.
- *Server list* (BUD-03): each profile publishes a kind 10063 event listing its Blossom servers as `i2p://<address>.b32.i2p` entries, next to its relay list (kind 10002).

**Referencing media in events.** Events point to media by hash, so any server that holds the blob can serve it. A profile picture in kind 0 and attachments in notes use a Blossom URL on one of the author's servers (`i2p://<address>.b32.i2p/<sha256>.<ext>`) plus an `imeta` tag (NIP-92) with the hash, type, size and dimensions. Clients resolve by hash first, trying the author's servers, then the circle's relays, then `discover`.

**Where media is kept.** Like notes (4.3): the author's own server always keeps what the author uploaded; the owner of the item a picture was posted on keeps it while the event that uses it is accepted; circle relays (4.5) keep and mirror the media referenced by the events they keep, within their storage budget, so pictures stay available when the author is offline. When a moderator removes an event, the pictures only it referenced are dropped from the circle's relays after a grace period.

**Moderation and abuse.** Media follows the same rules as the event it belongs to: an item that does not allow pictures makes relays refuse events with attachments; banned authors cannot upload; per-author quotas apply. Relays can filter against exact and perceptual blocklists (PDQ, as for files).

### 4.7 Collections worked on together

A collection has one **admin**, the profile that created it and signs its index, and any number of **moderators**, appointed and removed by the admin. Everyone else can read it, keep a copy and suggest changes.

- **The index.** The admin's addressable event (provisional kind 30780, `d` = collection id) lists the files (path, size, SHA-256, type, title, description, tags), the moderators as `["role", <pubkey>, "moderator", <I2P address>]` tags, and, as `["applied", <id>]` tags, the moderators' changes already folded in.
- **Changes.** An admin or moderator changes a collection with a signed change event (provisional kind 4782), tagged with the collection (`a`), the admin (`p`) and the suggestion it accepts (`e`), if any. Its content is a list of operations: `add` (path, hash, size, type, description, and who can serve the bytes), `remove` (path, hash) and `edit` (path, hash, changed fields). The collection as everyone sees it is the admin's index plus the changes by the admin and its moderators not yet folded in, replayed oldest first (`collection_index.dart`). Changes to different files merge; one aimed at a file that has changed since is skipped; changes by anyone else are ignored.
- **The admin folds** moderators' changes into its own collection as they arrive: edits and removals directly (a removed file stays on the admin's disk), new files after fetching them from the moderator into the collection's folder. It then republishes the index with the change marked applied. A new file that cannot be fetched yet holds the changes after it until it can.
- **Enforcement, twice.** The admin's relay refuses changes, and decisions on suggestions, from anyone who is neither the admin nor a moderator of that collection ("restricted: not a moderator of this collection"). Every client also ignores such changes when it replays an index, whichever relay it got them from.
- **Where changes travel.** A change goes to the admin's relay and stays in its author's relay. Followers read the admin's relay and each moderator's, so a moderator's change is visible while the admin is away. Anything that could not be delivered waits in the follow's outbox and is sent again at the next refresh.
- **Suggestions** (kind 4781) go to the admin and every moderator, and any of them decides. A moderator accepts by signing an `edit` change that names the suggestion, and both publish a kind 7 reaction (`+` or `-`, tagged with the collection). A suggestion leaves everyone's review list once someone entitled to decide has decided it, and the suggester sees the decision.
- **Keeping a copy.** A follower can keep a copy of a collection in `<default storage folder>/<collection> (<admin>)`, with each file's manifest beside it (9.4). Each refresh fetches new and changed files (5.7), and removes from the copy files the collection listed before and no longer lists. Other files in that folder are left alone. A moderator's new files are served from its copy.

Verified in `packages/arca_core/test/collaboration_test.dart` (admin, moderator, follower and outsider on an in-process network) and over the live I2P network with three nodes (`packages/arca_core/tool/live_sync_check.dart`).

## 5. Transport: I2P

### 5.1 The node

The client embeds `i2p-dart` (`../i2p-dart`, package `i2p`): a pure-Dart I2P router with NTCP2, inbound and outbound tunnels, LeaseSet2 publication and lookup, signed application messages, a content-addressed provider DHT and a piece swarm, all running in a background isolate. The app uses its `I2pService` facade:

- `ensureStarted`, `pause`, `resume`, `stop` for the node's life cycle, driven by the sharing settings (WiFi only, while charging, hours).
- `send` and `messages` for Nostr and control messages.
- `announce`, `discover`, `fetchByB32` and the swarm for file content by SHA-256.
- `addSharedDestination` so one node answers for every active profile.

There is exactly one node per device. Its router state (`stateDir`) is kept so restarts skip the reseed.

### 5.2 Ports

- **Nostr relay protocol**: one port, NIP-01 messages as described in 4.2.
- **Arca control**: catalog sync, collection head updates, pass receipts, holding proofs (later, with the chain).
- **Content**: `i2p-dart`'s own content protocol (`GET`/`DAT` by SHA-256, provider DHT, swarm) for chunks and files, and for Blossom blobs (4.6).
- **Blossom control**: upload, list, delete and mirror requests carrying kind 24242 authorization events (may share the Arca control port).

Port numbers are fixed in the protocol constants when implementation starts.

### 5.3 One address per profile

Each profile has its own I2P destination on each device, generated at profile creation and kept in its vault. The node registers every active profile's destination with `addSharedDestination`, so messages to any of them arrive at the one node, tagged with the destination they were addressed to, and the core routes them to the right profile.

Sending uses `I2pService.send(address, port, payload, fromB32: <profile address>)`, which signs the message with that profile's destination, so the receiver sees and replies to the profile's own address. (Added to `i2p-dart` for this; sending from an address the node does not answer for is refused.) The node's main identity is used only for router duties and never as any profile's address.

Known limitation: all destinations on one node share its tunnels, so their lease sets list the same gateways and an observer comparing them can tell two addresses live on one node. Until `i2p-dart` has a tunnel pool per destination, profiles on one device are separated from ordinary peers but not from a determined observer of the network database; the profile screen states this next to the timing leak (3.6).

### 5.4 Finding people again

I2P addresses are keys, stable across restarts and IP changes, so once a peer's address is known it can be reached from anywhere, whatever network it moved to.

A profile advertises where it can be reached in its NIP-65 relay list (kind 10002), with one entry per device in the form `i2p://<52 characters>.b32.i2p`. To reach a profile, a client:

1. uses the addresses it has cached for that npub;
2. otherwise asks the relays it knows (the collection owner, circle members, people it follows) for the profile's latest kind 10002;
3. for a file's or collection's owner, uses the addresses in the collection head, which the owner keeps current.

A profile's devices keep its kind 10002 up to date whenever a destination is added or removed.

### 5.5 Privacy limits

`i2p-dart` signs application messages but does not encrypt them end to end yet, so the two transit routers on a path can read them. Public Nostr events are public anyway. Anything private (direct messages, members-only catalogs and comments, pass receipts) must be encrypted above I2P with NIP-44, or sent inside a NIP-59 gift wrap. The node's current default of one-hop tunnels is a latency and reliability trade-off documented in `i2p-dart`; stronger anonymity with two-hop tunnels comes when that path is proven on the live network.

### 5.7 Files between clients

Files travel on the same addresses and link as the Nostr messages, as binary messages that can never be mistaken for one (a first byte other than `[`): `GET` (hash, offset, length), `DATA` (hash, offset, total size, bytes) and `MISS` (hash). Chunks are 24 KiB so each fits one I2P datagram (`transport/blobs.dart`).

- **Serving.** A profile serves only files it holds in its collections or its copies, looked up by SHA-256, reading just the requested chunk.
- **Fetching.**
  - Eight chunks are in flight at a time. A chunk that times out is asked for again, of another provider when there is one; a provider that answers `MISS` is dropped.
  - The download writes to `<file>.part` and remembers the chunks it has in `<file>.part.have`, so it continues where it stopped.
  - It is renamed into place only when the whole file matches its SHA-256; bytes that do not match are discarded.
- **Not yet used:** i2p-dart's swarm (`fetchByB32`, `discover`) could spread large files across many holders. It needs the node's own destination, while Arca serves from one destination per profile.

### 5.6 What the settings screen shows

There is no choice of network: I2P is always the transport. The Network section shows the node's state (starting, connected, paused by the sharing limits), the number of tunnels, and each profile's I2P address. The only network choices are the sharing limits (when the node may run) and, for always-on machines, volunteering as a circle relay (4.5).

## 6. Storage on the device

Data directory: `~/.local/share/arca` on Linux, the app's files directory on Android.

```
arca/
  device.json          device id, storage folders, active and stay-online profiles
  i2p/                 router cache and node state (stateDir)
  content/             shared content store: chunks and blobs by SHA-256
  catalogs/            downloaded circle catalogs, shared by all profiles
  media/               Blossom blobs by SHA-256 (own uploads, and media kept for others)
  previews/            video stills and hover GIFs by SHA-256 (9.1)
  subtitles/           work files of the subtitle maker and notes on files it could not do (9.3)
  models/              downloaded speech models (9.3)
  profiles/
    <profile id>/
      vault.bin        encrypted nsec and I2P destination seeds
      settings.json    this profile's settings
      events.db        this profile's relay: its events and cached events (SQLite)
      state.db         circles, followed collections, roles, hold modes, history
```

Storage folders (the base folders on each disk, chosen in Settings) hold the files of collections kept "on disk" as plain files in normal folders, and the packed copies of collections kept for sharing. They belong to the device; each profile records which folder each of its collections uses. The profile id is a random local id, not the npub, so the directory names on disk do not identify the account. The media store is shared the same way as the content store: each profile records which blobs it uploaded or keeps, and serves them only under its own address.

All database access goes through the core isolate. SQLite runs there, never on the UI isolate, and large queries are paginated.

## 7. Isolates and threads

- **UI isolate**: Flutter only.
- **Core isolate**: profiles, vaults in memory, event signing and verification, the relay and its databases, the outbox, collection and circle logic.
- **I2P isolate**: the `i2p-dart` worker.
- **Worker pool**: hashing (SHA-256, fingerprints), packing and file indexing, spawned as needed and bounded by the power settings.

The UI talks to the core through a request and response API plus state streams. Messages between isolates carry plain data, never live objects or secrets.

## 8. Main flows

**First launch.** Create device data and a profile (3.2), start the I2P node, register the profile's destination, show the home page. Nothing is published until the user acts.

**Import an account.** Paste or scan an nsec or ncryptsec, create a profile, register its destination, publish an updated kind 10002 adding this device, fetch the profile's events from reachable relays, switch to it.

**Switch profile.** Change the active profile in the UI; the core swaps which profile's state it serves. Stay-online profiles keep running.

**Comment on a file.** Build a kind 1111 event with the file's `I` tag, sign it, store it in the own relay, show it at once, and hand it to the outbox for delivery to one or two of the circle's relays and to the owner's relays; mark it as delivered when an `OK` arrives, or show it as pending. The circle relays spread it to each other.

**Read comments while the owner is offline.** Ask the circle's relays in the published order for kind 1111 events with the collection's `I` tag; show them as they arrive, verified.

**Volunteer as a circle relay.** In Settings, choose the circles and a storage budget; the client publishes its capability profile; the active relays start checking it; after a week of good attestations the daily selection may make it active, and it fills its store from the other relays and starts serving.

**Like and share a file.** Publish a kind 17 reaction with the file's `i` tag, add the file to the profile's shared items, fetch it if needed, announce it on the provider DHT under the profile's destination.

**Moderate.** An admin changes a setting or bans someone; the client publishes the kind 30078 settings or the circle ban list, and its relay applies them at once to what it serves.

**Delete a profile.** Stop its destination, delete its vault, settings and databases, and remove its references to shared folders and content (content still used by other profiles stays). Optionally publish kind 5 deletions for its events first.

## 9. Media on the device

Everything here runs on the device, from the files themselves; nothing is sent anywhere.

### 9.1 Previews

For each video the core makes a still frame (a tenth of the way in) and an animated GIF of ten frames from across the clip, shown when the pointer rests on a thumbnail. They are made with ffmpeg in a separate process and stored by the file's SHA-256 in `previews/`, so every collection holding the same clip shares them.

### 9.2 Playback

Video and audio play through libmpv (`media_kit`). Android bundles it in the APK; the Linux bundle carries libmpv, ffmpeg and ffprobe with the libraries they need (`app/linux/packaging/bundle_media.sh`, run by the CMake install step), so nothing has to be installed on the system. Subtitles made on the device (9.3) are loaded as a subtitle track. On Linux, mpv renders into a GPU texture shared with Flutter through a patched copy of media_kit_video (`third_party/media_kit_video/ARCA.md`); without it, current Flutter made media_kit fall back to drawing every frame on the CPU. A click on the picture plays or pauses; the page starts playback when it opens.

### 9.3 Subtitles

Subtitles are made from the speech in videos and audio with whisper.cpp, built from the `third_party/whisper.cpp` submodule into `libarca_whisper.so` behind a small C interface (`native/arca_whisper`), for Linux by the app's CMake build and for Android by Gradle's CMake build.

- **Decoding.** The audio track is decoded to 16 kHz mono WAV through libmpv, which the app already carries, so the same code works on Android, where there is no ffmpeg.
- **Threads.** Decoding and recognition block their thread for minutes, so they run on a worker isolate the core spawns per file; the core reads progress from shared native memory and can stop the job. One file at a time, with half of the processors on a computer and at most four on a phone.
- **Models.** Not part of the app. The user downloads one from Settings; the app recommends the one that fits the device: Tiny (31 MB) for phones under 6 GB of memory, Base (57 MB) for other phones, Small (181 MB) for computers under 7 GB, and Large turbo (547 MB) for the rest. Models are quantized ggml files, unchanged copies of `ggerganov/whisper.cpp` on Hugging Face, published as assets of the `models-v1` release of `github.com/x1watt/arca`. Downloads continue where they stopped and are checked against the SHA-256 the app carries; a file that does not match is discarded. Stored in `models/`.
- **Automatic.** With a model chosen and automatic subtitles on (the default), every video and audio file of the active profile's collections is queued when the app opens and when files are added. The user can make them again for a file (for example after switching to a better model) or stop the running job. A file that cannot be done (no sound, unreadable) is marked and skipped until asked for by hand.
- **Layout.** Whisper's word timings (DTW alignment heads, so words land where they are spoken) are grouped into cues the way subtitles are written: at most two lines of about 42 characters, balanced and broken after punctuation where possible, a new cue at the end of a sentence or at a pause, no cue longer than seven seconds or shorter than one.
- **Format.** SubRip (`.srt`), which every player, editor and platform reads.
- **Storage.** Beside the file, as `<name>.<language>.srt` (9.4), in every collection holding the same bytes, and recorded in the file's manifest as a machine-made layer with the tool and model that made it. Subtitles that came with the file (made by a person or another program) are never overwritten; a file that already has any is skipped by the automatic pass. Making them again replaces only the machine-made ones.
- **Display.** In the player, like film and television subtitles: white semi-bold text with a thin black outline and a soft shadow, no box, near the bottom, at about 5% of the picture height at any player size.

### 9.4 Files beside each file

A collection is an ordinary folder, and everything Arca knows about a file is written next to it, named after it, so the folder can be copied, backed up or opened by other programs without losing anything:

```
Talk.webm              the file
Talk.arca.json         its manifest
Talk.en.srt            subtitles, one file per language
```

- **Names.** The file's name without its extension, then the sidecar's own suffix, which is what video players expect for subtitles (mpv, VLC, Kodi and Jellyfin load `Talk.en.srt` for `Talk.webm` by themselves). When two files in a folder differ only by extension (`Song.mp3`, `Song.flac`) each keeps its full name instead: `Song.mp3.arca.json`.
- **Manifest.** `<name>.arca.json`, readable JSON: format version (`arca-manifest/1`), file name, size, SHA-256, SHA-1, detected type, title, description, tags, date added, and the text layers beside it (file, language, origin, and for machine-made ones the tool, model and date). It is the local form of the manifest in the whitepaper; signing it and publishing it to the circle come with sharing.
- **Written** whenever the library changes a file: when it is added, edited, when a suggestion is accepted, and when subtitles are made. Through a temporary file and a rename, so a copy taken at any moment never holds half of one.
- **Read** when a folder becomes a collection or a file is added: a manifest that matches the file's SHA-256 gives back its title, description, tags and layers, so a collection copied elsewhere and adopted again comes back as it was. A manifest for other bytes is ignored.
- **Carried along.** Adding a file copies its manifest and subtitles with it, renamed with it when the name changes. Removing a file from disk removes its sidecars. Scanning a folder does not list sidecars as files of their own; a `.srt` with no file of the same name beside it is an ordinary file.
- `collections.json` in the profile stays the fast index of the library; the files beside the files are what travels.

The model download is the one connection that does not go over I2P: a plain HTTPS download from GitHub, started by the user, carrying no profile key or address. It reveals to GitHub that this IP downloaded a speech model, nothing about the profile.

## 10. Open questions

- Exact Arca event kinds and their tags (collection head, catalog announcements, circle log entries).
- Port numbers and the control protocol's message set.
- A tunnel pool per destination in `i2p-dart` (5.3), and end-to-end encryption at the I2P layer.
- Event kinds for capability profiles, attestations and the computed relay list; the exact selection formula, how many relays per circle size, and how often volunteers are checked.
- How long relays keep cached events of others, and how storage budgets are split between events and files.
- Whether moderation follows NIP-72 as is, or an Arca variant aligned with the whitepaper's circle governance.
- Multi-device conflict rules for per-profile settings that are not published as events.
- Blossom over I2P: exact request format on the control port, default size cap and media types, and how long media of removed events is kept.
