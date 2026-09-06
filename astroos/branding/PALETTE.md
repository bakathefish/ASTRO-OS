# The AstroOS colour scheme

One palette, every surface. `palette.py` is the source of truth; this page says
how it is applied and why it looks the way it does. `palette-check.py` proves a
themed file uses nothing else.

## Where it comes from

The brand already existed in two generators: `logo.py` (the sphere, the band,
the glow) and `assetgen.py` (the deep-space gradient behind the wallpaper, the
login background and the installer slides, and the text colours drawn over
them). The scheme takes every colour from those two files and adds only the
two semantic hues a desktop cannot do without, an amber for warnings and a rose
for errors, both muted so they read as part of the same space.

## The idea

Dark, indigo-cast, quiet. Backgrounds are the space gradient stepped up in
lightness (`view` < `window` < `button`), never neutral grey, so a window sits
on the wallpaper instead of floating over it. One accent, the logo's lavender
(`lavender`, focus ring `lavender_hi`, hover `orchid`), carries selection,
progress and focus everywhere. Cyan (`cyan`, `cyan_hi`) is reserved for links
and attention, teal for success. Nothing on its own announces the brand; the
consistency does.

## Roles

| role | hex | goes on |
|---|---|---|
| space_top / space_bottom | #03020a / #0e0820 | boot splash, GRUB, ksplash gradient; lock and logout overlays |
| view | #120e22 | text views, lists, editors, terminal background |
| window | #1b1630 | window chrome, dialogs, panel, ANSI black |
| button | #28223f | buttons, raised surfaces, inputs |
| header | #161129 | title bars, header bars, System Settings and Discover sidebars |
| tooltip | #231c3a | tooltips, popups |
| line | #332b4f | separators, frames |
| text / text_sub / text_dim / text_disabled | #e8e6f5 / #c8c4de / #9692b2 / #6b6688 | text in four weights |
| selection_text | #f8e2f6 | text over a lavender selection |
| lavender / lavender_hi / orchid / pink | #8658b4 / #a679c9 / #c99cdc / #e29ef0 | selection and accent, focus, hover, visited |
| cyan / cyan_hi | #4ac0da / #62e2ec | links, active and attention text |
| teal / teal_hi | #2cb8ab / #5fd6c9 | positive, ANSI green |
| indigo / indigo_hi | #7c6bd0 / #9c8ce6 | ANSI blue |
| amber / amber_hi | #e2b46a / #f0cb8c | neutral and warning, ANSI yellow |
| rose / rose_hi | #e0679a / #f08ab5 | negative and error, ANSI red |

Contrast on the darkest surfaces: `text` on `view` is about 15:1, `text_dim` on
`window` about 5.8:1, `cyan` on `view` about 8.7:1, `selection_text` on
`lavender` about 4.2:1 (WCAG AA for large or bold text is 3:1; that pair only
ever carries a selected sidebar step, a pressed button or a shell selection,
all bold or transient, never running text).

## Surfaces and their owners

| surface | mechanism | package |
|---|---|---|
| every Qt/KDE window, System Settings and Discover sidebars, title bars, Plasma panel and widgets | `/usr/share/color-schemes/AstroOS.colors`; the Breeze desktop theme in "follow colour scheme" mode | astroos-theme |
| Global Theme entry, login splash (ksplash), defaults for cursor, icons, wallpaper | look-and-feel package `org.astroos.desktop` | astroos-theme |
| terminal | Konsole colour scheme + default profile `AstroOS` | astroos-theme (+ skel konsolerc in astroos-kde-settings) |
| boot splash | Plymouth theme `astroos` (two-step, space gradient, lavender progress, watermark) | astroos-theme |
| GRUB menu on installed systems | `/usr/share/grub/themes/astroos/theme.txt` | astroos-grub-theme (pulled in with grub by the installer) |
| GRUB menu on the live medium | the same theme, staged into the profile | container-build.sh |
| Limine menu | palette written into limine.conf by the installer's bootloader module | astroos-calamares (apply.sh) |
| login screen (SDDM Breeze theme) | greeter kdeglobals `ColorScheme=AstroOS`, background already ours | astroos-branding |
| installer | branding.desc sidebar colours, stylesheet.qss | astroos-calamares |
| GTK apps | kde-gtk-config derives GTK colours from the active scheme | nothing to ship |
| fish prompt and fastfetch | palette colours in astroos-config.fish and config.jsonc | astroos-fish-config, astroos-branding |
| defaults for new users | skel kdeglobals `ColorScheme=AstroOS`, `LookAndFeelPackage=org.astroos.desktop` | astroos-kde-settings |

## Checking

`python3 astroos/branding/palette-check.py <files or directories>` scans for
`#rrggbb`, `0xrrggbb`, KDE `key=r,g,b` and Limine `term_*` values and fails on
any colour not in `palette.py`. The checks workflow runs it over every themed
file; forge.sh's audit runs it over the files extracted from the ISO.
