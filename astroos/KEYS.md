# AstroOS repository signing key — procedure (council R3, risk #3)

The `[astroos]` pacman repo is signed end-to-end: every package carries a
detached signature and the repo db is signed (`repo-add --sign`). Clients get
`SigLevel = Required DatabaseOptional` for the FIRST publish cycle only, with
a dated cutover to full `Required` recorded in COUNCIL_LEDGER.md (R3 D2/Q4,
date set in R4.1). The same key signs the released ISOs (`.iso.asc`); a
separate release key is an open owner decision (review R4 D-A).

## Generation (one-time)

On the build VM: `bash astroos/scripts/build-aur-repo.sh keygen`
- ed25519 sign-only key, no expiry, uid `AstroOS Repository <repo@astroos.local>`
- lives in `~/astroos-repo-keys` (GNUPGHOME, mode 700)
- exports written next to it: `astroos.gpg` (binary pub), `astroos.asc`
  (armored), `FINGERPRINT`
- fingerprint: `DA5C947A5C329E528948830E92304756ECC2F9D8`, also pinned in
  `branding/REPO_FINGERPRINT`

## Backup (owner action)

The VM disk is NOT a backup: the resource group can be deleted.

Status 2026-09-05: the whole `~/astroos-repo-keys` directory was pulled to
the laptop at `C:\Users\rudra\astroos-repo-keys` (outside OneDrive, fingerprint
verified against `branding/REPO_FINGERPRINT`). Still open for the owner:
move that directory to cold storage (password manager attachment or an
encrypted drive) and delete the laptop copy. Until then the laptop copy is
the only backup.

## Client trust path (ratified Q2, moved into a package in R4.1)

The keyring trio lives in
`pkgs/astroos-keyring/files/usr/share/pacman/keyrings/`:

- `astroos.gpg`: the public key (binary export)
- `astroos-trusted`: one line, `<FPR>:4:` (ultimate trust for pacman-key)
- `astroos-revoked`: empty until a rotation

`astroos-keyring` installs the trio under `/usr/share/pacman/keyrings/` and
its install script runs `pacman-key --populate astroos` when a pacman keyring
exists. That covers every system the same way: the builder container
(`container-build.sh` installs the same three files, asserts the fingerprint
and the trusted line, then populates), the live ISO (the package is in the
package list), installed systems (the package sits in the installer's
pacstrap base set), the hosted-repo CI job and `forge.sh verify` (both
populate from the shipped files before installing under `SigLevel Required`).

## Rotation / loss (dual-sign transition, risk #3)

1. Generate a NEW key (`keygen` into a fresh dir; move the old aside).
2. Transition window: sign packages + db with the NEW key while
   `astroos-keyring` ships BOTH keys (`astroos.gpg` may hold several keys,
   `astroos-trusted` lists both fingerprints); installed systems learn the
   new key through the package update before the old one disappears.
3. After one release cycle, drop the old key from the package, list its
   fingerprint in `astroos-revoked`, update `branding/REPO_FINGERPRINT`
   (the build asserts against it) and rotate the ISO signature key with it.
4. If the private key is LOST: generate new, ship the new keyring in the
   next ISO; existing installed systems must import it by hand (documented
   in the release notes). This is why the offline backup matters.

## Publish credentials

Publishing uses Azure Blob SAS tokens (write-scoped, time-boxed), generated
on the laptop (`az storage container generate-sas`) and scp'd to the VM:
`~/astroos-repo.sas` for the `repo` container (packages) and
`~/astroos-iso.sas` for the `iso` container (released ISOs), both mode 600.
No cloud credentials live in git or in the image. Rotate by generating a
fresh SAS; expiry bounds the blast radius.
