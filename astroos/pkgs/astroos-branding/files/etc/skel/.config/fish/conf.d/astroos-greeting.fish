# AstroOS terminal greeting: fastfetch with the AstroOS logo.
#
# astroos-fish-config defines the same fish_greeting in
# /usr/share/astroos-fish-config/astroos-config.fish, and config.fish sources
# that after conf.d, so where both packages are installed its definition is the
# one that wins. The bodies are identical, so the greeting is the same either
# way. This drop-in is kept because astroos-fish-config is not guaranteed: it
# sits in the installer's selectable "shell configuration" group, not in the
# pacstrap base, so a system can have fish without it and this file is then the
# only greeting. Delete both to disable.
function fish_greeting
    if command -q fastfetch
        fastfetch
    end
end
