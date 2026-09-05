# AstroOS terminal greeting — fastfetch with the AstroOS logo.
# cachyos-fish-config ships its greeting commented out, so this drop-in is
# the active fish_greeting. Delete this file to disable.
function fish_greeting
    if command -q fastfetch
        fastfetch
    end
end
