# The test network and its seed node

Arca has one test network, built into the app like any chain's genesis block (`TestnetSpec.builtIn`, `docs/architecture.md` 10). Its marcas have no value.

## Taking part

In the app, open the wallet and choose "Take part in the test network". Nothing has to be typed in: the device works out the network's meeting point, an I2P address made from the network's spec that every full node answers for, and learns the other nodes there. A computer then fetches the network's files by hash from them, keeps a copy and earns for keeping it; a phone follows lightly and keeps nothing, unless it is told to keep files in the wallet. The first time takes a minute or two while I2P finds the others.

## The seed node

Someone has to make the network: choose its files, start its chain and keep it going until others keep copies too. That is the seed node, a headless Arca (`packages/arca_core/tool/seed_node.dart`). It is the network's founder: the admin of its genesis circle, holder of the circle's log and of the founder's test allocation. It has no other special role: newcomers find it at the meeting point like any other full node, and once others keep the files, the network does not need it to be online.

A seed needs a machine that stays on, about 1 GB of memory and the corpus's size in disk space twice over (the files and their packed copy). It makes only outgoing connections, so it works behind a home router or CGNAT.

Build it once:

    cd packages/arca_core
    dart compile exe tool/seed_node.dart -o ~/bin/arca-seed

The first run shares the files given as a collection and starts the network:

    ~/bin/arca-seed ~/arca-seed --name="Arca test corpus" ~/corpus/*

Choose files anyone may share: public domain or freely licensed works. The corpus cannot change once the network has started; a different corpus is a different network.

Later runs take no files and continue the same network:

    ~/bin/arca-seed ~/arca-seed

The seed writes the network's spec to `~/arca-seed/spec.json` and prints a line a minute (height, day, peers, balance). The data directory holds the seed's key: back it up, since a seed that loses it can no longer act as the network's founder or its circle's admin.

### Serving updates of Arca

The seed is where new versions of Arca start spreading over I2P (`docs/architecture.md`, 11). Give it a release as the release workflow publishes it, the downloads with `release.json` beside them:

    gh release download v0.1.1 -R x1watt/arca -D ~/arca-release/v0.1.1
    ~/bin/arca-seed ~/arca-seed --release=$HOME/arca-release/v0.1.1/release.json

It checks the announcement against the release key built into Arca and every file against its SHA-256, keeps them in `<data dir>/core/updates/`, keeps the announcement in its relay, answers at the updates meeting point and serves the files to every device that asks, whatever the test network's reading rules. It reads the file again every hour, so pointing it at the next release (or replacing the folder) is enough; the older release's files are deleted when a newer one is taken.

Or, as an explicit choice for an operator's machine, from GitHub over HTTPS every six hours:

    ~/bin/arca-seed ~/arca-seed --release-github

This shows GitHub the seed's IP address; it is still I2P only towards everyone else. The seed prints a line when it serves a new release, and which files it could not get.

### As a service

With `--release` below, `~/arca-release/current` is a link to the folder of the newest release (`ln -sfn v0.1.1 ~/arca-release/current`).

`~/.config/systemd/user/arca-seed.service`:

    [Unit]
    Description=Arca test network seed
    After=network-online.target

    [Service]
    ExecStart=%h/bin/arca-seed %h/arca-seed --release=%h/arca-release/current/release.json
    Restart=always
    RestartSec=30

    [Install]
    WantedBy=default.target

Then:

    systemctl --user daemon-reload
    systemctl --user enable --now arca-seed
    loginctl enable-linger $USER    # keep it running after logout
    journalctl --user -u arca-seed -f

The seed stops cleanly on SIGTERM. `Restart=always` brings it back after any stop but a `systemctl stop`, including one by earlyoom when memory runs low (`docs/TODO.md`, 3). A seed that was frozen or whose computer slept starts I2P afresh by itself (`docs/performance.md`, 3.17).

### Building the network into the app

Put the contents of `spec.json` in `TestnetSpec._builtInSpec` (`packages/arca_core/lib/src/chain/testnet.dart`) and release the app. To try a network before that, point `ARCA_TESTNET_SPEC` at a spec file when starting a desktop app.

With each release, also put the contents of `checkpoint.json` (the seed's latest block, rewritten every minute) in `TestnetSpec._builtInCheckpoint`. Devices then check the chain they are shown from that block on, which is less to download and check, and refuse any chain that does not contain it: even a first run that meets nothing but forgers cannot be led onto another chain from before it (`docs/architecture.md`, 10).
