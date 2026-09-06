# AstroOS fish configuration.
# Derived from the CachyOS package of the same purpose (MIT).
# /etc/skel/.config/fish/config.fish sources this file, so it runs after
# everything in conf.d and its definitions win over theirs.

## Source from conf.d before our fish config
source /usr/share/astroos-fish-config/conf.d/done.fish

## Set values
## Run fastfetch as welcome message.
# Bare fastfetch, with no -c, resolves its configuration through the XDG
# search path, and astroos-branding puts the AstroOS one on that path twice:
# ~/.config/fastfetch/config.jsonc (from /etc/skel) and, behind it,
# /etc/xdg/fastfetch/config.jsonc. So the greeting draws the AstroOS logo
# without this file naming a path, and a configuration the user writes still
# wins over ours. astroos-branding ships the same definition in
# conf.d/astroos-greeting.fish; both call fastfetch, so which one is defined
# last does not matter. The command test keeps a shell without fastfetch
# installed from printing an error on every prompt.
function fish_greeting
    if command -q fastfetch
        fastfetch
    end
end

# Format man pages
set -x MANROFFOPT "-c"
set -x MANPAGER "sh -c 'col -bx | bat -l man -p'"

# Set settings for https://github.com/franciscolourenco/done
set -U __done_min_cmd_duration 10000
set -U __done_notification_urgency_level low

## Environment setup
# Apply .profile: use this to put fish compatible .profile stuff in
if test -f ~/.fish_profile
  source ~/.fish_profile
end

# Append common directories for executable files to $PATH
fish_add_path ~/.local/bin ~/.cargo/bin ~/Applications/depot_tools

## Functions
# Functions needed for !! and !$ https://github.com/oh-my-fish/plugin-bang-bang
function __history_previous_command
  switch (commandline -t)
  case "!"
    commandline -t $history[1]; commandline -f repaint
  case "*"
    commandline -i !
  end
end

function __history_previous_command_arguments
  switch (commandline -t)
  case "!"
    commandline -t ""
    commandline -f history-token-search-backward
  case "*"
    commandline -i '$'
  end
end

if [ "$fish_key_bindings" = fish_vi_key_bindings ];
  bind -Minsert ! __history_previous_command
  bind -Minsert '$' __history_previous_command_arguments
else
  bind ! __history_previous_command
  bind '$' __history_previous_command_arguments
end

# Fish command history
function history
    builtin history --show-time='%F %T ' $argv
end

function backup --argument filename
    cp $filename $filename.bak
end

# Copy DIR1 DIR2
function copy
    set count (count $argv | tr -d \n)
    if test "$count" = 2; and test -d "$argv[1]"
        set from (echo $argv[1] | trim-right /)
        set to (echo $argv[2])
        command cp -r $from $to
    else
        command cp $argv
    end
end

## Useful aliases
# Replace ls with eza
alias ls='eza -al --color=always --group-directories-first --icons=always' # preferred listing
alias la='eza -a --color=always --group-directories-first --icons=always'  # all files and dirs
alias ll='eza -l --color=always --group-directories-first --icons=always'  # long format
alias lt='eza -aT --color=always --group-directories-first --icons=always' # tree listing
alias l.="eza -a | grep -e '^\.'"                                     # show only dotfiles

# Common use
alias grubup="sudo grub-mkconfig -o /boot/grub/grub.cfg"
alias fixpacman="sudo rm /var/lib/pacman/db.lck"
alias tarnow='tar -acf '
alias untar='tar -zxvf '
alias wget='wget -c '
alias psmem='ps auxf | sort -nr -k 4'
alias psmem10='ps auxf | sort -nr -k 4 | head -10'
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias .....='cd ../../../..'
alias ......='cd ../../../../..'
alias dir='dir --color=auto'
alias vdir='vdir --color=auto'
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'
alias hw='hwinfo --short'                                   # Hardware Info
alias big="expac -H M '%m\t%n' | sort -h | nl"              # Sort installed packages according to size in MB
alias gitpkg='pacman -Q | grep -i "\-git" | wc -l'          # List amount of -git packages
alias update='sudo astroos-rate-mirrors && sudo pacman -Syu'

# Get fastest mirrors
alias mirror="sudo astroos-rate-mirrors"

# Help people new to Arch
alias apt='man pacman'
alias apt-get='man pacman'
alias tb='nc termbin.com 9999'

# Cleanup orphaned packages
alias cleanup='sudo pacman -Rns (pacman -Qtdq)'

# Get the error messages from journalctl
alias jctl="journalctl -p 3 -xb"

# Recent installed packages
alias rip="expac --timefmt='%Y-%m-%d %T' '%l\t%n %v' | sort | tail -200 | nl"

## Colours
# One palette across the whole system (astroos/branding/PALETTE.md). fish wants
# a bare hex value with no leading #, so the role name goes in the comment.
#
# Why this is not written as "set -q fish_color_command; or set -g ...": fish 4
# applies its built-in theme from share/config.fish with
# "fish_config theme choose default --no-override", before conf.d and before
# this file, so every fish_color_* is already set by the time we run and a
# set -q guard would never fire. That theme marks each variable it writes
# with a trailing --theme=default element (share/functions/fish_config.fish),
# which is how fish itself tells its own defaults apart from a value a person
# chose. This does the same: repaint an unset variable or one a theme wrote,
# and never one the user set.
function __astroos_color --argument-names var
    set -l current $$var
    if set -q $var; and test (count $current) -gt 0
        string match -q -- '--theme=*' $current[-1]; or return 0
    end
    set -g $var $argv[2..]
end

__astroos_color fish_color_command       e8e6f5                      # text
__astroos_color fish_color_param         c8c4de                      # text_sub
__astroos_color fish_color_quote         2cb8ab                      # teal
__astroos_color fish_color_operator      4ac0da                      # cyan
__astroos_color fish_color_redirection   62e2ec                      # cyan_hi
__astroos_color fish_color_end           4ac0da                      # cyan
__astroos_color fish_color_error         e0679a                      # rose
__astroos_color fish_color_comment       9692b2                      # text_dim
__astroos_color fish_color_autosuggestion 6b6688                     # text_disabled
__astroos_color fish_color_valid_path    4ac0da --underline          # cyan
__astroos_color fish_color_selection     --background=8658b4         # lavender
__astroos_color fish_color_search_match  --background=8658b4         # lavender
__astroos_color fish_color_cwd           a679c9                      # lavender_hi
__astroos_color fish_color_user          c8c4de                      # text_sub
__astroos_color fish_color_host          c8c4de                      # text_sub
__astroos_color fish_color_cancel        e0679a                      # rose
__astroos_color fish_pager_color_prefix  a679c9                      # lavender_hi
__astroos_color fish_pager_color_progress f8e2f6 --background=8658b4 # selection_text on lavender
__astroos_color fish_pager_color_selected_background --background=8658b4 # lavender

# The pure prompt (fish-pure-prompt is a depends). Its own conf.d sets every
# pure_color_* universally at shell start, through _pure_set_default's
# "set --universal", so these are always set here too and carry no theme
# marker to test. Repaint only a value that is still pure's shipped default
# (conf.d/pure.fish, documented in docs/components/colours.md); anything else
# is a choice somebody made. pure resolves one colour variable naming another,
# so setting the base colours reaches the derived ones too: a caller
# passes the value ("pure_color_primary") and _pure_set_color dereferences it.
function __astroos_pure_color --argument-names var default
    set -l current (string join ' ' -- $$var)
    test "$current" = "$default"; or return 0
    set -g $var $argv[3..]
end

__astroos_pure_color pure_color_primary blue    a679c9  # lavender_hi, cwd
__astroos_pure_color pure_color_success magenta 2cb8ab  # teal, prompt after success
__astroos_pure_color pure_color_danger  red     e0679a  # rose, prompt after error, exit status
__astroos_pure_color pure_color_mute    brblack 9692b2  # text_dim, git, host, venv
__astroos_pure_color pure_color_info    cyan    4ac0da  # cyan, unpulled and unpushed commits
__astroos_pure_color pure_color_warning yellow  e2b46a  # amber, command duration, aws profile
__astroos_pure_color pure_color_light   white   e8e6f5  # text, root's username
# pure_color_normal stays "normal" so jobs print in the terminal's own
# foreground, and pure_color_dark is left alone: nothing in pure inherits it.

functions --erase __astroos_color __astroos_pure_color
