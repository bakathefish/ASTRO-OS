# AstroOS terminal greeting: fastfetch with the AstroOS logo.
# cachyos-fish-config defines its own fish_greeting (also fastfetch) and
# config.fish sources it after conf.d, so that definition wins; both read the
# AstroOS fastfetch config, so the greeting is branded either way. This
# drop-in keeps the greeting if the CachyOS config is ever removed. Delete
# both to disable.
function fish_greeting
    if command -q fastfetch
        fastfetch
    end
end
