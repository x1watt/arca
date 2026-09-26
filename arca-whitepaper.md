# Arca: Proof of Keeping

Arca is a shared library of files that people everywhere build together, the way Wikipedia is built for articles. Anyone can add files, anyone can search them, and the people who keep them safe are paid for it in one coin, the marca. Communities called circles curate their own collections; one global blockchain, with fixed rules and no owner, pays them for keeping what others want kept.

Sep 24, 2026, @Brito

## 1. The idea

Wikipedia showed that people everywhere will build a shared body of knowledge when the tools let them. Files have no equivalent. Radio archives, maps, books, recordings, manuals, family photos and community records live on single servers and personal drives, and they vanish when one person stops paying or one service shuts down.

Arca gives files what Wikipedia gave articles.

- One place to add them. Anyone joins a circle and proposes files for its collections. Contributing is free.
- One way to find them. Every circle publishes a catalog and a search index that anyone can verify by recomputing a sample.
- Many hands keeping them. People follow the collections they care about, keep a copy on their own disks, and are paid in marcas for keeping what other people also keep and read.

The money comes from mining, in the style of Proof of Capacity (Signum) and Arweave: disk space is the mining input. Arca points that disk at the library itself. Mining power is keeping of files people chose to keep, so the more meaningful data people keep, the stronger the network.

## 2. Who does what

A reader browses, searches and downloads. They need no account and no coins. Every circle gives them a free daily allowance, and they can buy a 24-hour pass for more.

A contributor proposes files, folders and descriptions to a collection. Contributing costs nothing, and the chain pays contributors nothing directly; a circle may pay them from its own pool.

A keeper keeps collections on disk, proves it every day, and serves downloads. Keepers earn marcas from the global chain through their circle's pool, get free access to everything they keep, and receive pass revenue for the bytes they serve.

A moderator reviews proposals, admits members, and signs the circle's index and log. Moderators receive a share of the pool if the circle's policy says so.

A circle is a community with its own collections, rules, log and pool. It earns marcas through its members' keeping and shares them by its own payout policy. It also earns trust, which is shown in search results.

The global chain is the one blockchain. It issues marcas, records who keeps what, pays the pools and sells passes. It has no owner, no admin, no moderators and no servers of its own.

The flow in one breath: a contributor proposes a file for free; moderators accept it into a collection; keepers follow the collection and keep it on disk; their daily proofs go to the global chain; the chain pays marcas to the circle's pool; the circle shares the pool by its policy; readers download from the keepers, free within the allowance or with a pass.

## 3. Principles

1. Bytes are bytes. The network cannot tell a treasure from junk. People decide what matters, inside circles; the chain only measures who keeps what and who pays to read it.
2. Contributing is free. Nobody pays to add files. Review, member quotas and trust decide what gets in, never who can afford it.
3. Nothing is forced on anyone. No node must hold any file, any catalog or any index it did not choose. The global chain holds no entry per file.
4. Every copy is unique to its keeper. Packing makes the bytes on disk differ per keeper, so one disk cannot pretend to be a hundred.
5. Mining power is bytes kept, not disk speed. A global clock limits proofs, so faster hardware gains nothing.
6. Pay for interest, not for supply. Bytes alone earn little. Data earns when people outside its own circle keep it or pay to read it.
7. Free activity never counts. Free downloads, searches, clicks and request counts feed no reward and no ranking, because they cost nothing to fake.
8. One money, fixed rules. Only the global chain creates marcas, under rules no participant can change. Circles curate and share rewards; they never mint and never govern the chain.
9. Nothing that maps a node to a place or a time is published. Latency and throughput stay on the client that measured them.

## 4. Circles

A circle is a community: members, moderators, collections, rules. Everyone who contributes or keeps files does it through at least one circle, so every file in the library has passed some community's curation. There is no solo mining and no solo sharing.

**Creating a circle** burns a fixed fee in marcas, roughly what a keeper earns in a month of keeping one partition. Nobody starts with marcas, so a founder first keeps files in an existing circle, earns with patience, and then opens their own. This keeps fake circles expensive and gives every founder a track record. The genesis circles (Wikipedia, OpenStreetMap, Project Gutenberg) are open to all, so there is always somewhere to start.

**Governance.** Seven rules, and nothing else.

1. Whoever creates a circle is its admin.
2. The admin appoints moderators and sets the policy. Nothing else.
3. Moderators admit and exclude members, with as many approvals as the policy requires.
4. Moderators are the indexers: only index shards signed by a moderator count as the circle's index. What no moderator will index is unsearchable there, which is what moderation means in practice.
5. Moderators accept or reject files, collections and edits, and may appoint maintainers for a single collection.
6. A majority of moderators can replace the admin or remove a moderator. The admin cannot remove moderators.
7. Policy may change at any time. With no admin and no moderators, the circle freezes as it stands.

**Policy.** The admin sets how open the circle is along four dials.

- Joining: from anyone joins by publishing a key, to newcomers request admission and wait for approval.
- Publishing: from members' files enter at once, to files wait in a review queue until accepted.
- Visibility: from anyone can browse, search and download, to members only, where outsiders see at most a collection's name.
- Approvals: from one moderator, to any number up to all moderators.

The policy also sets member quotas (bytes contributed per day, proposals open at once), the free reading allowance, the pass price and whether passes are sold, the sync score needed for free member access, the payout policy of the pool, and what happens when the circle is cut off from the global chain.

Typical settings: a public commons is open on every dial; a community archive is open to join but reviews what is published; a club library admits by request, reviews with two approvals, and is visible to members only; a family archive admits by invitation, lets members publish freely, and is visible to members only.

**Review queue.** A proposed file is announced by hash and served by its contributor while it waits. It is not yet part of anything: not mined, not indexed, not in a collection. Waiting costs nobody anything; quotas limit how much one member can have waiting. Once approved it enters the circle's public data and the index.

**Closed collections** are closed by access, never by encryption. Files stay plain bytes and belong to whoever holds them. The circle serves a closed collection only to members, and its data never enters the global corpus and never earns marcas, because proving it on the global chain would publish slices of it. Members can still pay and be paid in marcas. Excluding a member ends their access from then on; what they already copied stays theirs. The same files may be open in another circle; the protocol does not try to prevent it.

**Circle log and anchors.** A circle's records (members, policy, collections, review queue, quota use) live in its own log: an append-only chain of entries signed by its moderators. It carries no money and needs no mining, so it is cheap on a phone and keeps working offline. About once an hour a moderator posts an anchor to the global chain: a hash of the log head, a hash of the circle's public data, the member list root, the catalog sizes and the payout table, about 1 KB. Anchors are how the global chain knows what a circle keeps, how it pays the circle, and how the circle's history is pinned so moderators cannot rewrite what they already anchored.

**Disconnected circles.** A circle that cannot reach the global chain keeps its library: log, collections, review and search work among whoever can still reach each other. It loses its money: after a time the admin sets (for example 6 hours), no passes are sold, passes already bought stay valid until they expire, and the pool earns nothing. Access falls back to the admin's choice: free for everyone, or members only. On reconnection the circle anchors again and earns from then on.

**Forking is the real check.** Chunks are content-addressed and packing is keyed to the keeper, not the circle. Members who dislike their moderators take their packed disks, start a new log with a new membership, pay the circle fee, and are earning for the new pool the same day. No governance can extract more than the cost of that fork.

## 5. Collections

A collection is a tree of folders and files that a circle builds together: "Portuguese radio archive", "Maps of the Azores", "Club manuals 1970 to 1990".

**Structure.** A content-addressed tree, like a git repository: folders are small objects listing subfolders and files by name, each file with its content hash and description. A version is a signed commit: root hash, parent version, the proposal it accepted, the accepting signatures. The circle log holds only the current version; history lives in the corpus as ordinary data.

**Editing, like Wikipedia.** A change is a proposal against a base version: add files, make, rename or move folders, remove entries, improve a description. Moderators or the collection's maintainers accept it by signing a new version, or reject it. Changes to different paths merge automatically; changes to the same path make the contributor rebase. Any earlier version can be restored in one signed step, and a history view shows who proposed and who accepted every change.

Each collection has one of three roles. Open: any member proposes, moderators or maintainers accept. Curated: only maintainers propose, other maintainers or moderators accept. Personal: the owner edits directly, with no review.

**Following.** A client follows a collection by watching its version in the circle log and fetching only what changed. A follower keeps it in one of two ways, and the default is both: as a mirror, plain files in a local folder kept in sync for everyday use, offline included; and as a keeper, a packed copy that can be proven daily, which earns marcas and keeps the collection safe. Removed files leave a mirror only if the follower chooses.

**Across circles.** A collection may include files held in another circle, and anyone can copy a collection into their own circle with its full history. A circle's collection is what the circle curates, not what it owns.

## 6. The global chain

The global chain is the one blockchain, run together by the machines of every circle. Circles are expected to contribute nodes and miners; that is what earns their pool a share.

**Fixed rules, no owner.** Issuance schedule, budgets, burn share, the standing formula, the replication target, the circle fee and the content hash format are protocol constants. Metadata extraction and indexing tools are not: anyone may improve them (see Search). No participant, circle or group of circles can vote to change them or exclude anyone. A rule changes only if node operators each choose to run new software, and anyone who disagrees keeps running the old rules. No faction can take over the network or push another out.

**No curation.** The global chain holds no collections and judges no file. Curation is subjective, so it lives only in circles, where moderators answer to their own members and their power ends at their circle's border.

**State only.** The chain keeps no long-term transaction history. A block carries its transactions; full nodes apply them, keep them for a 24-hour challenge window, and discard them. The header commits to the transactions, the resulting state, the corpus root and the circle anchors.

**Phones are full participants.** A phone does not re-execute blocks. If a block commits a wrong state, any full node publishes a fraud proof (the bad transaction plus small Merkle witnesses) within the window, and every phone rejects that block and its descendants. Finality for a phone needs one honest full node, not an honest majority. A new node syncs from a recent state snapshot plus headers, never from genesis.

**Small by design.** State holds balances, circle anchors, standing, pool accounts, open passes, declared holdings and the live bitmaps (one bit per 256 KB chunk, about 5 GB per 10 PB of data). Nothing is stored per file. Headers grow about 1.5 GB a year and prune to checkpoints. A full node for a library of petabytes fits on a small SSD.

## 7. Proof of Keeping

**Corpus.** Accepted files are split into 256 KB chunks and appended to one global content-addressed corpus with a single Merkle root. The same chunk in a hundred circles is one chunk. Only live chunks are mineable: those in the current version of a public collection of a circle whose anchor is under 24 hours old. Removed data stays live for a 30-day grace period so a revert loses nothing, then may be deleted.

**Partitions.** The corpus is cut into partitions of 32 to 64 GB. A keeper declares which partitions they keep. A phone with 128 GB free keeps two.

**Packing.** A keeper stores each chunk XOR a memory-hard function (such as RandomX) of their own key and the chunk position. Packing costs 1,000 to 10,000 times more than reading, so it is cheaper to keep a real disk than to regenerate or fetch data on demand, and no disk can answer for another keeper's copy. Keepers who serve files keep an optional unpacked copy.

**Clock-limited mining.** A hash chain ticks once a second and names random chunks and 1 KB slices in every partition. Keepers read the named slices from their packed copies and hash them against the block signature; the lowest result wins the block, as in Signum. A faster disk gains nothing; only more partitions gain. A Raspberry Pi with used hard disks competes. Steady-state energy is disk reads plus an idle CPU.

**Daily holding proofs.** Each day the clock names one random chunk in each keeper's declared partitions, and the keeper posts a 2 KB proof: the slice, its Merkle paths, and the packing. A missed or wrong proof drops all of that keeper's declarations and resets their scores, so claiming a partition you do not hold is caught within days and costs everything built up. Declared partitions are therefore a true count of copies.

**Proof size.** One 1 KB slice, 8 hashes inside the chunk, about 22 hashes to the corpus root, and the packing proof: about 2 KB. A block header is about 3 KB.

**Genesis.** An empty library has nothing to mine. The first blocks hash in public-domain corpora (Wikipedia, OpenStreetMap, Project Gutenberg) as the public collections of the first circles.

## 8. Marcas: how the money works

One coin, the marca (plural marcas, short for Money Arca). Only the global chain creates it, on a fixed schedule that decays over the years to a small permanent rate. Issuance does not grow with the amount of data, so accepting junk never creates marcas; it only dilutes everyone's share, including the share of whoever accepted it.

**Two budgets.** Each day's issuance is split in two. The storage budget, 30%, pays for bytes kept, per partition and deduplicated; it covers the cost of keeping data at all, including large archives few people read. The interest budget, 70%, pays for collections that people outside their own circle keep or pay to read, regardless of size; it rewards what the wider library actually wants.

**The replication curve.** For each partition and each collection, the reward is shared among its keepers on a curve with a target of 10 copies. A single copy earns little: it is fragile, and its keeper wants company. From the second copy to the tenth, the reward per copy rises with each new keeper. From the eleventh on, the total is frozen at ten keepers' worth and split among all, so every extra copy takes a slice from everyone. The incentive is to be one of the first ten keepers of something worth keeping, and to leave over-replicated data to others.

**Interest and standing.** The interest of a collection comes from three sources only: a fixed seed for the genesis corpora; marcas burned reading it over the last 30 days by people who are not members of its circle; and one third of the standing of keepers from outside its circle who keep it, each divided by the number of collections they keep.

A keeper's standing is the sum of their shares of the interest of the collections they keep, following the replication curve, recomputed once a day. Standing flows outward: from public-domain data and paid reading, through the people who keep them, to whatever those people also keep. The interest budget is paid to keepers in proportion to standing.

Two consequences. A circle whose members keep only their own archive and nothing else earns storage but no interest; to earn interest, others must be interested, or the members must also keep what others keep. And because only one third of standing passes on, nobody can lift their income above 1.5 times what their keeping of others' data earns, however much junk or how many keys they add.

**Books versus video.** Circle A curates 100 books, 100 MB. Circle B curates one video, 1 TB. In a library of 10 PB with equal interest in both, A's keepers and B's keepers earn about the same: B a little more from the storage budget, having spent 10,000 times the disk for it. Per byte, A is paid thousands of times better. Nobody keeps the video for the money; they keep it because members want it. If the video is genuinely wanted, its interest rises and its keepers are paid for that.

**Pools and payout.** Every proof names the circle it is made for, and the keeper's earnings go to that circle's pool. The admin sets a payout policy, published in every anchor as a table of member shares; members claim from the global chain with a Merkle proof. A suggested default is 45% to keepers by sync score, 45% to contributors by how much their accepted files are kept and read, and 10% to moderators and indexers. Any split is allowed. Payouts are public, so a circle that treats members badly loses them to another circle or to a fork, as with mining pools.

**What is free and what is paid.** New marcas go to circle pools by proven keeping, through the storage and interest budgets. Pools pay their members by the circle's policy. Readers beyond the free allowance pay for a pass: half is burned and half goes to the servers in proportion to bytes delivered. A founder burns the circle creation fee. Contributing, reviewing, the free allowance and member access cost nothing.

**Why burning.** Half of every pass is burned, so buying passes on your own files to look popular always loses half, and the burned marcas benefit every holder. Burns are also the one popularity signal nobody can fake for free.

**Trust.** Every circle has a trust score on the global chain, computed by fixed rules from its interest, its age and the correctness of its index (shards proven wrong by resampling lower it). Trust changes nothing in issuance; it is shown beside every search result and decides which circles clients subscribe to by default. Good curation earns visibility.

## 9. Reading and serving

Everyone can read, in three ways, with limits set by each circle's admin. The free allowance is for anyone, member or not, at no cost: for example 1 GB a day per reader at limited speed. A 24-hour pass is for anyone who wants more, at a price in marcas set by the admin and bought on the global chain. Member access is free for members whose sync score reaches the admin's threshold, because they keep the circle's files and are its redundancy.

**Free allowance.** Each server counts it per reader key and also caps the total bandwidth it gives to free readers, so making many keys only competes for that share.

**Passes.** While a pass is active the reader signs a running total of bytes for each server. When the pass ends, each server submits its latest total once, and the chain splits the price: half burned, half to servers by bytes delivered. One transaction to buy, one per server to settle, however many chunks moved.

**Sync score.** Per circle, per member: the bytes of the circle's data a member proves they keep, weighted toward rare data, with extra weight for whole collections, decaying so it reflects what they keep now. It is proven, never claimed. It grants member access, sets serving priority (members by score, then pass holders, then free readers), and decides who receives new files first when a collection grows.

**Serving settings.** Each app decides how much it gives, and none of this ever leaves the device: upload speed cap, daily and monthly volume, WiFi or Ethernet only, only while charging, hours of the day, storage limit, and the share of upload given to free readers. The sync score depends on what a member keeps, not on how much they serve, so a phone that serves only on WiFi while charging still has full member access. Serving more earns pass revenue.

**Over I2P and other transports.** Low latency is rewarded by pass revenue following bytes delivered and by the client choosing whom to download from: it opens sessions to several keepers, requests chunks in parallel, keeps a private performance table per peer, shifts requests to whoever delivers, and hedges slow chunks. Nothing about latency is ever published, because published timings would let attackers locate servers. I2P is the privacy floor; clearnet, mesh and LAN transports plug into the same client loop, and each server chooses its own tunnel length as a trade between anonymity and income. Details in Appendix D.

## 10. Search

**Manifests.** Every file carries a signed description. A few fields are required: content hash, SHA-256, size, detected type, recommended file name, namespace, format version and signer. Others are optional and computed from the bytes by a tool the manifest names: media properties, archive listings, thumbnails, and fingerprints for similarity search. The rest are optional and declared by people: title, descriptions and translations, category, tags, languages, creators, date, places, license, source identifiers, screenshots, relations to other files and content notes. Anyone may publish a better description of any file, and the collection pins the one its moderators accepted. The full list is in Appendix A.

**Text layers.** Extracted text, OCR, subtitles per language, transcripts, chapters, lyrics and image descriptions are separate files linked from the manifest, each marked as computed, human or machine-made. They are what make a PDF, a film or a radio recording searchable by what is inside it, and a hit opens the file at the right page or second. Details in Appendix B.

**Open, improvable tools.** No extraction or indexing tool is imposed by the protocol. Text extractors, media decoders, fingerprinters, OCR engines and tokenizers are ordinary software that anyone may write or improve, including third parties. Every computed field in a manifest names the tool and version that produced it. When a better tool appears, anyone may publish a new manifest or a new index shard made with it, beside the old ones; nothing forces anyone else to switch, and nothing has to be re-indexed at once. Collections pin the manifests their moderators accept, clients prefer whichever tools they trust, and better metadata spreads file by file, voluntarily.

**Verifiable when reproducible.** A tool published as WASM in the corpus is deterministic, so anyone can re-run it on a file and check a field or a shard produced with it; a mismatch flags that shard or manifest and lowers the circle's trust. Tools that cannot be reproduced bit for bit, such as many OCR engines and machine-learning models, are still welcome: their output is labelled with the tool and vouched for by its signer, and clients weigh it accordingly. Moderators publish their circle's inverted-index shards into the corpus as ordinary files, each declaring the tools it was built with.

**Catalog, sized for a disk.** Each circle publishes three layers, and every anchor reports their sizes. The catalog holds the collection trees and a compact record of at most 4 KB per file, about 3 GB per million files. The full-text layer holds the index shards over text layers and descriptions, 5 to 20 GB per million files. The preview layer holds thumbnails and screenshots, 20 to 100 GB per million files.

The catalog of a billion public files is about 3 TB, so the whole library's catalog fits on one 4 TB disk beside a full node. Users take the catalog of every circle or only of the circles they care about, full text for some, previews for those they browse; search runs locally over what is held and asks gateways for the rest, marked as remote.

**Protection against garbage.** Nothing per file is on the chain, and nobody takes a circle's catalog unless they subscribe. Manifests are corpus chunks, so publishing a catalog means keeping it, packed and proven daily, and a circle's catalog may be at most 1% of the public bytes its keepers keep. A saboteur who wants to publish 300 TB of junk records must first keep 30 PB, and even then only subscribers carry it. Clients subscribe by default only to circles above a trust threshold and show the disk cost before subscribing.

**Ranking** never enters consensus. Clients mix signals with known faking costs: copies kept (availability), age, burns per byte (money spent), trust of the circles that include the file, and pins from keys in the user's own web of trust. Curators publish weightings and lists the way they publish collections.

## 11. Abuse and defences

Junk in your own circle earns storage only, at the lowest point of the curve, and no interest, because interest needs keepers from other circles or paying readers.

Hundreds of circles with the same files gain nothing: the same chunks are one partition, copies beyond ten earn less each, and every circle costs a burned fee.

Variations and subsets gain nothing: subsets are the same chunks, and variants nobody else keeps earn like junk.

Fake searches, free downloads and clicks never count for anything.

Buying passes on your own files loses half to burning every time, and interest from burns can never return more than half.

Thousands of keys are worthless: a key with no proven keeping has no standing, and keys aged in advance have none unless they kept valued data the whole time.

Two circles endorsing each other are capped: only one third of standing passes per hop, total gain is at most 1.5 times honest earnings, and each circle cost a fee.

Claiming partitions you do not keep is caught by the daily random proof on a uniquely packed copy; one failure drops everything.

Faking copies from one disk fails because packing is per keeper and costs 1,000 to 10,000 times more than reading.

Fetching proofs from the cloud loses the race: reads are clock-limited and random, and a local disk beats the network by orders of magnitude.

Billions of garbage files stress only their author: there is no per-file state, catalogs are per circle and opt-in, a catalog is capped at 1% of bytes kept, and the manifests must themselves be kept.

A wrong index is caught by anyone who resamples it with the tools it declares, and the circle's trust falls.

Moderators rewriting history are exposed, because anchored log heads cannot change unnoticed, and members fork.

An unfair pool payout is visible to everyone, and members leave.

A faction cannot change global rules: there is no admin and no vote, and rules change only when operators each choose new software.

A wrong state in a block is undone by a fraud proof within 24 hours; one honest full node is enough.

Locating servers by timing is impossible, because no timing data ever leaves the measuring client.

Illegal content is refused by keepers, who lose only those tickets, rejected by moderators, and filtered by front-ends with exact and perceptual blocklists.

## 12. Open problems and first prototype

**Numbers to test.** The 30/70 split, the one-third pass-on, the target of 10 copies, the 1% catalog cap, the 24-hour window and the circle fee are starting points chosen by reasoning, not measurement.

**Open problems.**

- Sybil-resistant demand: interest from outside keepers and burns is the honest fallback; a way to reward what people read without paying would be better.
- Reproducible versus better: deterministic WASM tools can be checked by anyone, while stronger OCR and machine-learning tools often cannot be reproduced bit for bit. Clients must learn to weigh verified fields against better but vouched-for ones.
- Query cost: intersecting common terms over a DHT does not scale; gateways are needed from day one, and their centralisation must be managed.
- Pool payouts at scale: a pool with a million members needs batched claims.
- Global partitions: a long split of the internet forks the money chain; circles in regions often cut off depend on disconnected mode.
- Member privacy: serving only to members tells the server which key asked; an anonymous membership proof would fix it.
- Packing asymmetry: cheap unpacking with expensive packing would let keepers serve straight from packed copies.

**Suggested order.**

1. Indexing code in WASM (SHA-256, TLSH, PDQ, MinHash, text extraction) over Gutenberg and a public image set, with independent recomputation checks.
2. Manifests, catalog records and collection trees; a follower that mirrors a collection to a folder.
3. Packing benchmark on commodity hardware.
4. Clock-limited mining, daily holding proofs, live bitmaps, state-only headers and fraud proofs.
5. Circle logs, anchors, review queue, policy dials, circle fee.
6. Standing, the replication curve, the two budgets, pool payouts.
7. Free allowance, passes, sync score, serving settings; client loop over I2P.
8. Per-circle catalog layers with size reporting and local search.

## 13. Naming

Arca is Latin and Portuguese for a chest or ark, the root of "archive": a chest each circle keeps, and the ark that carries things across a partition. Marca is short for Money Arca, and also Portuguese for a mark: the mark a circle earns by keeping the library well. The consensus is Proof of Keeping, because the input is not raw space or time but the keeping of data someone chose to keep.

Parts: corpus (all the data), chunk (256 KB of it), partition (32 to 64 GB of it), circle (a community), collection (a tree of folders and files), manifest (a file's description), proposal (a suggested edit), keeper (someone who keeps and proves), moderator (someone who reviews and indexes), circle log (a circle's record), anchor (its hourly checkpoint on the global chain), pool (a circle's earnings), standing (a keeper's earned weight), interest (what the wider library wants), pass (24 hours of full-speed reading), sync score (how much of a circle a member keeps), shard (an index file), trust (a circle's public standing in search). Plain nouns that survive translation.

## Appendix A. Manifest fields

A manifest is a small signed record, at most 64 KB. Its searchable part, the catalog record, is at most 4 KB. Anything larger, such as a screenshot, is referenced by hash. Only the fields marked required must be present; everything else is optional and may be added later, in a new manifest, by anyone.

**Header, all required.** The manifest format version, so the format can evolve. For each computed field, the tool and version that produced it, with the tool's hash when it is published as WASM in the corpus. The signer's key and signature; the signer vouches for the description and need not be the contributor. Optionally, the hash of an earlier manifest by the same signer that this one replaces.

**Computed from the bytes, verifiable when the tool is reproducible.** Required: the content hash (the Merkle root the corpus uses), the SHA-256 of the whole file (so exact matches work against outside sources that only know plain file hashes), the size in bytes, and the type detected from the content rather than the extension. Optional: fingerprints for similarity search (Appendix C); media properties such as width and height, duration, page count, codecs, bitrate, sample rate, text encoding and detected language; an archive listing for ZIP, TAR and similar, with the names, sizes and SHA-256 of the files inside, so contents are searchable without unpacking; and a thumbnail rendered by a named tool (an image scaled down, a PDF's first page, a video frame), stored as its own corpus file.

**Declared by people.** Two are required: the recommended file name, with an extension that fits the detected type, and the namespace, a contributor-declared prefix such as radio/ or maps/pt/. The rest are optional:

- Title, which defaults to the file name, and the original file name where it was found, if different.
- A short description of one or two sentences for search results, and a long description in plain text with light formatting: contents, context, how to use it.
- Translations of the title and descriptions, each tagged with a BCP 47 language code.
- Category, one value from a small shared list (document, book, image, audio, video, software, dataset, map, font, archive, other), which a circle may extend.
- Tags, up to 32, lowercase, singular, words joined by hyphens, such as nvis or dipole-antenna.
- Languages of the content, as BCP 47 codes.
- Creators, people or organisations with a role: author, photographer, composer, performer, editor, translator, publisher.
- Date of creation or publication: a year, a month or a full ISO 8601 date.
- Version or edition, for software, documents and books that change over time.
- Places the content is about, by name, with optional coordinates or a bounding box.
- License, as an SPDX identifier where one fits, otherwise a short text or a reference to a license file.
- Source: the original URL, archive or library, and external identifiers such as ISBN, DOI, ISRC or a catalogue number.
- Screenshots, up to 8, referenced by content hash, each with a caption and a kind (screenshot, cover, page, frame, waveform, map extent); PNG, JPEG or WebP, each at most 1 MB.
- Relations to other files by content hash: new version of, part of, translation of, derived from, same content as, companion of.
- Text layers, referenced by hash (Appendix B).
- Type-specific fields, small key-value sets per category: operating system and architecture for software, scale and projection for maps, frequency and mode for radio recordings.
- Content notes that help people filter, such as graphic or adult content.

**File name rules.** A recommended file name must work on every common operating system: valid UTF-8 in NFC form, at most 255 bytes, no control characters, none of the characters slash, backslash, colon, asterisk, question mark, double quote, less than, greater than or vertical bar, no leading or trailing space or dot, and not a reserved name such as CON or NUL. Clients may still rename on save; the recommendation is what search results show and what a mirror writes to disk.

**Screenshots and thumbnails** are ordinary corpus files, contributed with the file and kept for as long as it is. They matter most where the bytes do not explain themselves: software, games, maps, datasets and scanned documents.

**What gets indexed.** File name, title, descriptions and translations, tags, creators, places, source identifiers, the archive listing and every text layer are indexed as terms, prefixed by field, so a search can ask for tag:dipole-antenna, creator: followed by a name, or transcript: followed by a phrase. Terms from text layers keep their page or time code. Category, languages, date, license, size and media properties become filters rather than search words.

## Appendix B. Text layers

Much of what makes a file findable is text that sits inside it or that people add later: the words in a PDF, the dialogue in a film, the speech in a radio recording. Each such text is a layer: a separate corpus file referenced from the manifest by content hash, so the manifest stays small and a file can gain layers over the years without being contributed again.

The layers are: extracted text from PDFs with a text layer, EPUB, Office documents, HTML and plain text, as UTF-8 with page or section markers; an outline, the headings of a document with page or section references; OCR text for scanned PDFs and images of text, with page markers and optional word positions; subtitles for video, in WebVTT, one layer per language; captions, subtitles that also describe sounds, for viewers who cannot hear the audio; transcripts of audio and video, time-coded, with optional speaker names; chapters, start times or pages with titles; lyrics, plain or time-coded; image descriptions per language, also used as alternative text; and translations of any other layer, in the same format as the layer they translate.

Extracted text, outlines and OCR are computed by tools the layer names; when the tool is a published WASM build they are verifiable like the index. Anyone may publish a better extraction of the same file with a newer or different tool, beside the old one. Everything else is contributed by people or generated by tools.

Every layer carries a small header: its kind, its language as a BCP 47 code, the content hash of the file it belongs to, the layer it translates if any, and how it was made: computed by a named tool, written by a person, or generated by a machine, with the tool's name and version. A machine transcript is useful but can be wrong, and saying so lets clients rank human layers first and lets people replace machine layers with corrected ones.

Contributed layers follow the collection's edit rules: adding subtitles or a corrected transcript is a proposal that moderators or maintainers accept like any other edit. Several layers of the same kind may exist for one file, such as subtitles in ten languages or two competing transcripts, and the collection pins which ones it accepted. Adding a layer costs nothing, and a layer is kept for as long as its file.

Time codes are kept in the index, so a search hit in a transcript or subtitle can open the recording at that moment, and a hit in extracted text can open a PDF at that page.

## Appendix C. Fingerprints and similarity

Besides words, a file can carry fingerprints that find exact copies and similar files whatever their format. SHA-256 is required on every file. All others are optional, added when the file qualifies and the contributor or an indexer chooses to compute them. A fingerprint names the tool that computed it and, when that tool is reproducible, must match what anyone else gets from it; a missing one only means that file is left out of that kind of similarity search.

SHA-256 finds the exact same file. It works on any input, and two files match or they do not.

TLSH finds files with similar bytes: edited documents, patched binaries, re-saved archives. It needs at least 50 bytes with enough variety, and is otherwise left empty. Its distance score is lower the closer two files are. It was chosen over ssdeep, sdhash and LZJD because its digest has a fixed size and a real distance, so it can be indexed; the last two can be more precise but produce large, variable digests.

PDQ finds the same image in any format, resolution or compression, including rotated or flipped copies. It works on decoded pixels scaled to a fixed size, which is what makes it independent of format and resolution, and it needs a decodable image with a PDQ quality score of 50 or more. Distance is a Hamming distance over 256 bits.

TMK+PDQF finds the same video re-encoded, resized or in another container, from a few seconds of decodable video.

Chromaprint finds the same recording in any audio format or bitrate, from a few seconds of decodable audio; it is a good fit for radio archives.

MinHash over extracted text finds the same text in different files, such as a PDF and an EPUB of one book, once there is enough text for a few dozen shingles.

When a fingerprint tool bundles its own decoders as WASM, every verifier gets the same pixels, samples and text, and therefore the same fingerprint.

**Indexing similarity.** Fingerprints are split into bands, and each band is stored as an ordinary term in the index shards. A similarity query looks up the bands of the query file, gathers candidates that share at least one band, then computes the true distance on the client and ranks. This reuses the shards, gateways and sampling verification the text index already has.

**What it is for.** Reviewers see when a proposed file is an exact or near copy of something already in the collection. Users find a higher-resolution scan, a better recording or a later edition of a file they have, find copies in other circles, and browse similar files from any file. Front-ends can filter against perceptual blocklists, not only exact hashes.

**Limits.** Similarity is only a hint; identity is SHA-256 and the content hash, and reviewers compare the files themselves. Learned image and audio embeddings such as SSCD or DINOv2 also match crops and heavy edits, which PDQ does not, but their floating-point inference is not bit-exact across hardware, so they cannot be checked bit for bit; anyone may still publish them, labelled with the model, as a vouched-for extra. New or improved fingerprint algorithms are added the same way, beside the old ones, and used by whoever finds them worth it.

## Appendix D. Serving over I2P

**Why proximity is the wrong variable.** A packet crosses two to three outbound and two to three inbound hops through routers chosen at random, and tunnels are rebuilt every ten minutes. Geography contributes almost nothing to latency; the intermediate routers contribute nearly all of it. Published latency measurements would also enable fingerprinting attacks that triangulate a server's real location.

**The client-side loop.** All the intelligence lives in the client, as in BitTorrent's choking algorithm. It opens sessions to several candidate keepers of the file, taken from the declared holdings on chain. It requests chunks in parallel and, on a pass, signs each server's running receipt as bytes arrive. It keeps a local performance table per I2P destination (throughput, time to first byte, failure rate), persisted across sessions, since destinations are stable even though tunnels are not. It shifts requests toward whoever delivers, drops peers below a threshold, and periodically tries a random new peer. For tail latency it hedges: it requests the same chunk from two servers and keeps whichever arrives first.

**Why this fits I2P.** Single-tunnel throughput is tens to a few hundred KB/s, so a large popular file cannot come from one server at usable speed whatever the distance. Swarming across many keepers is the path to bandwidth, and pass revenue rewards every server in proportion to what it pushed.

**The server's lever.** Tunnel length is the operator's choice. Zero-hop tunnels are fast and reveal the router to its direct peers; three-hop tunnels are slow and well hidden. Because pass revenue follows bytes delivered, that becomes a market trade between anonymity and income, with nothing encoded in the protocol.

**Pluggable transport.** Chunk requests, receipts and payments are defined over an abstract stream. I2P is one transport; clearnet, Yggdrasil-style overlays, and LAN or mesh peer discovery are others. Where real proximity exists, the same client loop exploits it automatically.

**Published and never published.** Published: who keeps which partitions (implied by proofs), aggregate burn totals per file, and a server's self-declared capacity class as a hint verified by buying. Never published: the measured latency or throughput of any node, anything mapping a destination to a time or place, and per-user download records.

## Appendix E. Relation to Arweave

Arca builds directly on Arweave's design and departs from it in a few places.

Arweave stores forever from a one-time endowment; Arca keeps a file while it sits in a public collection, paid by issuance, so adding to the library costs nothing and communities decide what stays.

Arweave pays every partition the same; Arca pays on a replication curve that rises to ten copies and falls beyond, so rare data gets company and over-replication is discouraged.

Arweave issues by schedule to miners directly; Arca issues by schedule through circle pools, split between a storage budget and an interest budget, so what the wider library wants is rewarded and curation pays.

Arweave leaves search to external services; Arca stores verifiable WASM index shards in the corpus, so search is part of the shared library.

Arweave's gateways serve for free as a service layer; Arca has a free allowance, 24-hour passes and free member access, so anyone can read and heavy use pays the people serving it.

Arweave has one weave; Arca has one chain and one coin with circles as curating pools, and one packed disk serves many circles.

Arweave keeps the full transaction history; Arca keeps state only, with a 24-hour challenge window, so phones are full participants.

Arweave uses 3.6 TB partitions; Arca uses 32 to 64 GB, so phones and small devices can mine.
