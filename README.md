# public_archive_bootstrap

`public_bootstrap.sh` restores an encrypted [restic](https://restic.net)
archive onto a fresh machine.

## Usage

```
git clone https://github.com/puddle-lake-ocean/public_archive_bootstrap && cd public_archive_bootstrap && bash public_bootstrap.sh
```

## Requirements

- A root-owned terminal: console login as root, `ssh root@host`, or a separate
  root session.
- Your Bitwarden vault, reachable.
- Another device to receive a two-step or new-device code.

You are asked for your Bitwarden email and master password once.
