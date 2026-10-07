# cmesh BYOL hardening — /etc/profile.d/cmesh-tmout.sh
# Shell-level automatic logoff: an interactive shell idle for 15 minutes exits. sshd's
# ClientAlive settings handle a dead link; this handles a live link with nobody at it.
if [ -n "${BASH_VERSION:-}" ] || [ -n "${ZSH_VERSION:-}" ]; then
    TMOUT=900
    readonly TMOUT
    export TMOUT
fi
