{ lib, pkgs, config, ... }:

# Hardware-agnostic system base: everything a desktop needs that is NOT
# drivers, filesystems or firmware. Every value is mkDefault so the
# importing config always wins.

let cfg = config.wabisabi; in
lib.mkIf cfg.enable {
  nix.settings = {
    experimental-features = lib.mkDefault [ "nix-command" "flakes" ];
    auto-optimise-store = lib.mkDefault true;
  };

  time.timeZone = lib.mkDefault cfg.timeZone;
  i18n.defaultLocale = lib.mkDefault cfg.locale;

  # Keyboard layout, for the desktop AND for the two text consoles.
  #
  # These are `services.xserver.xkb.*` and there is no X server here. The
  # option names are historical: nixpkgs' `services.graphical-desktop` module
  # (enabled for us by greetd, through services.displayManager) renders them
  # into /etc/X11/xorg.conf.d/00-keyboard.conf, systemd-localed reads that
  # file, and niri asks localed because home/desktop.nix leaves its own xkb
  # block empty. So this is the single source of truth, as a declarative
  # option rather than a `localectl set-x11-keymap` run that no rebuild can
  # reproduce.
  #
  # `console.useXkbConfig` then derives the VT keymap from the same values,
  # which is what makes the initrd LUKS passphrase prompt agree with the
  # keyboard the passphrase was chosen on.
  services.xserver.xkb = {
    layout = lib.mkDefault cfg.keyboard.layout;
    variant = lib.mkDefault cfg.keyboard.variant;
    options = lib.mkDefault cfg.keyboard.options;
  };
  console.useXkbConfig = lib.mkDefault true;

  # Fonts: the nerd font the home layer names (ghostty, foot, waybar all ask
  # for "JetBrainsMono Nerd Font"), plus a Noto fallback for CJK/emoji so
  # nothing renders as tofu.
  #
  # NOT mkDefault, and that is the whole point of this comment. nixpkgs
  # defines its own base font list (dejavu, liberation, noto, gyre, ...) at
  # NORMAL priority, and `fonts.packages` is a list: a normal-priority
  # definition does not merge with a mkDefault one, it DISCARDS it. So with
  # mkDefault here the nerd font silently never got installed, fontconfig
  # substituted DejaVu Sans, and terminals rendered a PROPORTIONAL font --
  # visibly ragged, with foot warning "font does not appear to be monospace"
  # on every launch. The demo VM had it too.
  #
  # Declared at normal priority these MERGE with the nixpkgs list, which is
  # what a list option should do. A consumer who genuinely wants to drop them
  # still can, with mkForce.
  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-color-emoji
  ];

  # Modern audio stack (PulseAudio API + ALSA + JACK compat).
  services.pipewire = lib.mkDefault {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # Everything else a desktop session expects from the system.
  services = {
    gvfs.enable = lib.mkDefault true;     # trash/mounts for file managers
    upower.enable = lib.mkDefault true;    # battery reporting
    printing.enable = lib.mkDefault cfg.printing.enable;  # CUPS
  };

  # Avahi IS the discovery half of printing, not a nicety beside it: with no
  # declarative queue, DNS-SD is the ONLY way CUPS learns a printer exists.
  # Without this, CUPS runs happily and the print dialog is simply empty, which
  # reads as "printing is broken" and sends people looking for a driver -- the
  # exact dead end driverless setup is meant to avoid.
  #
  # nssmdns4 additionally resolves <name>.local through NSS, so the printer is
  # reachable by identity rather than by whatever address DHCP handed it today.
  services.avahi = lib.mkIf cfg.printing.enable (lib.mkDefault {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;  # UDP 5353, or nothing is ever discovered
  });

  # GPU accel + dconf for GTK settings + portals for Wayland desktop glue.
  hardware.graphics.enable = lib.mkDefault true;
  programs.dconf.enable = lib.mkDefault true;

  # Portals: the compositor module (programs.niri) already adds the gnome
  # portal and the interface routing it wants. We only add the GTK portal,
  # which is the generic fallback for file chooser, print and settings.
  # Assign per-leaf rather than wrapping the namespace in one mkDefault:
  # extraPortals is a list, so this merges with the compositor's instead of
  # racing it.
  xdg.portal.enable = lib.mkDefault true;
  xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-gtk ];

  # Compressed-RAM swap: safe on any machine, no partition required.
  zramSwap.enable = lib.mkDefault cfg.zram.enable;

  # Binaries built for other distributions (see wabisabi.nixLd). The default
  # library set only; add to programs.nix-ld.libraries when a binary names one.
  programs.nix-ld.enable = lib.mkIf cfg.nixLd.enable (lib.mkDefault true);

  # zellij with the declared keybinds. ZELLIJ_CONFIG_FILE rather than only the
  # /etc copy, because zellij reads ~/.config/zellij/config.kdl BEFORE /etc, so
  # a file its first-run wizard once wrote would otherwise silently win. Both
  # at mkDefault, so a machine that ships its own zellij config replaces this
  # one instead of conflicting with it.
  environment.etc."zellij/config.kdl".source = lib.mkIf cfg.zellij.enable (
    lib.mkDefault ./zellij-config.kdl
  );
  environment.variables.ZELLIJ_CONFIG_FILE = lib.mkIf cfg.zellij.enable (
    lib.mkDefault "/etc/zellij/config.kdl"
  );

  # The interactive bash stack (nixos-modules' modules/interactive-shell.nix).
  nixos-modules.interactiveShell.enable = lib.mkDefault cfg.bash.enable;

  # What goes with that shell, for every account: direnv with nix-direnv
  # (per-project dev environments; NixOS's own module hooks it into bash), and
  # eza/bat behind the familiar names. Aliases only exist in interactive
  # shells, so scripts and agents' tool shells still get the real ls and cat.
  #
  # mkOverride 900, not mkDefault: NixOS already sets `ls`/`ll` at mkDefault,
  # and two mkDefault strings are a conflict. 900 beats that default while
  # anything a machine writes (priority 100) still wins.
  programs.direnv = lib.mkIf cfg.bash.enable {
    enable = lib.mkDefault true;
    nix-direnv.enable = lib.mkDefault true;
  };
  # On the Linux text console the icons draw as boxes (no Nerd Font there),
  # so the same commands without them.
  programs.bash.interactiveShellInit = lib.mkIf cfg.bash.enable (
    lib.mkAfter ''
      if [[ $TERM == linux ]]; then
        alias ls='eza --group-directories-first' ll='eza -la --git'
      fi
    ''
  );
  environment.shellAliases = lib.mkIf cfg.bash.enable (
    lib.mapAttrs (_: lib.mkOverride 900) {
      ls = "eza --icons --group-directories-first";
      ll = "eza -la --icons --git";
      cat = "bat --style=plain";
      g = "git";
      nrs = "sudo nixos-rebuild switch --flake";
    }
  );

  # mtr through its NixOS module rather than as a bare package: the module
  # installs it with the capability raw ICMP needs, so it works without sudo.
  programs.mtr.enable = lib.mkDefault true;

  # Small opinionated CLI base for any TTY session: what you reach for to look
  # at files, processes, the network and JSON, on any machine, before there is
  # a project or a dev shell around you.
  environment.systemPackages = with pkgs; [
    git
    lazygit
    curl
    wget
    ripgrep
    fd
    tree
    btop
    htop
    tmux
    micro       # a terminal editor with the keys everyone already knows
    jq
    yq-go       # jq for YAML (and TOML, XML)
    zip
    unzip
    lsof
    nmap
    tcpdump
    inotify-tools
  ]
  ++ lib.optionals cfg.bash.enable [
    eza
    bat
  ]
  ++ lib.optional cfg.zellij.enable zellij;
}