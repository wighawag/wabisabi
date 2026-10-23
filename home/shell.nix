{ lib, pkgs, config, ... }:

# The user's CLI toolkit. The interactive SHELL itself is not here: it is the
# system layer's bash stack (modules/services/interactive-shell.nix: ble.sh,
# fzf, zoxide, atuin, starship), box-wide in /etc/bashrc, because that is the
# shell every account actually lands in. This layer used to configure zsh,
# starship, fzf and direnv for zsh, but nothing ever made zsh a login shell and
# home-manager hooks none of them into bash unless its own bash module is on,
# so a terminal opened plain bash and all of it was dead configuration. direnv,
# eza and bat moved to the system layer with the shell (modules/core.nix).

let cfg = config.wabisabi; in
lib.mkIf cfg.enable {
  home.packages = with pkgs; [
    unzip
    fastfetch
  ];
}
