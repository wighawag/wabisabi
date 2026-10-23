{ lib, pkgs, config, osConfig ? null, ... }:

# THE ASSISTANT, MADE VISIBLE. The system layer (../modules/agents.nix) runs a
# wherever for the machine's owner: a web UI for pi agent sessions on the
# local model, loopback only. Until now the only way to find it was to know
# that `wherever-link` exists. This module puts it where a new user looks:
#
#   - a launcher entry ("Assistant"), in fuzzel and in Noctalia's launcher
#   - a keybind, Mod+A
#   - a bar button (Waybar here; Noctalia's comes from its seed, see noctalia.nix)
#   - a welcome notification on the first graphical login, shown once and
#     only after Noctalia's own intro is closed (after-noctalia-intro, noctalia.nix)
#
# All four run the same command, `wabisabi-assistant`, which asks
# `wherever-link` for the URL AT CLICK TIME. That is the one design constraint:
# the URL carries the access token (in the fragment, which a browser never
# sends), the token is minted on the machine at first start and readable only
# by the owner, and it must never reach the store. So nothing here may bake the
# URL into a file; a bookmark or a browser homepage set at build time would
# have to. Resolving it on each click also means a token rotation (delete
# /var/lib/wherever/token, restart wherever) is picked up with no rebuild.
#
# WHY KEEP THE TOKEN AT ALL on a loopback-only server, when a mesh-only box
# (the fleet's telemaque) runs without one: loopback is not a boundary against
# THIS machine's browsers. wherever answers with `Access-Control-Allow-Origin:
# *` and does not check Host, so without a token any web page open in any
# local browser could drive an agent with full access to the owner's home,
# directly or by DNS rebinding. Two such browsers are always here: the owner's
# own, and webhands' Chromium, which agents point at arbitrary pages. On a mesh
# box, those browsers are not on the same host as the server; here they are.
let
  cfg = config.wabisabi;

  # On by default exactly when this home belongs to the account the system
  # layer runs wherever for. Standalone home-manager (no NixOS underneath) has
  # no osConfig and no wherever, so it is off there.
  ownsWherever =
    osConfig != null
    && (osConfig.nixos-modules.wherever.enable or false)
    && (osConfig.nixos-modules.wherever.user or "") == config.home.username;

  noctalia = cfg.shell == "noctalia";

  # How the bind reads to a person: "Super+A", not "SUPER+A".
  keyName = { SUPER = "Super"; ALT = "Alt"; CTRL = "Ctrl"; }.${cfg.modKey};

  # One path, used by the script and by the unit's condition.
  stampRel = ".local/state/wabisabi/assistant-welcomed";

  browserCmd =
    if cfg.browser == "firefox" then lib.getExe pkgs.firefox
    else if cfg.browser == "librewolf" then lib.getExe pkgs.librewolf
    else if cfg.browser == "chromium" then lib.getExe pkgs.chromium
    else "${pkgs.xdg-utils}/bin/xdg-open";

  open = pkgs.writeShellApplication {
    name = "wabisabi-assistant";
    runtimeInputs = [ pkgs.libnotify pkgs.coreutils pkgs.curl ];
    text = ''
      # wherever-link comes from the system profile, which a session spawned
      # by the compositor may not have on PATH.
      PATH="$PATH:/run/current-system/sw/bin"

      # Wait for a link AND a server answering it. The link alone is not
      # enough: the token file outlives a stopped wherever, so wherever-link
      # still prints a URL and the browser would open on "Not connected".
      # Right after boot the server may still be starting, hence the retries.
      url=""
      for _ in $(seq 1 10); do
        if url=$(wherever-link 2>/dev/null) \
           && curl -s -o /dev/null --max-time 2 "''${url%%#*}"; then
          break
        fi
        url=""
        sleep 1
      done

      if [ -z "$url" ]; then
        notify-send --app-name=wabisabi "Assistant unavailable" \
          "wherever is not running. Check it with: systemctl status wherever"
        exit 1
      fi

      exec ${browserCmd} "$url"
    '';
  };

  welcome = pkgs.writeShellApplication {
    name = "wabisabi-assistant-welcome";
    runtimeInputs = [ pkgs.libnotify pkgs.coreutils pkgs.gnugrep pkgs.systemd pkgs.niri ];
    text = ''
      stamp="$HOME/${stampRel}"
      [ -e "$stamp" ] && exit 0

      # Is there a notification daemon to show the welcome to? Noctalia claims
      # the bus name when its unit has started, which may be after this one;
      # mako is D-Bus ACTIVATED, so it owns nothing until the first
      # notification starts it. So: an owner is ready at once, an activatable
      # daemon after a short grace (letting Noctalia claim the name first), and
      # neither means nobody to show it to: leave the stamp, try next login.
      bus() {
        busctl --user call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus "$@" 2>/dev/null
      }
      for i in $(seq 1 30); do
        if bus NameHasOwner s org.freedesktop.Notifications | grep -q true; then
          ready=1
          break
        fi
        if [ "$i" -ge 5 ] && bus ListActivatableNames | grep -q '"org.freedesktop.Notifications"'; then
          ready=1
          break
        fi
        sleep 1
      done
      [ "''${ready:-0}" = 1 ] || exit 0

      # Stamped BEFORE showing, so it is once even if the session ends while
      # the notification is up.
      mkdir -p "$(dirname "$stamp")"
      touch "$stamp"

      # Two actions, one per daemon: mako fires `default` when the body is
      # clicked, while Noctalia shows only NAMED actions, as buttons, and a
      # click on its body fires nothing. The body is short because Noctalia
      # cuts a toast at three lines.
      action=$(notify-send --app-name=wabisabi --expire-time=0 --wait \
        --action=default="Open" \
        --action=open="Open the assistant" \
        "Your assistant is ready" \
        "An AI running on this computer: no account, no cloud. ${keyName}+A opens it any time." \
        || true)

      # Hand the launch to niri, as the keybind does, rather than exec'ing it:
      # otherwise the browser would live in THIS unit's cgroup, and anything
      # that stops the unit (a home-manager switch) would take it down too.
      case "$action" in
        default|open)
          niri msg action spawn -- ${lib.getExe open} \
            || systemd-run --user --collect ${lib.getExe open}
          ;;
      esac
    '';
  };
in
{
  options.wabisabi.assistant = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = ownsWherever;
      defaultText = lib.literalMD "true when this home's user is the one the system runs wherever for";
      description = ''
        Make the local assistant (wherever, the web UI for pi agent sessions)
        reachable from the desktop: an "Assistant" launcher entry, Mod+A, a
        bar button, and a one-time welcome notification. Each opens the
        browser on `wherever-link`'s URL, resolved when clicked, so the access
        token never reaches the store.
      '';
    };

    welcome = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Show a welcome notification introducing the assistant on the first
        graphical login, once. Delete ~/${stampRel} to see it again.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && cfg.assistant.enable) (lib.mkMerge [
    {
      home.packages = [ open ];

      # The launcher entry. Both fuzzel and Noctalia's launcher list XDG
      # desktop entries, so this one definition serves both shells.
      xdg.desktopEntries.wabisabi-assistant = {
        name = "Assistant";
        genericName = "Local AI assistant";
        comment = "The AI assistant running on this computer (wherever, on the local model)";
        exec = lib.getExe open;
        icon = "internet-chat";
        terminal = false;
        categories = [ "Utility" ];
        settings.Keywords = "ai;agent;assistant;chat;pi;wherever;llm;";
      };

      # Mod+A: free in desktop.nix, and "A" for assistant.
      wayland.windowManager.niri.settings.binds."Mod+A".spawn = lib.getExe open;
    }

    # The bar button, classic stack. Leftmost of the right-hand modules, so it
    # sits apart from the status indicators.
    (lib.mkIf (!noctalia) {
      programs.waybar.settings.mainBar = {
        modules-right = lib.mkBefore [ "custom/assistant" ];
        "custom/assistant" = {
          format = "󰚩";
          tooltip-format = "Assistant (${keyName}+A)";
          on-click = lib.getExe open;
        };
      };
      programs.waybar.style = lib.mkAfter ''
        #custom-assistant { padding: 0 8px; color: #cba6f7; }
      '';
    })

    (lib.mkIf cfg.assistant.welcome {
      systemd.user.services.wabisabi-assistant-welcome = {
        Unit = {
          Description = "Introduce the local assistant, once";
          After = [ config.wayland.systemd.target ];
          PartOf = [ config.wayland.systemd.target ];
          ConditionPathExists = "!%h/${stampRel}";
        };
        Service = {
          Type = "simple";
          # After Noctalia's own first-login intro, not on top of it.
          ExecStart = "${lib.getExe cfg.afterNoctaliaIntro} ${lib.getExe welcome}";
          Restart = "no";
        };
        Install.WantedBy = [ config.wayland.systemd.target ];
      };
    })
  ]);
}
