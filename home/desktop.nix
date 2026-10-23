{ lib, pkgs, config, ... }:

# The desktop session: niri + Waybar + fuzzel + mako, with locking, idle,
# screenshots and recording wired up. Everything is a default the user can
# override file-by-file.
#
# niri is a scrollable-tiling compositor: windows live in columns on an
# infinite horizontal strip, and opening a window never resizes the ones
# already open. See notes/compositor-alternatives.md for why it is the
# default and what the alternatives would cost.

let
  cfg = config.wabisabi;

  # The palette, from theme/palettes.nix via `wabisabi.theme` (sumi by
  # default, Catppuccin Mocha as a choice). Compositor-independent: it themes
  # the bar, launcher, notifications, lock screen and GTK, none of which know
  # what compositor they are running under.
  c = (import ../theme/palettes.nix).${cfg.theme};
  sumi = cfg.theme == "sumi";

  # The wallpaper at a path that survives the image changing (see
  # wallpaperPath in modules/desktop.nix for why a store path will not do).
  wallpaperExt = let m = builtins.match ".*(\\.[A-Za-z0-9]+)" (toString cfg.wallpaper); in if m == null then "" else lib.head m;
  wallpaperFile = "wabisabi/wallpaper${wallpaperExt}";
  wallpaperPath = "${config.xdg.dataHome}/${wallpaperFile}";

  # Sumi for GTK3 (adw-gtk3) and GTK4 (libadwaita): their named colours.
  gtkColours = ''
    @define-color accent_color #${c.highlight};
    @define-color accent_bg_color #${c.highlight};
    @define-color accent_fg_color #${c.base};
    @define-color destructive_color #${c.urgent};
    @define-color destructive_bg_color #${c.urgent};
    @define-color destructive_fg_color #${c.base};
    @define-color success_color #${c.success};
    @define-color success_bg_color #${c.success};
    @define-color success_fg_color #${c.base};
    @define-color warning_color #${c.warning};
    @define-color warning_bg_color #${c.warning};
    @define-color warning_fg_color #${c.base};
    @define-color error_color #${c.urgent};
    @define-color error_bg_color #${c.urgent};
    @define-color error_fg_color #${c.base};
    @define-color window_bg_color #${c.base};
    @define-color window_fg_color #${c.text};
    @define-color view_bg_color #${c.mantle};
    @define-color view_fg_color #${c.text};
    @define-color headerbar_bg_color #${c.surface0};
    @define-color headerbar_fg_color #${c.text};
    @define-color headerbar_border_color #${c.surface1};
    @define-color headerbar_backdrop_color #${c.base};
    @define-color headerbar_shade_color rgba(0, 0, 0, 0.36);
    @define-color card_bg_color #${c.surface0};
    @define-color card_fg_color #${c.text};
    @define-color card_shade_color rgba(0, 0, 0, 0.36);
    @define-color dialog_bg_color #${c.surface0};
    @define-color dialog_fg_color #${c.text};
    @define-color popover_bg_color #${c.surface0};
    @define-color popover_fg_color #${c.text};
    @define-color sidebar_bg_color #${c.mantle};
    @define-color sidebar_fg_color #${c.text};
    @define-color sidebar_backdrop_color #${c.mantle};
    @define-color secondary_sidebar_bg_color #${c.crust};
    @define-color secondary_sidebar_fg_color #${c.text};
  '';

  # niri names the primary modifier once, and every bind then says "Mod".
  # That is why the binds below never interpolate the mod key.
  niriModKey = {
    SUPER = "Super";
    ALT = "Alt";
    CTRL = "Ctrl";
  }.${cfg.modKey};

  # Terminal command the binds refer to.
  # Is the cohesive shell in charge, or the five single-purpose daemons?
  noctalia = cfg.shell == "noctalia";

  # Every Noctalia action is `noctalia msg <command>`; the binary is on PATH
  # from home/noctalia.nix. Spelled through a helper so a rename is one edit.
  noc = c: "noctalia msg ${c}";

  termCmd =
    if cfg.terminal == "ghostty" then lib.getExe pkgs.ghostty
    else if cfg.terminal == "kitty" then lib.getExe pkgs.kitty
    else lib.getExe pkgs.foot;

  browserCmd =
    if cfg.browser == "firefox" then lib.getExe pkgs.firefox
    else if cfg.browser == "librewolf" then lib.getExe pkgs.librewolf
    else if cfg.browser == "chromium" then lib.getExe pkgs.chromium
    else lib.getExe pkgs.fuzzel;

  fileManagerCmd =
    if cfg.fileManager == "thunar" then lib.getExe pkgs.thunar
    else if cfg.fileManager == "nautilus" then lib.getExe pkgs.nautilus
    # yazi is a TUI: it opens IN the terminal rather than as its own window.
    else if cfg.fileManager == "yazi" then "${termCmd} -e ${lib.getExe pkgs.yazi}"
    else termCmd;

  # The shell owns locking when it is in charge; swaylock only exists in the
  # classic stack, and binding a swaylock that is not installed would be a
  # keybind that silently does nothing.
  lockCmd =
    if noctalia then noc "session lock"
    else "${lib.getExe pkgs.swaylock} -f";

  launcherCmd = if noctalia then noc "panel-toggle launcher" else lib.getExe pkgs.fuzzel;

  # Screen recording as a command, so the keybind stays clean. Screenshots
  # need no script: niri has a built-in screenshot UI that saves to
  # screenshot-path and copies to the clipboard in one action.
  recordScript = pkgs.writeShellApplication {
    name = "wabisabi-record";
    runtimeInputs = [ pkgs.wf-recorder pkgs.libnotify ];
    text = ''
      if pkill -INT wf-recorder 2>/dev/null; then
        notify-send "Recording" "Stopped"
      else
        mkdir -p "$HOME/Videos"
        wf-recorder -f "$HOME/Videos/recording-$(date +%s).mkv" &
        notify-send "Recording" "Started"
      fi
    '';
  };

  # Workspace binds, generated. niri workspaces are dynamic, so an index
  # beyond the current count lands on the bottom-most empty workspace.
  wsBinds = lib.listToAttrs (lib.concatMap (i: [
    (lib.nameValuePair "Mod+${toString i}" { focus-workspace = i; })
    (lib.nameValuePair "Mod+Shift+${toString i}" { move-column-to-workspace = i; })
  ]) (lib.range 1 9));

in
lib.mkIf cfg.enable {
  home.packages = [ recordScript ]
    ++ lib.optional (!noctalia) pkgs.fuzzel;

  # ─── niri compositor ───
  wayland.windowManager.niri = {
    enable = true;

    # Runs `niri validate` on the generated KDL as part of the build, so a
    # broken option fails `nixos-rebuild` instead of dropping you into a
    # black screen. This is the main reason niri is the default.
    checkConfig = true;

    settings = {
      input = {
        # Empty xkb block: niri reads the layout from systemd-localed, so
        # `localectl set-x11-keymap` is the single place to set it.
        keyboard.xkb = { };
        touchpad = {
          tap = { };
          natural-scroll = { };
        };
        # Primary modifier — from wabisabi.modKey (default SUPER; the demo
        # VM uses ALT because host desktops swallow Super combos before
        # QEMU sees them).
        mod-key = niriModKey;
      };

      layout = {
        gaps = 8;
        center-focused-column = "never";
        default-column-width.proportion = 0.5;
        background-color = "#${c.base}";
        focus-ring = {
          width = 2;
          active-color = "#${c.focus}";
          inactive-color = "#${c.surface1}";
        };
      };

      # Without this niri logs "error loading xcursor default@24: no default
      # icon" and falls back to a built-in cursor. It has to match
      # home.pointerCursor below.
      cursor = {
        xcursor-theme = "Bibata-Modern-Ice";
        xcursor-size = 24;
      };

      # Ask clients to drop their own title bars so niri can draw the focus
      # ring around the window rather than behind it.
      prefer-no-csd = { };

      screenshot-path = "~/Pictures/Screenshots/Screenshot from %Y-%m-%d %H-%M-%S.png";

      # The hotkey cheat sheet is genuinely useful, but not on every login.
      # Mod+Shift+Slash brings it up on demand.
      hotkey-overlay.skip-at-startup = { };

      binds = {
        # Launchers
        "Mod+Return".spawn = termCmd;
        "Mod+D".spawn-sh = launcherCmd;
        "Mod+B".spawn = browserCmd;
        "Mod+E".spawn = fileManagerCmd;

        # Windows
        "Mod+Q" = { _props.repeat = false; close-window = { }; };
        "Mod+Shift+Q".quit = { };  # shows a confirmation dialog
        "Mod+Space".toggle-window-floating = { };
        "Mod+F".fullscreen-window = { };
        "Mod+Shift+F".maximize-column = { };
        "Mod+C".center-column = { };
        "Mod+O" = { _props.repeat = false; toggle-overview = { }; };
        "Mod+Shift+Slash".show-hotkey-overlay = { };

        # Focus (vim keys + arrows). In a scrollable layout, left/right move
        # between columns and up/down move within a column.
        "Mod+H".focus-column-left = { };
        "Mod+J".focus-window-down = { };
        "Mod+K".focus-window-up = { };
        "Mod+L".focus-column-right = { };
        "Mod+Left".focus-column-left = { };
        "Mod+Down".focus-window-down = { };
        "Mod+Up".focus-window-up = { };
        "Mod+Right".focus-column-right = { };

        # Move. Ctrl rather than Shift, because Mod+Shift+L is the lock
        # bind: niri's own defaults use Ctrl here for the same reason.
        "Mod+Ctrl+H".move-column-left = { };
        "Mod+Ctrl+J".move-window-down = { };
        "Mod+Ctrl+K".move-window-up = { };
        "Mod+Ctrl+L".move-column-right = { };

        # Column shaping — the part that has no equivalent in a classic tiler.
        "Mod+R".switch-preset-column-width = { };
        "Mod+Minus".set-column-width = "-10%";
        "Mod+Equal".set-column-width = "+10%";
        "Mod+BracketLeft".consume-or-expel-window-left = { };
        "Mod+BracketRight".consume-or-expel-window-right = { };
        "Mod+W".toggle-column-tabbed-display = { };

        # Workspaces (vertical), beyond the numbered binds below.
        "Mod+U".focus-workspace-down = { };
        "Mod+I".focus-workspace-up = { };

        # Screenshots: built-in, interactive, saves to disk and clipboard.
        "Mod+Shift+S".screenshot = { };
        "Print".screenshot-screen = { };
        "Alt+Print".screenshot-window = { };

        # Recording / lock / monitors off
        "Mod+Shift+R".spawn = lib.getExe recordScript;
        "Mod+Shift+L".spawn-sh = lockCmd;
        "Mod+Shift+P".power-off-monitors = { };

        # Escape hatch for apps that grab the keyboard (remote desktop, KVM).
        "Mod+Escape" = {
          _props.allow-inhibiting = false;
          toggle-keyboard-shortcuts-inhibit = { };
        };

        # Media keys — allow-when-locked so they work on the lock screen.
        "XF86AudioPlay" = { _props.allow-when-locked = true; spawn = [ (lib.getExe pkgs.playerctl) "play-pause" ]; };
        "XF86AudioNext" = { _props.allow-when-locked = true; spawn = [ (lib.getExe pkgs.playerctl) "next" ]; };
        "XF86AudioPrev" = { _props.allow-when-locked = true; spawn = [ (lib.getExe pkgs.playerctl) "previous" ]; };
        "XF86AudioMute" = { _props.allow-when-locked = true; spawn = [ (lib.getExe pkgs.pamixer) "-t" ]; };
        "XF86AudioMicMute" = { _props.allow-when-locked = true; spawn = [ (lib.getExe pkgs.pamixer) "--default-source" "-t" ]; };

        # Volume / brightness — these repeat while held.
        "XF86AudioRaiseVolume" = { _props.allow-when-locked = true; spawn = [ (lib.getExe pkgs.pamixer) "-i" "5" ]; };
        "XF86AudioLowerVolume" = { _props.allow-when-locked = true; spawn = [ (lib.getExe pkgs.pamixer) "-d" "5" ]; };
        "XF86MonBrightnessUp" = { _props.allow-when-locked = true; spawn = [ (lib.getExe pkgs.brightnessctl) "set" "+5%" ]; };
        "XF86MonBrightnessDown" = { _props.allow-when-locked = true; spawn = [ (lib.getExe pkgs.brightnessctl) "set" "5%-" ]; };
      }
      // wsBinds
      # The surfaces that only exist when the cohesive shell is in charge.
      # Deliberately NOT invented: these are upstream's documented IPC
      # commands (docs.noctalia.dev/noctalia/ipc).
      // lib.optionalAttrs noctalia {
        "Mod+S".spawn-sh = noc "panel-toggle control-center";
        "Mod+Comma".spawn-sh = noc "settings-toggle";
        "Mod+V".spawn-sh = noc "panel-toggle clipboard";
        "Mod+Period".spawn-sh = noc "panel-toggle emoji";
        "Alt+Tab".spawn-sh = noc "window-switcher";
      };
    }
    # Animations are a full-screen redraw. On a GPU that is free; under
    # llvmpipe (the demo VM, or a machine with no accelerated driver) it is
    # the difference between smooth and unusable.
    // lib.optionalAttrs (!cfg.animations) { animations.off = { }; };
  };

  # ─── Session services ───
  # All of these are plain systemd user units bound to graphical-session
  # .target, which niri-session starts. Nothing is spawned by the compositor,
  # so the session survives restarting the compositor and each piece can be
  # replaced without touching the niri config.
  services.polkit-gnome.enable = true;   # authentication agent
  services.blueman-applet.enable = true;

  # ─── Waybar ───
  programs.waybar = lib.mkIf (!noctalia) {
    enable = true;
    systemd.enable = true;
    settings.mainBar = {
      layer = "top";
      position = "top";
      height = 32;
      modules-left = [ "niri/workspaces" ];
      modules-center = [ "clock" ];
      modules-right = [
        "tray"
        "bluetooth"
        "network"
        "pulseaudio"
        "battery"
      ];
      "niri/workspaces".format = "{index}";
      clock.format = "{:%H:%M}";
      bluetooth.format = "  {status}";
      bluetooth.format-connected = " {num_connections}";
      network.format-wifi = "  {essid}";
      network.format-ethernet = "󰈀 {ipaddr}";
      network.format-disconnected = "󰖪 offline";
      pulseaudio.format = "{icon} {volume}%";
      pulseaudio.format-icons = {
        headphone = "🎧";
        default = [ "🔈" "🔉" "🔊" ];
      };
      battery.format = "{capacity}% {icon}";
      battery.format-icons = [ "" "" "" "" "" "" ];
      battery.states = {
        warning = 20;
        critical = 10;
      };
    };
    style = ''
      * {
        font-family: "JetBrainsMono Nerd Font";
        font-size: 13px;
        border: none;
        min-height: 0;
      }
      window#waybar {
        background: alpha(#${c.base}, 0.9);
        color: #${c.text};
      }
      #workspaces button {
        padding: 0 8px;
        color: #${c.overlay0};
      }
      #workspaces button.focused {
        color: #${c.highlight};
      }
      #workspaces button.active {
        color: #${c.subtext};
      }
      #workspaces button.urgent {
        color: #${c.urgent};
      }
      #battery.warning { color: #${c.warning}; }
      #battery.critical { color: #${c.urgent}; }
      #clock { font-weight: bold; color: #${c.highlight}; }
      widget > * { padding: 0 6px; }
    '';
  };

  # ─── Notifications ───
  services.mako = lib.mkIf (!noctalia) {
    enable = true;
    settings = {
      anchor = "top-right";
      background-color = "#${c.base}EE";
      text-color = "#${c.text}";
      border-color = "#${c.info}";
      border-radius = 8;
      border-size = 1;
      default-timeout = 4000;
    };
  };

  # ─── Launcher ───
  xdg.configFile."fuzzel/fuzzel.ini" = lib.mkIf (!noctalia) { text = ''
    [main]
    font=JetBrainsMono Nerd Font:size=11
    terminal=${termCmd}
    layer=top
    [colors]
    background=${c.base}ee
    text=${c.text}ff
    match=${c.highlight}ff
    selection=${c.surface0}ff
    selection-text=${c.text}ff
    border=${c.info}ff
  ''; };

  # ─── Lock screen ───
  # swaylock speaks ext-session-lock-v1, so it is not tied to any compositor.
  # It needs security.pam.services.swaylock on the system side (see
  # ../modules/desktop.nix) or it can never accept your password.
  programs.swaylock = lib.mkIf (!noctalia) {
    enable = true;
    settings = {
      daemonize = true;
      show-failed-attempts = true;
      # The wallpaper behind the ring, as on the Noctalia lock screen; `color`
      # stays as what shows if the image cannot be read.
      image = wallpaperPath;
      scaling = "fill";
      indicator-radius = 100;
      indicator-thickness = 8;
      color = c.base;
      inside-color = c.surface0;
      inside-ver-color = c.surface0;
      inside-wrong-color = c.surface0;
      ring-color = c.surface1;
      ring-ver-color = c.info;
      ring-wrong-color = c.urgent;
      key-hl-color = c.highlight;
      bs-hl-color = c.urgent;
      text-color = c.text;
      text-ver-color = c.text;
      text-wrong-color = c.text;
      line-color = "00000000";
      separator-color = "00000000";
    };
  };

  # ─── Idle: lock at 5min, screen off at 10, suspend at 15 ───
  # swayidle speaks ext-idle-notify-v1, also compositor-independent. The
  # `lock` and `before-sleep` events mean loginctl lock-session and suspend
  # both go through the same locker.
  services.swayidle = lib.mkIf (!noctalia) {
    enable = true;
    timeouts = [
      { timeout = 300; command = lockCmd; }
      {
        timeout = 600;
        command = "${lib.getExe pkgs.niri} msg action power-off-monitors";
      }
      { timeout = 900; command = "${pkgs.systemd}/bin/systemctl suspend"; }
    ];
    events = {
      before-sleep = lockCmd;
      lock = lockCmd;
    };
  };

  # ─── Cursor ───
  # home.pointerCursor (rather than gtk.cursorTheme alone) also exports
  # XCURSOR_THEME/XCURSOR_SIZE and links the theme into ~/.icons, which is
  # what the compositor itself reads.
  home.pointerCursor = {
    enable = true;
    name = "Bibata-Modern-Ice";
    package = pkgs.bibata-cursors;
    size = 24;
    gtk.enable = true;
  };

  # ─── GTK theme ───
  # Sumi has no GTK theme of its own, and does not need one: adw-gtk3 is
  # libadwaita's look for GTK3 apps, and both it and libadwaita draw from
  # NAMED colours that a user stylesheet can redefine. So one list of
  # @define-color lines, written for GTK3 and GTK4 alike, recolours Thunar
  # and Nautilus the same way. The accent is the palette's highlight (ochre),
  # the colour of the current workspace and the launcher's match.
  gtk = {
    enable = true;
    theme =
      if sumi then {
        name = "adw-gtk3-dark";
        package = pkgs.adw-gtk3;
      } else {
        name = "Catppuccin-Mocha-Standard-Mauve-Dark";
        package = pkgs.catppuccin-gtk;
      };
    iconTheme = {
      name = "Papirus-Dark";
      package = pkgs.papirus-icon-theme;
    };
    gtk3.extraCss = lib.mkIf sumi gtkColours;
    gtk4.extraCss = lib.mkIf sumi gtkColours;
  };

  # libadwaita ignores the GTK theme name and asks for a colour scheme
  # instead. Both palettes are dark. (Noctalia sets the same key from its own
  # mode; this is what the classic shell gets.)
  dconf.settings."org/gnome/desktop/interface".color-scheme = "prefer-dark";

  # ─── Wallpaper ───
  # A stable path for it: Noctalia's seeded config and swaylock point here.
  xdg.dataFile.${wallpaperFile}.source = cfg.wallpaper;

  # Under the classic shell nothing else draws a wallpaper, so swaybg does,
  # as a user service bound to the session like the rest of the stack.
  systemd.user.services.swaybg = lib.mkIf (!noctalia) {
    Unit = {
      Description = "Wallpaper";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "${lib.getExe pkgs.swaybg} --mode fill --color '#${c.base}' --image ${wallpaperPath}";
      Restart = "on-failure";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
