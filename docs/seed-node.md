# Running a seed node, and joining the public test network

The public test network is an ordinary Arca test network (`docs/architecture.md`, 10) whose founder is a headless Arca that runs as a service: the seed node. It shares one collection, which is the network's corpus, keeps and proves every partition of it, mines, and serves the network's spec, the circle log and the files to whoever joins. Test marcas have no value.

## Joining

In the app, open the wallet and choose "Join the public test network". A computer keeps a copy of the corpus and earns for keeping it; a phone follows lightly and keeps nothing, unless it is told to keep files in the wallet. Joining can take a minute or two while I2P finds the seed.

To join another network, choose "Join with an invite" and paste its invite (`arca-chain:<spec hash>:<arca address>`). The environment variable `ARCA_PUBLIC_INVITE` replaces the built-in public invite on a desktop, which is how a new seed is tried before it becomes the default.

## Running a seed node

A seed needs a machine that stays on, about 1 GB of memory and the corpus's size in disk space twice over (the files and their packed copy). It makes only outgoing connections, so it works behind a home router or CGNAT.

Build it once:

    cd packages/arca_core
    dart compile exe tool/seed_node.dart -o ~/bin/arca-seed

The first run creates the collection from the files given and starts the network:

    ~/bin/arca-seed ~/arca-seed --name="Arca test corpus" ~/corpus/*

Choose files anyone may share: public domain or freely licensed works. The corpus cannot change once the network has started; a different corpus is a different network.

Later runs take no files and continue the same network:

    ~/bin/arca-seed ~/arca-seed

The seed writes its invite to `~/arca-seed/invite.txt` and prints a line a minute (height, day, peers, balance). The data directory holds the seed's key: back it up, since a seed that loses it can no longer act as the network's founder or its circle's admin.

### As a service

`~/.config/systemd/user/arca-seed.service`:

    [Unit]
    Description=Arca test network seed
    After=network-online.target

    [Service]
    ExecStart=%h/bin/arca-seed %h/arca-seed
    Restart=always
    RestartSec=30

    [Install]
    WantedBy=default.target

Then:

    systemctl --user daemon-reload
    systemctl --user enable --now arca-seed
    loginctl enable-linger $USER    # keep it running after logout
    journalctl --user -u arca-seed -f

The seed stops cleanly on SIGTERM. `Restart=always` brings it back after any stop but a `systemctl stop`, including one by earlyoom when memory runs low (`docs/TODO.md`, 3).

### Making it the default

Put the seed's invite in `TestnetSpec._publicInvite` (`packages/arca_core/lib/src/chain/testnet.dart`) and release the app. The invite stays valid as long as the seed keeps its data directory.
