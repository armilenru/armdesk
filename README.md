# ArmDesk

[Русская версия](README.ru.md)

ArmDesk is a fork of the [RustDesk](https://github.com/rustdesk/rustdesk)
remote desktop client, built by the IT studio [ARMILEN](https://www.armilen.ru)
to support its clients. It comes preconfigured for our own servers and under
our own name. It is an independent build: not affiliated with or endorsed by
the RustDesk project.

## Download

Installers for Windows, macOS, Linux and Android are at
https://www.armilen.ru/support. The same files are attached to the
[releases](../../releases) of this repository.

## What differs from upstream

- Its own name, icons, logos and accent color.
- By default it connects to our rendezvous and relay servers (`hbbs`/`hbbr`)
  with our server key.
- Account sign-in and the address book go to our own API server, never to
  RustDesk's public one.
- It checks for new versions at www.armilen.ru and updates itself by default.
  Upstream keeps auto-update off; the "Auto update" checkbox in the settings
  turns it off here.
- The privacy policy link leads to
  https://www.armilen.ru/legal/armdesk-privacy.

Everything else is upstream's code.

## Versions

A version reads `<RustDesk version>-<ArmDesk build>`: `1.5.0-1` is the first
ArmDesk build on top of RustDesk 1.5.0. New upstream releases are merged as
they come out.

## Building

Build it the way upstream describes in its
[README](https://github.com/rustdesk/rustdesk#readme). Release builds are made
by GitHub Actions in this repository.

## License

AGPL-3.0, the same as upstream: see [LICENCE](LICENCE). The source code of
every released build is in this repository.
