#!/usr/bin/env bash
# Runs INSIDE the audit container (forge.sh stage_audit mounts it): does pacman
# accept, on a system that looks like a freshly pacstrapped CachyOS target, the
# package set the AstroOS installer installs by default?
#
# Why a real transaction and not --print: `pacman -S --print` skips the
# conflict questions entirely (it happily prints core/zlib on a zlib-ng-compat
# base with exit 0), while the installer's `pacman -S --noconfirm` answers
# every conflict question with "no" and dies. So the check runs the same
# non-interactive transaction with the downloader replaced by /usr/bin/false:
# dependency resolution and conflict checks happen in the prepare phase, the
# commit phase then fails on the first download, and the error text says which
# phase failed. Prepare-phase errors are audit failures.
#
# Mounts: /iso-pacman.conf, /iso-pacman.d, /iso-keyrings, /iso-modules
# (etc/calamares/modules with netinstall.yaml and pacstrap.conf) and
# /iso-pacstrap-main.py (the pacstrap module, whose code adds the bootloader,
# filesystem, microcode and platform packages the YAML never lists).
set -u
cp /iso-pacman.d/*mirrorlist /etc/pacman.d/ 2>/dev/null || true
cp /iso-keyrings/* /usr/share/pacman/keyrings/
pacman-key --init >/dev/null 2>&1
pacman-key --populate >/dev/null 2>&1
cp /iso-pacman.conf /etc/pacman.conf
# pacman 7 drops to the alpm user under Landlock for downloads; neither is
# available in an unprivileged container, and the resolver does not care
sed -i -e "/^DownloadUser/d" -e "s/^\[options\]/[options]\nDisableSandbox/" /etc/pacman.conf
pacman -Sy >/dev/null 2>&1 || { echo "!! pacman -Sy with the ISO pacman.conf failed"; exit 1; }
pacman -S --noconfirm --needed python-yaml >/dev/null 2>&1 || { echo "!! python-yaml unavailable"; exit 1; }
# the installer's base set replaces zlib with zlib-ng-compat (--ask=4 answers the removal)
pacman -S --noconfirm --ask=4 zlib-ng-compat >/dev/null 2>&1 || { echo "!! could not install zlib-ng-compat"; exit 1; }

# The default selection: pacstrap basePackages, every netinstall group that is
# selected by default (the AstroOS and BlackArch groups among them) and the
# KDE group the Desktop page picks for the shipped Plasma default.
python3 - <<'PY' > /tmp/names || { echo "!! could not read the installer package lists"; exit 1; }
import yaml
names = set()
ps = yaml.safe_load(open("/iso-modules/pacstrap.conf"))
for p in ps.get("basePackages", []) or []:
    names.add(p if isinstance(p, str) else p.get("name"))
ni = yaml.safe_load(open("/iso-modules/netinstall.yaml"))
if isinstance(ni, dict):
    ni = ni.get("groups", [])
def walk(g, sel):
    s = sel or bool(g.get("selected")) or g.get("name") == "KDE-Desktop"
    if s:
        for p in g.get("packages", []) or []:
            names.add(p if isinstance(p, str) else p.get("name"))
    for sg in g.get("subgroups", []) or []:
        walk(sg, s)
for g in ni:
    walk(g, False)
# The pacstrap module adds packages in code, per bootloader, filesystem,
# CPU vendor and platform choice (base_packages += [...] and .append(...)):
# every name it can add is resolved here, whatever the page choices, because
# a user can make any of them and the 2026-09-06 install died on exactly one
# of these sets (Limine + btrfs: limine-entry-tool, limine-snapper-sync).
import re
src = open("/iso-pacstrap-main.py").read()
for line in src.splitlines():
    if "base_packages" in line and ("+=" in line or ".append(" in line):
        for n in re.findall(r'"([a-z0-9][a-z0-9@._+-]*)"', line):
            names.add(n)
# Calamares expands $LOCALE at install time (the language pack group); the
# shipped default is American English
for n in sorted(x.replace("$LOCALE", "en-us") for x in names if x):
    print(n)
PY
grep -qx limine-entry-tool /tmp/names || { echo "!! the pacstrap module's bootloader packages were not read"; exit 1; }
n=$(wc -l < /tmp/names)
(( n > 100 )) || { echo "!! only $n names selected from the installer lists"; exit 1; }
grep -qx geant4 /tmp/names || { echo "!! the AstroOS repository group is not in the default selection"; exit 1; }

# now block every download and run the installer's transaction shape
sed -i "s|^DisableSandbox$|DisableSandbox\nXferCommand = /usr/bin/false %u %o|" /etc/pacman.conf
mapfile -t names < /tmp/names
pacman -S --noconfirm --needed "${names[@]}" > /tmp/r.out 2>&1
rc=$?
if (( rc == 0 )); then echo "!! transaction unexpectedly succeeded with downloads blocked"; exit 1; fi
# Reaching the download stage means the prepare phase (dependencies, provider
# choice, conflicts) accepted the whole set; "removing X from target list
# because it conflicts with Y" is pacman resolving a dependency candidate
# against an installed or selected provider and is not an error (the real
# install prints the same for blas/cblas/lapack against blas-openblas).
if grep -qE "failed to retrieve some files|failed retrieving file|failed to commit transaction" /tmp/r.out; then
  w=$(grep -c "removing .* from target list because it conflicts" /tmp/r.out || true)
  echo "resolver accepted all $n default-selection names on a zlib-ng-compat base ($w candidate conflicts auto-resolved, downloads blocked by design)"
  exit 0
fi
echo "!! prepare phase failed for the default selection ($n names):"
grep -E "unresolvable|failed to prepare|target not found|could not satisfy|are in conflict|error:" /tmp/r.out | head -8
exit 1
