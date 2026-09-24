# Arca web archive format (arca-web/1)

A format for archiving websites so they can be browsed offline, and so a reader can move through a site's history as timelines of changes instead of a list of numbered versions. It is built from the same parts as the rest of Arca: content-addressed files, manifests, collections and signed proposals. An archived site is an ordinary collection that circles can curate, follow, mirror and keep.

Draft, Sep 24, 2026, @Brito

## 1. Goals

- Offline first. A copy of an archive on a disk is enough to browse it, with no network and no server. Nothing is fetched live unless the reader asks for it.
- Timelines, not versions. For every page the reader sees when it changed, what changed, and can jump from one change to the next, skipping captures where nothing happened.
- Pristine bytes. What the server sent is stored as it was sent, never rewritten, so every file can be checked by its hash against any other copy.
- Cheap to keep going. A new crawl of a site that barely changed adds almost nothing: unchanged files are stored once, whoever captured them and however often.
- One format for one page and for a whole site. Saving a single page is a crawl with one seed and no depth.
- Verifiable where possible. Everything derived from the captures (timelines, indexes, diffs) is recomputed by a named, deterministic tool, so anyone can check it.
- Honest about uncertainty. A change happened somewhere between the last capture that saw the old state and the first capture that saw the new one, and the format says so instead of pretending to know the moment.

Not goals: proving that a server really sent a response (Section 13 has the partial answers) and archiving non-web protocols. Arca archives are stored in this format only; WARC is supported for moving archives in and out (Section 12), never as the way Arca keeps them.

## 2. Why not WARC

WARC (ISO 28500) is the format web archives have used for twenty years, and it is good at what it was made for: an institution writing a crawl to disk once and keeping it unchanged. Arca needs things WARC was not designed to give, so Arca keeps archives in its own format and uses WARC only to exchange them.

**Its files do not share chunks.** A WARC is a stream of records written into files of about 1 GB, usually compressed record by record. The same body sits at a different offset, with different neighbours and different compression, in every WARC that holds it. Cut into Arca's 256 KB chunks, two WARCs holding the same logo, script or photo share no chunks at all, so the corpus would store and pay for every copy. In this format every body is its own file named by its content hash, and the corpus stores it once.

**Its deduplication stops at the archive's edge.** A WARC `revisit` record says that a response was the same as one recorded earlier, by URL and date. Replaying it needs that earlier WARC to be present. There is no way to say "this body is already kept elsewhere in the library", which is what Arca's deduplication across collections and circles depends on.

**It stores bodies as they were sent.** The same file sent once with gzip and once with brotli gives two different payloads with two different digests. This format stores bodies decoded, so they dedupe and their text can be extracted and indexed directly.

**It has captures, not timelines.** WARC records what was fetched and when. Which captures are the same page in a meaningful sense, when a page changed and what changed are left to outside tools, each with its own rules. Here states, change kinds, change windows and site changelogs are part of the format and are rebuilt the same way by anyone.

**It does not say what a page loaded.** `WARC-Concurrent-To` and `WARC-Refers-To` link records loosely, but nothing records reliably which styles, scripts and images one page capture used, so replay guesses by timestamp. Here every resource names the page capture that caused it, and replay shows a page with the resources it actually had.

**It cannot be edited.** Records are appended and never changed. Removing one page means rewriting the whole file, which changes its hash and breaks every index that points into it. Here a takedown removes lines from a crawl and blobs from a collection, and nothing else changes.

**It proves integrity, not origin.** `WARC-Block-Digest` shows the bytes were not damaged; nothing in the standard says who made the capture. Here every crawl is signed, and anchoring it on the global chain fixes the latest time it can have been made.

**It needs an index that lives outside it.** Finding a record means a separate CDX or CDXJ index, and tools disagree on their variants. Here the index is part of the archive and derived by a named tool.

WACZ packages WARCs in a ZIP with an index, a list of pages and a signature, which fixes the packaging and the missing signature. It still carries WARC files inside, so the chunking, deduplication and timeline problems remain.

## 3. Concepts

**Capture.** One fetch of one URL at one moment: the request, the response status and headers, the body by content hash, and the time. A capture is a fact claimed by whoever made it.

**Crawl.** A set of captures made together by one capturer with one tool, one scope and a start and end time. A crawl is the unit that gets proposed to a collection, signed and accepted. A saved page is a crawl too.

**State.** A run of captures of the same URL whose content is the same in a meaningful sense (Section 7). A state has a first-seen and a last-seen time, the number of times it was seen, and the exact variants of bytes that were grouped into it.

**Page timeline.** The ordered list of states of one URL. Where two states meet there is a change, and every change has a window: from the last time the old state was seen to the first time the new one was seen.

**Lane.** A parallel timeline for the same URL when a site shows different content to different readers: desktop or mobile, one language or another, one region or another. Each capture declares its lane, and timelines never mix lanes. Most archives have only the default lane.

**Site timeline.** The history of a whole site as a sequence of crawls, each with the pages it added, removed and changed. It answers "what changed on the site this week" and "what did the site look like on a given day".

**Blob.** The body of a response, stored once under its content hash. A thousand captures of an unchanged logo are one blob.

## 4. Layout

An archive is a folder. In Arca it is a collection (or a folder inside one); outside Arca it is a plain directory, or a single ZIP file with the extension `.arcaweb` holding the same tree.

```
example.org/
  archive.json                    archive header
  crawls/
    20260917140000-3fa9c21b.json  crawl record, signed
    20260917140000-3fa9c21b.jsonl captures of that crawl, one per line
    20260924140000-3fa9c21b.json
    20260924140000-3fa9c21b.jsonl
  blobs/
    a7/3f/<content hash>          response bodies, one file per distinct body
  derived/
    derived.json                  which tool built this folder, from which crawls
    index/0000.cdx ...            capture index, sorted by URL key and time
    pages/0000.jsonl ...          page timelines, sorted by URL key
    pages/shards.json             first key of every shard, for lookup
    site.jsonl                    site timeline, one line per crawl
    changes/<crawl id>.jsonl      what each crawl changed, one line per page
    diffs/<hash>.json             optional precomputed diffs between states
```

The source of truth is `archive.json`, `crawls/` and `blobs/`. Everything under `derived/` can be deleted and rebuilt from them, and a reader may choose to trust a published copy or rebuild it.

Crawl ids are the start time as 14 digits in UTC followed by the first 8 hex digits of the crawl key, so sorting crawl files by name sorts them by time. Blobs sit in two levels of folders named by the first four characters of their hash, so no folder grows past a few thousand entries.

Records are UTF-8 JSON. Signed records use the JSON Canonicalization Scheme (RFC 8785) so the signature covers exactly one byte sequence. Times are RFC 3339 in UTC with second precision, such as `2026-09-24T14:03:11Z`. Hashes use the text form of the Arca content hash, the same one manifests use.

## 5. Records

### archive.json

```json
{
  "format": "arca-web/1",
  "title": "example.org",
  "description": "Public pages of example.org, weekly since 2026.",
  "scope": {
    "seeds": ["https://example.org/"],
    "include": ["https://example.org/", "https://cdn.example.org/"],
    "exclude": ["https://example.org/login", "https://example.org/cart"]
  },
  "lanes": {
    "default": "Desktop browser, English, no cookies",
    "mobile": "Mobile browser, English, no cookies"
  },
  "strip_headers": ["x-session", "x-user-id"],
  "canon": { "tool": "arca-urlkey", "version": "1.0", "hash": "<wasm hash>",
             "drop_params": ["utm_*", "fbclid", "gclid", "sessionid"] },
  "normalize": { "tool": "arca-webnorm", "version": "1.0", "hash": "<wasm hash>",
                 "ignore": [
                   { "match": "https://example.org/*", "selector": ".ad-slot, #visitor-count" },
                   { "match": "*", "pattern": "csrf_token=[A-Za-z0-9]+" }
                 ] }
}
```

The header holds what applies to every crawl: what the archive tries to cover, which lanes exist, how URLs are turned into keys, and which parts of a page are noise that should never count as a change. Changing `canon` or `normalize` means rebuilding `derived/`; the captures themselves never change.

### Crawl record

`crawls/<id>.json` describes a crawl and signs its captures.

```json
{
  "format": "arca-web/1",
  "id": "20260924140000-3fa9c21b",
  "start": "2026-09-24T14:00:00Z",
  "end": "2026-09-24T14:47:12Z",
  "tool": { "name": "arca-capture", "version": "0.4.1" },
  "mode": "browser",
  "lanes": ["default"],
  "seeds": ["https://example.org/"],
  "depth": 6,
  "captures": { "file": "20260924140000-3fa9c21b.jsonl", "hash": "<content hash>", "count": 1532 },
  "blobs_new": 41,
  "key": "<crawl public key>",
  "signature": "<signature over this record without this field>"
}
```

`mode` is `http` for a plain fetcher that does not run scripts, or `browser` for a capturer that renders pages and records every request the page makes. `blobs_new` is informative: how many bodies this crawl added that the archive did not already have.

The crawl key signs the record, and through the captures hash it signs every capture. It may be a one-off key made for this crawl (Section 13).

### Captures

`crawls/<id>.jsonl` holds one capture per line, in the order they were made. The line number, starting at 1, is the capture's address inside the crawl.

A page:

```json
{"url":"https://example.org/news?id=7&utm_source=feed","key":"org,example)/news?id=7",
 "time":"2026-09-24T14:03:11Z","lane":"default","method":"GET","nav":true,
 "status":200,"type":"text/html",
 "headers":[["content-type","text/html; charset=utf-8"],["last-modified","Tue, 22 Sep 2026 09:12:00 GMT"],["content-encoding","br"]],
 "body":"<content hash>","size":48213,"decoded":true,
 "exact":"<content hash>","norm":"<hash>",
 "dom":"<content hash>","shot":"<content hash>"}
```

A resource that page loaded:

```json
{"url":"https://cdn.example.org/site.css?v=812","key":"org,example,cdn)/site.css",
 "time":"2026-09-24T14:03:12Z","lane":"default","method":"GET","from":17,
 "status":200,"type":"text/css","headers":[["content-type","text/css"]],
 "body":"<content hash>","size":20110,"decoded":true,"exact":"<content hash>","norm":"<content hash>"}
```

A redirect and a failure:

```json
{"url":"https://example.org/old","key":"org,example)/old","time":"2026-09-24T14:05:40Z",
 "lane":"default","method":"GET","nav":true,"status":301,"location":"https://example.org/new"}
{"url":"https://example.org/gone","key":"org,example)/gone","time":"2026-09-24T14:05:41Z",
 "lane":"default","method":"GET","nav":true,"error":"timeout"}
```

Fields:

- `url`: the URL exactly as requested. `key`: its canonical key (Section 6).
- `time`: when the response began to arrive.
- `lane`: one of the archive's lanes.
- `method`: the HTTP method. For anything but GET and HEAD, `request_body` holds the hash of the request body, because script-driven pages often load their content with POST requests and replay has to match them.
- `nav`: true when the capture is a top-level document the reader could navigate to, as opposed to an image, script or API call. Only `nav` captures get page timelines in the site timeline; everything else still gets a timeline of its own.
- `from`: for a resource, the line number of the page capture that caused it. This is how a page's render set (everything it loaded) is known.
- `status` and `headers`: the response status and headers, with the headers listed in Section 13 removed. Header names are lowercase and in the order received.
- `body`, `size`: the body as a blob and its size in bytes. `decoded: true` means transfer and content encodings (chunked, gzip, br, zstd) were removed before storing, which lets the same file sent with different compression dedupe to one blob and lets text be extracted. The original encoding stays in the headers.
- `exact` and `norm`: the two hashes used to detect change (Section 7). `exact` equals `body` for plain responses; `norm` is computed by the archive's normalize tool.
- `location`: the target of a redirect. `error`: why no response came: `dns`, `refused`, `reset`, `tls`, `timeout` or `blocked` (the capturer chose not to fetch it).
- `dom`: optional, for browser crawls. The page's DOM after scripts ran, serialized as one HTML file that still refers to resources by their original URLs. It is the fallback when the page's scripts cannot be replayed.
- `shot`: optional, a screenshot of the rendered page, PNG or WebP. It doubles as the screenshot in the blob's manifest.
- `cert`: optional, the SHA-256 of the server's TLS certificate, once per host per crawl.

A capture with the same `norm` as the previous capture of its key in the same lane is still recorded. It costs about 300 bytes and it is what moves a state's last-seen time forward.

### Blobs

Each blob is the body as stored, named by its content hash. In Arca every blob is an ordinary corpus file with a manifest: the recommended file name comes from the last URL segment with an extension that fits the detected type, the source field holds the first URL it was captured from, and HTML, PDF and other documents get their extracted text as a text layer (white paper, Appendix B). That is what makes archived pages searchable by what they said.

## 6. URL keys and matching

A URL key groups captures that are the same resource. It is computed by the archive's canon tool, which must be deterministic:

1. Lowercase the scheme and host; drop the fragment, the default port, a trailing dot in the host, and one leading `www.`.
2. Treat `http` and `https` as the same key; the real scheme stays in `url`.
3. Remove query parameters matching `drop_params`, then sort the rest by name and value.
4. Reverse the host labels and join them with commas, then `)`, then the path and query, as in `org,example)/news?id=7`. All keys of one site then sort together, which keeps its captures together in the index.

When a request has no exact key in the archive, the viewer may try fuzzy matches, in order: the same key with all query parameters dropped, then the same path with a different query, and marks the result as an approximate match. Cache-busting parameters such as `?v=812` are the common case, which is why they belong in `drop_params` when the archive knows them.

## 7. Detecting change

Pages change in ways nobody cares about: a clock in the footer, a visitor counter, a rotating ad, a fresh security token in every form. If every such difference counted, every capture would be a new version and the timeline would be useless. So every capture carries two hashes.

**exact** is the hash of the stored bytes. Two captures with the same `exact` are identical.

**norm** is the hash of the meaningful content, computed by the archive's normalize tool. For HTML it is built from the visible text, the targets of links, the sources of images and media, and the page title, with whitespace collapsed and the `ignore` rules of `archive.json` applied. For every other type it is the same as `exact`, unless a rule in `archive.json` says otherwise for that type.

A state is a run of captures of one key and one lane with the same `norm`. Captures with different `exact` hashes inside a state are its variants; the viewer can show them, and a reader who cares about byte-level history can step through them.

A page's look also depends on its styles, scripts and images. For a `nav` capture the derived timeline also computes a render hash: the hash of the sorted list of `norm` hashes of everything the page loaded. That gives two kinds of change for a page that did not change in content.

Every change between two states has one kind:

- `new`: first time the key was seen.
- `content`: the `norm` hash changed.
- `assets`: the page's own `norm` is the same but its render hash changed; it looks different while saying the same.
- `redirect`: it became a redirect, stopped being one, or now redirects somewhere else.
- `status`: the status class changed, such as 200 to 404, or 200 to 500.
- `gone`: it answered with 404 or 410, or stopped appearing in crawls whose scope covers it.
- `back`: it reappeared after being gone.
- `unreachable`: every capture in a crawl failed with an error. An unreachable capture never ends a state by itself; it is shown as a gap.

Normalizing is a matter of judgement, so it is a named, replaceable tool like the extraction tools in the white paper. A curator who finds that a site's timeline is noisy adds an `ignore` rule and rebuilds `derived/`. Nothing captured is lost; only the grouping changes.

## 8. Timelines

Timelines are derived by a deterministic tool from `archive.json` and all crawls, and written to `derived/`. `derived/derived.json` names the tool, its version and hash, and the list of crawl ids it was built from.

### Page timelines

`derived/pages/*.jsonl` holds one line per state, sorted by key, then lane, then first-seen time. Shards are at most 1 MB; `shards.json` lists the first key of every shard so a reader finds the right one without scanning.

```json
{"key":"org,example)/news?id=7","lane":"default","state":3,
 "first":"2026-09-10T14:02:55Z","last":"2026-09-17T14:03:01Z","seen":2,
 "norm":"<hash>","render":"<hash>","status":200,"type":"text/html",
 "change":"content","window":["2026-09-03T14:02:40Z","2026-09-10T14:02:55Z"],
 "variants":2,"first_capture":["20260910140000-3fa9c21b",17],"last_capture":["20260917140000-3fa9c21b",17],
 "witnesses":1,"summary":{"words_added":212,"words_removed":8,"links_added":3,"links_removed":0}}
```

- `state` counts from 1 per key and lane.
- `change` is how this state differs from the one before it; `window` is when that change happened, as closely as the captures allow.
- `render` is present when the state has a single render hash; when assets changed inside a content state the timeline starts a new state of kind `assets` instead.
- `witnesses` is how many distinct crawl keys saw this state. A state seen by three independent capturers is better evidence than one seen by one.
- `summary` is a small, cheap description of the change for timeline views, computed from the normalized text of the two states.

### Capture index

`derived/index/*.cdx` lists every capture as one line of space-separated fields, sorted bytewise, so a lookup is a binary search:

```
org,example)/news?id=7 20260924140311 default 20260924140000-3fa9c21b 17 200 9c1e44a0
```

The fields are key, time as 14 digits, lane, crawl id, line number, status (or `-` for an error), and the first 8 characters of the `norm` hash. This is what the viewer uses to resolve a URL at a time; page timelines are what it uses to show changes.

### Site timeline

`derived/site.jsonl` has one line per crawl:

```json
{"crawl":"20260924140000-3fa9c21b","start":"2026-09-24T14:00:00Z","end":"2026-09-24T14:47:12Z",
 "pages":1210,"new":4,"content":23,"assets":112,"gone":2,"back":0,"unchanged":1069,"unreachable":0}
```

`derived/changes/<crawl id>.jsonl` lists, for that crawl, every page whose state changed, with its key, lane, kind, old and new state numbers and summary. A site changelog is these files read in order.

### Diffs

A diff between two states of a page is computed from their normalized text, their links and their render sets: paragraphs added and removed, links added and removed, resources that changed. Viewers compute diffs on demand. A curator may precompute the ones readers look at most and publish them in `derived/diffs/`, named by the hash of the two `norm` hashes; they are an optimization, never required.

## 9. Browsing offline

### Time as the reader's position

The reader is always at a moment T, and optionally locked to it. The viewer's address for an archived page is:

```
arca-web:<archive id>/<T as 14 digits>/<original URL>
```

`<archive id>` is the collection's id in Arca, or the folder or file name outside it. Appending `raw` to the time (`20260924140311raw`) returns the stored bytes with no replay; appending `dom` shows the serialized DOM instead of running the page.

### Resolving a request

For the page the reader opens at time T, in lane L:

1. Canonicalize the URL to a key.
2. Take the latest capture of that key and lane at or before T. If there is none, take the earliest after T, and say so.
3. If the capture is a redirect, follow it inside the archive with the same rules. If it is an error, show the nearest successful capture and the error beside it.
4. If nothing matches, try the fuzzy matches of Section 6. If nothing still matches, show a "not archived" page that lists the nearest archived times of that URL and nearby URLs, with a button to open it live.

For everything the page then loads (styles, scripts, images, API calls), the reference time is not T but the time t of the page capture that was chosen, and the rule is different:

1. Prefer the capture made by the same page capture, found through `from`.
2. Otherwise prefer a capture from the same crawl.
3. Otherwise take the capture closest to t in either direction.

This keeps a page coherent: it is shown with the resources it actually had, not with whatever version of the stylesheet happens to be closest to where the reader is standing.

**Drift.** The viewer shows how far the page it shows is from T, and how far the most distant resource is from t. Beyond a threshold the reader chooses (by default one day for pages and one week for resources), it marks the page as a composite.

### Following links

Clicking a link keeps T, not t. A reader looking at the site on 1 March stays on 1 March as they move around, even when the page they came from was captured on 27 February. When time lock is off, the viewer instead moves T to the capture time of each page opened, which is how people usually wander through an archive.

### No rewriting, no leaks

Stored bodies are never rewritten, not at capture and not at rest. The viewer renders pages in a web view it controls and intercepts every request the page makes, whatever the URL, and answers it from the archive with the rules above. Because interception happens below the page, absolute links, links built by scripts, and resources named in CSS all resolve without any rewriting of the HTML.

The web view has no network. A request the archive cannot answer fails, and the viewer lists what failed, so a reader always knows what is missing. Opening a URL live is always an explicit action and always leaves the archive view. This protects fidelity (no live file mixed into an archived page) and privacy (an archived page cannot call home).

For replay fidelity the viewer may also set the page's clock to t, fix random number seeds, and disable service workers of the archived site. Pages that still fail to replay fall back to the `dom` snapshot, and to the screenshot if there is no snapshot.

On Arca's clients the web view is the app's own; outside Arca, a small viewer serves the folder on localhost and does the same with a service worker. A `.arcaweb` file is read in place, without unpacking, because ZIP gives random access to its entries.

## 10. Moving through changes

The format exists so that a viewer can offer these, and every one of them is answered from `derived/` without reading blobs until the reader opens a page.

**Page timeline bar.** Each state is a segment from its first to its last capture, with a dot for every capture. Change windows between states are drawn as hatched gaps, because the change happened somewhere inside them. Unreachable crawls are marked. Lanes are parallel bars.

**Step through changes, not captures.** Next and previous jump to the next state, skipping the hundred captures where nothing happened. A filter chooses which kinds count: content only, content and assets, or everything including status and redirects.

**Compare.** Any two states of a page side by side or as a diff of text, links and resources. The default comparison is a state with the one before it.

**Site at a date.** Pick a day and browse the whole site as it was, with time lock on.

**Site changelog.** Crawl by crawl, what appeared, what disappeared and what changed, each entry opening the diff. Filters by path prefix (only /news/), by kind, and by size of change.

**Search in time.** Because blob text is indexed through manifests, a search can ask for pages that contained a phrase at a given date, or for the first state of a page where a phrase appeared and the state where it disappeared.

## 11. In Arca

**An archive is a collection.** It is curated like any other: a circle holds the archives its members care about, with the same roles, review and policy.

**A crawl is a proposal.** A capturer proposes a new crawl file, its captures file and the blobs the archive does not have yet. Moderators or the collection's maintainers accept it by signing a new collection version. Crawls from different capturers touch different paths and merge without conflict, which is how several people archive one site together. Removing a crawl is also a proposal, and after it the derived timelines are rebuilt without it.

**Derived files are computed files.** After accepting crawls, a moderator runs the deterministic timeline tool and publishes `derived/` as part of the same version, the way index shards are published. Anyone can rebuild it from the crawls and compare; a mismatch is handled like a wrong index shard and lowers the circle's trust.

**Following.** A follower of an archive fetches only new crawls, new blobs and the changed derived shards. A mirror of an archive is a folder that the offline viewer opens directly.

**Deduplication is free.** Blobs are corpus files, so the same jQuery build, font or logo captured by a thousand archives in a hundred circles is one chunk sequence in the corpus, kept and proven like any other.

**Relations.** A curator may publish manifests that link successive states of important pages with the relation "new version of", so a document found by search leads to its earlier and later states even outside the archive's viewer.

**Time evidence.** A capture's time is the capturer's claim. The circle's hourly anchor on the global chain proves that an accepted crawl existed no later than that anchor, so no one can later insert a capture with an old date into an anchored archive without it being visible. Independent witnesses of the same state (Section 8) add corroboration from the other direction.

## 12. Interoperability

**Import from WARC.** Every WARC `response` record becomes a capture with its body as a blob; `request` records supply the method and request body; `revisit` records become captures pointing to the blob of the record they revisit; `metadata` and `warcinfo` records fill the crawl record. One WARC file, or a set from one crawl job, becomes one crawl. The WARC file's own hash is kept in the crawl record so the import can be checked.

**Export to WARC.** Each crawl exports as a WARC file with one `response` record per capture, rebuilt from the headers and the blob. Because bodies are stored decoded, the exported payload is identical in meaning but may differ in bytes from what was originally sent when the response was compressed; the export marks such records.

**Single file.** An archive or a subset of it (some crawls, one path, one lane) exports as a `.arcaweb` ZIP holding the same tree. Blobs that are already compressed (images, video, archives) are stored without further compression; text is deflated.

## 13. Privacy and safety

**Stripped headers.** Capture tools remove `cookie`, `set-cookie`, `authorization`, `proxy-authorization` and any header the archive lists in `strip_headers`, from both requests and responses. Archives of pages behind a login are discouraged, and a capturer who makes one must keep it in a closed collection.

**No capturer location.** The resolved server IP address is not recorded by default, because with geographically routed hosts it reveals where the capturer was. Lanes that depend on region are declared coarsely by the capturer ("EU"), never measured. Crawl keys may be one-off keys that are not linked to a steward key; the circle vouches for the crawl by accepting it. This follows principle 9 of the white paper: what is published is what was captured and when, not where the capturer sits.

**What the format cannot prove.** A signed capture proves who claims to have seen a response and, once anchored, that the claim existed by a certain time. It does not prove the server sent it. The `cert` field and the server's own `date` header are weak supporting evidence; several independent witnesses of the same state are stronger. A notarized capture scheme, where a third party attests to a TLS session without seeing it, would close the gap and is left open.

**Takedown.** Removing a page from an archive is a proposal that drops its captures from the accepted crawls or removes whole crawls, followed by a rebuild of `derived/`. As with every collection, what others already copied stays theirs, and blobs still used by other collections stay in the corpus.

## 14. Sizes

For a site of 1,000 pages captured weekly by a browser crawler:

- First crawl: about 30 MB of HTML and 200 MB of images, styles, scripts and fonts, plus about 1,500 captures of about 300 bytes each.
- Each later crawl, with 2% of pages changing: about 1 MB of new HTML, a few new assets, and 450 KB of captures (about 60 KB compressed).
- A year: about 230 MB for the first crawl and 50 to 100 MB for the next 51, depending on how often assets change. Derived files are a few MB.
- Screenshots, if taken, dominate: 200 to 500 KB per page state, stored only when the render hash changes.

The same site archived as 52 independent snapshots would take about 12 GB. Most of the saving comes from storing each body once, and the rest from recording unchanged pages as a single line.

## 15. Open questions

- **Small blobs.** Sites are made of many files under 4 KB (icons, JSON responses, small scripts). How the corpus stores files much smaller than a chunk decides whether they should be bundled inside an archive or left to the corpus.
- **Normalizing well by default.** A good default normalize tool for common sites (news, blogs, forums, shops) would make most timelines useful without hand-written rules. Whether that can be deterministic enough to verify while staying good is the same tension as in the white paper's extraction tools.
- **Replaying modern applications.** Pages that open WebSockets, stream media in pieces, or sign their API requests with the current time replay poorly from request matching alone. The `dom` fallback always works but is not interactive.
- **Clock skew between capturers.** Capture times from different crawl keys are claims made with different clocks. Merged timelines may show brief flips when two capturers' clocks disagree; lanes do not help here, and a skew estimate per crawl key may be needed.
- **Lanes by region without locating anyone.** Region-dependent content is real, but recording which region a capture came from reveals something about its capturer. Coarse, declared regions are the current answer.
