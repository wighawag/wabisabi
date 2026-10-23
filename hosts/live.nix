{
  config,
  lib,
  pkgs,
  wabisabiModules,
  ...
}:

# THE LIVE SESSION on the offline medium: the wabisabi desktop, logged in
# automatically as the installer's `nixos` user (no password, passwordless
# sudo, both from NixOS's installation-device profile), so the machine can be
# tried before anything touches its disk. Imported by hosts/iso.nix when
# `live` is set.
#
# The boot menu's default entry is this; a second entry, "text installer",
# is the old medium exactly (see `specialisation.installer` below), for a
# machine whose graphics are the problem or a person who just wants to install.
let
  # What greetd runs for the live user, at autologin and whenever someone logs
  # in again from the greeter. The render-node test is the whole point: niri
  # refuses a software renderer, so without it a GPU-less machine would show a
  # black screen with niri running perfectly behind it. This turns that into
  # a sentence on the screen and a working shell.
  #
  # WAIT FOR THE GPU DRIVER FIRST. greetd can start before udev has loaded the
  # GPU's kernel module (on the medium it is not in the initrd; amdgpu takes
  # seconds on real laptops). `udevadm settle` waits for the coldplug queue to
  # drain, and the poll covers a driver that registers its node a moment later.
  #
  # A PLAIN GLOB, NOT `compgen -G`: scripts run under nixpkgs' non-interactive
  # bash, which is built without programmable completion, so `compgen` does
  # not exist there, and the test failed silently on a machine with a GPU.
  liveSession = pkgs.writeShellScript "wabisabi-live-session" ''
    hasRenderNode() {
      local n
      for n in /dev/dri/renderD*; do
        [ -e "$n" ] && return 0
      done
      return 1
    }
    ${lib.getExe' pkgs.systemd "udevadm"} settle --timeout=30 || true
    for _ in $(seq 1 20); do
      hasRenderNode && break
      sleep 0.5
    done
    if hasRenderNode; then
      exec ${lib.getExe' pkgs.systemd "systemd-cat"} --identifier=niri-session ${lib.getExe' pkgs.niri "niri-session"}
    fi
    clear
    cat <<'MSG'

      wabisabi live: this machine has no usable GPU (no /dev/dri/renderD*),
      and the desktop needs one, so it was not started.

      You can still install:   sudo wabisabi-install
      Wifi:                    sudo nmtui

    MSG
    exec ${lib.getExe pkgs.bashInteractive} -l
  '';

  # THE KEYBOARD, CHOSEN IN THE LIVE SESSION. The medium cannot know the
  # keyboard in front of it (a keyboard does not report its layout), so it
  # boots on US and asks, once, in the welcome terminal: Enter keeps US, a few
  # letters find another. Also on PATH as `wabisabi-keyboard`, and in the
  # launcher, for changing it again.
  #
  # IT GOES THROUGH systemd-localed, the one place niri reads the layout from
  # (home/desktop.nix leaves niri's own xkb block empty), and niri follows
  # localed's PropertiesChanged signal, so the running desktop switches at
  # once, with no restart. The same localed is what the installer then reads
  # to offer this layout as its default. `--no-convert` leaves the text
  # console alone: nothing here types on it, and the installer sets it
  # itself from its own answer.
  #
  # Picking from a list rather than typing a layout code, because the person
  # choosing is by definition typing on the wrong layout.
  keyboard = pkgs.writeShellApplication {
    name = "wabisabi-keyboard";
    runtimeInputs = [
      pkgs.gum
      pkgs.gawk
      pkgs.gnused
      pkgs.coreutils
      pkgs.systemd
    ];
    # `sudo` comes from the caller's PATH (/run/wrappers/bin), which
    # writeShellApplication extends rather than replaces.
    text = ''
      lst=${pkgs.xkeyboard_config}/share/X11/xkb/rules/base.lst
      section() { awk -v s="! $1" '$0 == s { on = 1; next } /^!/ { on = 0 } on && NF' "$lst"; }
      # `|| true`: pipefail is on, and a failed localectl must read as "no
      # value", not end the script.
      field() { { localectl status 2>/dev/null || true; } | sed -n "s/^ *X11 $1: //p" | head -n 1 || true; }

      layout=$(field Layout)
      layout=''${layout:-us}
      variant=$(field Variant)
      describe() { section layout | awk -v l="$1" '$1 == l { $1 = ""; sub(/^ +/, ""); d = $0 } END { print (d == "" ? l : d) }'; }

      echo
      echo "  Keyboard layout: $(describe "$layout") ($layout''${variant:+, $variant})"
      echo
      echo "  Enter keeps it. To change it, type part of a name"
      echo "  (French, German, fr, de...) and press Enter."
      echo

      # The current layout first, so Enter alone keeps it.
      pick=$(
        {
          section layout | awk -v l="$layout" '$1 == l'
          section layout | awk -v l="$layout" '$1 != l'
        } | gum filter --height 12 --placeholder "search layouts" || true
      )
      [ -n "$pick" ] || exit 0
      new_layout=$(awk '{ print $1 }' <<<"$pick")

      new_variant=""
      variants=$(section variant | awk -v l="$new_layout:" '$2 == l { v = $1; $1 = ""; $2 = ""; sub(/^ +/, ""); print v "\t" $0 }')
      if [ -n "$variants" ]; then
        echo "  Variant, if you know you need one (Enter: standard)"
        vpick=$(
          { printf 'standard\tthe usual one\n'; printf '%s\n' "$variants"; } \
            | gum filter --height 12 --placeholder "search variants" || true
        )
        new_variant=$(cut -f1 <<<"$vpick")
        [ "$new_variant" = standard ] && new_variant=""
      fi

      if [ "$new_layout" = "$layout" ] && [ "$new_variant" = "$variant" ]; then
        echo "  Keeping $layout."
        exit 0
      fi

      options=$(field Options)
      if sudo localectl set-x11-keymap --no-convert "$new_layout" "" "$new_variant" "$options"; then
        echo "  Keyboard is now $(describe "$new_layout")''${new_variant:+ ($new_variant)}."
        echo "  To change it again: wabisabi-keyboard"
      else
        echo "  Could not switch the keyboard to $new_layout." >&2
        exit 1
      fi
    '';
  };

  # Opened once when the live desktop starts: what this is, and the one
  # command that installs it.
  welcome = pkgs.writeShellScript "wabisabi-live-welcome" ''
    # The keyboard first: everything after it is typed.
    ${lib.getExe keyboard} || true
    clear

    # Lines kept short: this opens in a tiled, half-width terminal.
    cat <<'MSG'

      Welcome to the wabisabi live session.

      It runs from the USB stick and from RAM.
      Nothing is written to this computer's
      disks, and nothing done here survives a
      reboot.

      Things to try:
        Super+A            the assistant, in the
                           browser (same agent)
        pi                 an AI coding agent, on a
                           model running on this CPU
                           (the first answer waits
                           while the model loads)
        webveil search ..  private web search
        sudo anonctl use anon
                           an account whose traffic
                           all goes through Tor
                           (needs a network)

      To install:  sudo wabisabi-install
      Wifi:        sudo nmtui
      Keyboard:    wabisabi-keyboard

    MSG
    exec ${lib.getExe pkgs.bashInteractive} -l
  '';

  terminalFor =
    t:
    if t == "ghostty" then
      lib.getExe pkgs.ghostty
    else if t == "kitty" then
      lib.getExe pkgs.kitty
    else
      lib.getExe pkgs.foot;

  tuigreet = "${lib.getExe pkgs.tuigreet} --time --greeting 'wabisabi live: user nixos, no password.  Install: sudo wabisabi-install' --cmd ${liveSession}";
in
{
  networking.hostName = "wabisabi-live";

  wabisabi = {
    enable = true;
    user = "nixos";
    # The text greeter, whatever the default: it is the one that still works
    # when the GPU is the problem, and it only shows after a logout anyway.
    greetd.greeter = "tuigreet";
    # The medium has its own boot screen; Plymouth would only hide it.
    splash.enable = false;
  };

  environment.systemPackages = [ keyboard ];

  # What the agent should know on top of the machine guide (modules/agents/
  # AGENTS.md): that this is the live medium, and that sudo here depends on
  # where the agent runs (see allowPrivilegeEscalation below).
  wabisabi.agents.extraGuide = ''
    ## This is the live session

    This computer is running wabisabi from a USB stick, from memory, as the user `nixos`. Nothing is written to its disks and nothing done here survives a reboot, so there is no `~/nixos` configuration to change: a fix that should last belongs in the installed system. To install: `sudo wabisabi-install`, in a terminal. To change the keyboard layout: `wabisabi-keyboard`, in a terminal.

    Here `sudo` needs no password in a terminal, and is refused in the web UI. Still ask before using it.
  '';

  # RAM is the scarce thing in a live session (every file written lives in
  # it), so the model loads on first use rather than at boot.
  nixos-modules.llm.onDemand = true;

  # The live user has PASSWORDLESS sudo (NixOS's installation-device profile),
  # so a working sudo in wherever sessions would be root for any agent.
  nixos-modules.wherever.allowPrivilegeEscalation = false;

  services.greetd.settings = {
    initial_session = {
      user = "nixos";
      command = "${liveSession}";
    };
    default_session.command = tuigreet;
  };

  # UNDO WHAT THE MINIMAL INSTALLER PROFILE TURNS OFF, which a desktop needs:
  # without fontconfig nothing finds a font, without the xdg pieces there are
  # no icons, no "open with" and no autostart, and without udisks2 the file
  # manager cannot mount a USB stick. Normal priority beats the profile's
  # mkDefault and mkOverride 500.
  fonts.fontconfig.enable = true;
  xdg = {
    autostart.enable = true;
    icons.enable = true;
    mime.enable = true;
    sounds.enable = true;
  };
  services.udisks2.enable = true;

  # No keyring. On an installed machine the login password unlocks it; the
  # live session logs in with no password, so gnome-keyring greeted the
  # desktop with "choose a password for a new keyring". Nothing here outlives
  # the session anyway. (niri's module enables it at mkDefault.)
  services.gnome.gnome-keyring.enable = false;

  home-manager.users.nixos = {
    imports = [ wabisabiModules.home ];
    wabisabi.enable = true;

    xdg.desktopEntries.wabisabi-keyboard = {
      name = "Keyboard layout";
      comment = "Change the keyboard layout of this live session";
      # Held open a moment after, so the result can be read before the
      # terminal closes.
      exec = "${terminalFor config.home-manager.users.nixos.wabisabi.terminal} -e ${pkgs.writeShellScript "wabisabi-keyboard-window" "${lib.getExe keyboard}; sleep 3"}";
      icon = "input-keyboard";
      terminal = false;
      categories = [ "Settings" ];
      settings.Keywords = "keyboard;layout;keymap;azerty;qwertz;";
    };

    systemd.user.services.wabisabi-live-welcome = {
      Unit = {
        Description = "wabisabi live welcome";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        # After Noctalia's own first-login intro, not on top of it: one thing
        # at a time (the assistant's welcome notification waits the same way).
        ExecStart = "${lib.getExe config.home-manager.users.nixos.wabisabi.afterNoctaliaIntro} ${terminalFor config.home-manager.users.nixos.wabisabi.terminal} -e ${welcome}";
        Restart = "no";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };

  # THE TEXT-ONLY BOOT ENTRY: the old medium, exactly. No desktop, no agent
  # layer, getty autologin as before, so a machine whose graphics misbehave in
  # a way the render-node test cannot see still installs.
  isoImage.configurationName = "live desktop";
  specialisation.installer.configuration = {
    isoImage.configurationName = lib.mkForce "text installer only";
    wabisabi.enable = lib.mkForce false;
    services.greetd.enable = lib.mkForce false;
    home-manager.users = lib.mkForce { };
  };
}
