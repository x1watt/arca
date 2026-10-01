# Changelog

All notable changes to Arca. Versions follow `version:` in
`app/pubspec.yaml`; each release is tagged `v<version>`.

## 0.1.1 (2026-10-01)

- Updates over I2P. A new version is announced by an event signed with
  Arca's release key and its files travel over I2P from the seed and from
  every device that already has them, checked against the signed SHA-256.
  Settings, About shows the version, what is new and an Install button;
  "Automatic updates" can download by itself (the default), only notify,
  or stay off. Installing always waits for your click.
- Android installs updates through the system installer; Windows and
  Linux unpack the update beside the app and swap it in on "Restart to
  update", keeping the previous folder as `arca.previous`.
- Downloading from GitHub instead is offered only when no device on I2P
  has the update, and only on your click: it shows GitHub your IP address.
- Android builds are now signed with Arca's permanent release key.
  **If you installed 0.1.0 on Android, uninstall it and install 0.1.1 once
  by hand**: 0.1.0 was signed with a temporary key, so Android refuses to
  update it in place. Back up your profile first (Settings, Profiles,
  export the nsec). From 0.1.1 on, updates install over the top.

## 0.1.0 (2026-10-01)

- First public prototype for Windows, Linux and Android: profiles,
  collections, following and suggestions, subtitles made on the device,
  the built-in test network and its wallet, all over I2P.
