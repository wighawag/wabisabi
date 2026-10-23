{ lib, pkgs, config, ... }:

# Terminal + editors.

let
  cfg = config.wabisabi;

  # The palette, from theme/palettes.nix via `wabisabi.theme`. Catppuccin
  # keeps the themes its apps bundle; sumi is spelled out, once per terminal,
  # from the same 16 colours.
  c = (import ../theme/palettes.nix).${cfg.theme};
  sumi = cfg.theme == "sumi";
  ansi = i: lib.elemAt c.ansi i;
in
lib.mkIf cfg.enable {
  programs.ghostty = lib.mkIf (cfg.terminal == "ghostty") {
    enable = true;
    settings = {
      font-family = "JetBrainsMono Nerd Font";
      font-size = 11;
      # Catppuccin is bundled with ghostty; sumi is defined below. HM validates
      # the name at build time either way.
      theme = if sumi then "wabisabi-sumi" else "Catppuccin Mocha";
      background-opacity = 0.95;
      confirm-close-surface = false;
      copy-on-select = "clipboard";
      # Ghostty's bash integration is loaded by the system bashrc instead
      # (nixos-modules' interactive-shell, just before ble-attach), with the
      # same features (cursor, path, title), since this still exports them.
      # Injected, it made ble.sh defer its attach and every new window opened
      # on a doubled first prompt.
      shell-integration = "none";
    };
    themes = lib.mkIf sumi {
      wabisabi-sumi = {
        background = "#${c.base}";
        foreground = "#${c.text}";
        cursor-color = "#${c.bright}";
        cursor-text = "#${c.base}";
        selection-background = "#${c.surface2}";
        selection-foreground = "#${c.bright}";
        palette = lib.imap0 (i: v: "${toString i}=#${v}") c.ansi;
      };
    };
  };

  # kitty: GPU-accelerated like ghostty, but with a config format and a theme
  # ecosystem that predate it. Its themes ship as a separate package, so the
  # palette is set here explicitly rather than named.
  programs.kitty = lib.mkIf (cfg.terminal == "kitty") {
    enable = true;
    font = {
      name = "JetBrainsMono Nerd Font";
      size = 11;
    };
    settings = {
      background_opacity = "0.95";
      confirm_os_window_close = 0;
      copy_on_select = "clipboard";
      # The same palette as ghostty and foot, so switching terminals does not
      # switch colours.
      background = "#${c.base}";
      foreground = "#${c.text}";
      selection_background = "#${c.surface2}";
      selection_foreground = "#${c.bright}";
      cursor = "#${c.bright}";
      url_color = "#${c.info}";
    } // lib.listToAttrs (lib.imap0 (i: v: lib.nameValuePair "color${toString i}" "#${v}") c.ansi);
  };

  programs.foot = lib.mkIf (cfg.terminal == "foot") {
    enable = true;
    settings = {
      main = {
        font = "JetBrainsMono Nerd Font:size=11";
      };
      # foot 1.28 replaced the [colors] section with [colors-dark] and
      # [colors-light]. A stale [colors] is not ignored: foot refuses the
      # section and prints an error into your terminal on every launch.
      colors-dark = {
        background = c.base;
        foreground = c.text;
        regular0 = ansi 0; regular1 = ansi 1; regular2 = ansi 2; regular3 = ansi 3;
        regular4 = ansi 4; regular5 = ansi 5; regular6 = ansi 6; regular7 = ansi 7;
        bright0 = ansi 8; bright1 = ansi 9; bright2 = ansi 10; bright3 = ansi 11;
        bright4 = ansi 12; bright5 = ansi 13; bright6 = ansi 14; bright7 = ansi 15;
      };
    };
  };

  # Both editors ship; $EDITOR follows the option.
  programs.neovim = {
    enable = true;
    defaultEditor = cfg.editor == "neovim";
    withRuby = false;
    withPython3 = false;
    # Deliberately bare — users layer their config on top, or point the
    # flake at nixvim for a fully declarative config later.
  };

  programs.helix = {
    enable = true;
    defaultEditor = cfg.editor == "helix";
    settings = {
      # base16_terminal draws with the terminal's own 16 colours, so under
      # sumi Helix follows the palette above with no theme file to keep in
      # step. Catppuccin is bundled with helix.
      theme = if sumi then "base16_terminal" else "catppuccin_mocha";
      editor.cursor-shape = {
        insert = "bar";
        normal = "block";
      };
    };
  };
}