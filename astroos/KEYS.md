# AstroOS repository signing key — procedure (council R3, risk #3)

The `[astroos]` pacman repo is signed end-to-end: every package carries a
detached signature and the repo db is signed (`repo-add --sign`). Clients get
`SigLevel = Required DatabaseOptional` for the FIRST publish cycle only, with
a dated cutover to full `Required` recorded in COUNCIL_LEDGER.md (R3 D2/Q4).

## Generation (one-time)

On the build VM: `bash astroos/scripts/build-aur-repo.sh keygen`
- ed25519 sign-only key, no expiry, uid `AstroOS Repository <repo@astroos.local>`
- lives in `~/astroos-repo-keys` (GNUPGHOME, mode 700)
- exports written next to it: `astroos.gpg` (binary pub), `astroos.asc`
  (armored), `FINGERPRINT`

## Backup (owner action, immediately after keygen)

Copy the whole `~/astroos-repo-keys` directory to an offline location the
owner controls (password manager attachment / encrypted drive). The VM disk
is NOT a backup: the resource group can be deleted.

## Client trust path (ratified Q2: keyring file in overlay)

`astroos.gpg` is shipped in the ISO overlay at
`usr/share/pacman/keyrings/astroos.gpg` with `astroos-trusted`
(`<FPR>:4:` line) so `pacman-key --populate` trusts it on live AND installed
systems. The ISO build asserts the shipped fingerprint equals the one the
repo db is signed with.

## Rotation / loss (dual-sign transition, risk #3)

1. Generate a NEW key (`keygen` into a fresh dir; move the old aside).
2. Transition window: sign packages + db with the NEW key while the overlay
   ships BOTH keyrings (old + new) — installed systems learn the new key via
   a shipped keyring update before the old one disappears.
3. After one release cycle, drop the old keyring from the overlay and revoke.
4. If the private key is LOST: generate new, ship new keyring in the next ISO;
   existing installed systems must re-import manually (documented in release
   notes) — this is why the offline backup matters.

## Publish credentials

Publishing uses an Azure Blob SAS token (write-scoped, time-boxed), generated
on the laptop (`az storage container generate-sas`) and scp'd to the VM at
`~/astroos-repo.sas` (mode 600). No cloud credentials live in git or in the
image. Rotate by generating a fresh SAS; expiry bounds the blast radius.
