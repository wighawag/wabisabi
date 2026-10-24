{ lib, pkgs, config, ... }:

{
  options.wabisabi = {
    enable = lib.mkEnableOption "the wabisabi system layer";

    enforceLibre = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Fail the build if `nixpkgs.config.allowUnfree = true`.
        This enforces the project rule: open source software only.
      '';
    };

    greetd.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "greetd as the login manager.";
    };

    greetd.greeter = lib.mkOption {
      type = lib.types.enum [ "noctalia" "tuigreet" ];
      default = "noctalia";
      description = ''
        Which greeter greetd launches.

        "noctalia" is the graphical greeter from the Noctalia project
        (packaged in nixpkgs): user and session pickers, password entry and a
        colour-scheme chooser, in the same visual language as the shell. It
        brings its OWN bundled wlroots compositor, so it needs a GPU with a
        render node, exactly like the session it logs you into.

        "tuigreet" is a text greeter that runs on the VT. Uglier, and the one
        that still works when the graphics stack is the thing that is broken
        -- which is why it stays available rather than being deleted.

        This pairs with the HOME-layer `wabisabi.shell` option but is
        deliberately independent of it: the greeter runs as its own user
        before any home configuration exists, so the two cannot read each
        other and a fleet may reasonably want a text greeter with a graphical
        session or the reverse.
      '';
    };

    splash.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Plymouth splash screen and a quiet boot, themed to match the desktop.

        This hides routine unit and kernel output, not failures: password
        prompts, fsck questions and the emergency shell still appear. Set to
        false if you would rather watch the boot.
      '';
    };

    splash.hideBootMenu = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Skip systemd-boot's menu, so the machine goes from the firmware logo
        straight to the splash. The menu is still there: HOLD SPACE while the
        machine starts to see it, which is how you pick an older generation to
        roll back to. Only applies with systemd-boot (the installer's
        bootloader) and to installed systems; the ISOs keep their menu.
      '';
    };

    theme = lib.mkOption {
      type = lib.types.enum (lib.attrNames (import ../theme/palettes.nix));
      default = "sumi";
      description = ''
        The palette the whole desktop is drawn in: boot splash, greeter,
        shell, terminals, GTK, editors. Defined in theme/palettes.nix.

        "sumi" (ink) is wabisabi's own, sampled from the default wallpaper:
        indigo ink and warm paper. "catppuccin-mocha" is the previous default.

        The home layer follows this value unless it sets its own.
      '';
    };

    wallpaper = lib.mkOption {
      type = lib.types.path;
      default = "${pkgs.callPackage ../pkgs/wabisabi-artwork/package.nix { }}/share/backgrounds/wabisabi/enso.jpg";
      defaultText = lib.literalExpression ''"''${wabisabi-artwork}/share/backgrounds/wabisabi/enso.jpg"'';
      description = ''
        The desktop's wallpaper, also used by the greeter and the lock screen.
        The default is the enso risograph print (CC0, artwork/wallpapers).

        The home layer follows this value unless it sets its own.
      '';
    };

    zram.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "zram swap (compressed RAM swap — no disk layout needed, safe everywhere).";
    };

    bluetooth.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Bluetooth stack (harmless if the machine has no adapter).";
    };

    cellular.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "ModemManager for WWAN/LTE modems (harmless if absent).";
    };

    printing.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        CUPS plus DRIVERLESS printer discovery (IPP Everywhere / AirPrint over
        DNS-SD). Finds any printer made since roughly 2010 with no vendor
        driver and no configuration.

        Driverless is not merely the tidy option here, it is what keeps
        printing COMPATIBLE WITH THE LIBRE RULE. Most vendor PPDs and filters
        in nixpkgs are unfree (Epson's escpr2, for one), so a driver-based
        setup would force a wabisabi user to choose between printing and
        `enforceLibre`. Asking the printer to describe itself over IPP removes
        that choice instead of trading it away.

        No queue is created declaratively, deliberately: building one requires
        contacting the device, so a printer that is switched off would fail the
        activation. Discovery has no such coupling.
      '';
    };

    tor.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        A Tor CLIENT exposing SOCKS5 on 127.0.0.1:9050. Client only: this is
        never a relay, a bridge or an onion service, so the machine carries
        nobody else's traffic and gains no abuse or legal surface from it.

        ON BY DEFAULT because it fits what this setup is for: an endpoint that
        can be reached without an account attached to it is exactly the kind of
        capability a libre, self-hostable desktop should have sitting there,
        and nothing uses it until something asks. The daemon is small and
        idles cheaply.

        BE HONEST ABOUT TWO THINGS. It does not make the machine anonymous:
        your browser, your logins and your ordinary traffic are untouched and
        still fully attributable. And running it is VISIBLE TO YOUR ISP, since
        connections to Tor guards are recognisable; in a few jurisdictions that
        is itself worth avoiding, which is a reason to set this false rather
        than a reason nobody should have it on.
      '';
    };

    timeZone = lib.mkOption {
      type = lib.types.str;
      default = "Europe/London";
      description = "Default timezone. mkDefault — override freely.";
    };

    locale = lib.mkOption {
      type = lib.types.str;
      default = "en_GB.UTF-8";
      description = "Default locale. mkDefault — override freely.";
    };

    keyboard.layout = lib.mkOption {
      type = lib.types.str;
      default = "us";
      example = "fr";
      description = ''
        XKB layout, as an xkeyboard-config name ("us", "fr", "de", "gb").
        Several may be given comma-separated ("us,fr") to switch between them.

        THIS IS ONE SETTING FOR THREE KEYBOARDS, which is the reason it exists
        as an option rather than as something you run once by hand.

        niri deliberately does not carry its own copy of the layout: with an
        empty `xkb` block (see home/desktop.nix) it asks systemd-localed, and
        localed reads /etc/X11/xorg.conf.d/00-keyboard.conf. NixOS generates
        that file from `services.xserver.xkb.*` whenever
        `services.graphical-desktop.enable` is on, which greetd turns on -- so
        this flows to the compositor with no X server anywhere in sight.

        The other two keyboards are the text ones, and they are the reason
        `console.useXkbConfig` is switched on alongside: the VT (tuigreet, the
        emergency shell) and, more importantly, THE INITRD PASSPHRASE PROMPT.
        Set a LUKS passphrase containing characters that move between layouts
        and leave the console on US, and the machine becomes unbootable by its
        owner with no indication of why.
      '';
    };

    keyboard.variant = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "dvorak";
      description = "XKB variant (\"dvorak\", \"colemak\", \"nodeadkeys\"). Empty means the layout's default.";
    };

    keyboard.options = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "grp:alt_shift_toggle,caps:escape";
      description = "XKB options, comma-separated. Empty means none.";
    };

    mdns.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Announce this machine on the local network as <hostname>.local, and
        find other machines by their .local names (mDNS, via Avahi), so
        `ssh mybox.local` works on a home network with no DNS set up.

        The trade: on a network you do not trust (a café, a hotel), everyone
        on it can see this machine's hostname. Resolving other machines'
        .local names stays on either way while printing is on, since that is
        how printers are found; this option decides whether THIS machine
        announces itself.
      '';
    };

    nixLd.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run binaries built for other Linux distributions (nix-ld): toolchains
        that download their own compilers (rustup, Foundry), Playwright's
        browsers, VS Code-style remote servers, prebuilt release binaries.
        NixOS has no /lib64/ld-linux-x86-64.so.2 by default, so without this
        they fail with a misleading "No such file or directory". It adds that
        loader and a set of common libraries; it runs nothing by itself.
      '';
    };

    zellij.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        zellij, a terminal multiplexer: panes, tabs, and sessions that survive
        a closed terminal or a dropped ssh connection (`zellij attach`). Comes
        with a declared keybind set (modules/zellij-config.kdl), which starts
        LOCKED so it never steals keys from the program inside: Ctrl+G unlocks.
      '';
    };

    bash.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        A modern interactive bash for every account, in /etc/bashrc: ble.sh
        (syntax highlighting and autosuggestions as you type), fzf (Ctrl-T
        files, Alt-C directories), zoxide (`z` jumps to directories you use),
        atuin (Ctrl-R searches your whole history, kept locally) and a
        starship powerline prompt, all in one Catppuccin Mocha palette with
        `ls` colours to match.

        Only at a real terminal: a script, an agent's tool shell or anything
        reporting TERM=dumb gets plain bash, so agents' commands never land in
        your history. The prompt's shapes and icons need a Nerd Font in the
        terminal, which wabisabi installs and its terminals use.
      '';
    };

    # ── The agent layer: a local model, private search, and agents that use
    # them, for the owner and for anonymous accounts. See modules/agents.nix.

    user = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "alice";
      description = ''
        The machine's OWNER: the account the agent layer configures pi and
        wherever for, and adds to the local model's and search's groups.

        The system layer cannot know this by itself (a NixOS module is not
        told which of the declared users is the person at the keyboard), which
        is the only reason it is an option. Empty leaves those per-user parts
        off; the machine-wide services (model, search, anon accounts) do not
        depend on it.
      '';
    };

    # ── Secrets: sops-encrypted values in the owner's own flake. See
    # modules/secrets.nix and `wabisabi-secrets --help`.

    secrets.sopsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "./secrets/secrets.yaml";
      description = ''
        The machine's sops-encrypted secrets file, committed to its flake. Null
        (the default) leaves secrets off entirely.

        Set by `wabisabi-secrets init`, which the installer runs for you:
        it creates an age key, encrypts the file to it and uncomments this
        line in configuration.nix. The file is safe to publish; only the age
        key can read it, and the key lives outside the flake (see
        `secrets.ageKeyFile`).
      '';
    };

    secrets.ageKeyFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/sops-nix/key.txt";
      description = ''
        Where the machine's age private key lives. It is read at activation to
        decrypt `secrets.sopsFile`, so it must exist on the machine and must
        NOT be in the flake. The owner keeps a backup of it: with the key and
        the flake, a wiped machine is reinstalled as it was.
      '';
    };

    secrets.ownerPassword = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Take the owner's login password from the secret `owner-password` (a
        crypt hash, as `mkpasswd` makes) instead of leaving it to `passwd`.
        Only takes effect when `secrets.sopsFile` is set.

        This is what makes a reinstall from the flake log in with the same
        password. NixOS applies it when the account is CREATED; on an existing
        machine, `wabisabi-secrets password` changes both the secret and the
        live password, whereas plain `passwd` changes only the live one.
      '';
    };

    restore.files = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            sopsFile = lib.mkOption {
              type = lib.types.path;
              description = "The sops-encrypted file in the repo that holds the content.";
            };
            format = lib.mkOption {
              type = lib.types.enum [ "binary" "yaml" "json" "dotenv" "ini" ];
              default = "binary";
              description = "How sops reads `sopsFile` (sops' --input-type).";
            };
            extract = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = ''["ssh"]["hostKey"]'';
              description = "For a structured file, the one value to place (sops' --extract). Null places the whole decrypted file.";
            };
            mode = lib.mkOption {
              type = lib.types.str;
              default = "0400";
              description = "File mode on the target. Owned by root.";
            };
          };
        }
      );
      default = { };
      example = lib.literalExpression ''
        {
          "/etc/ssh/ssh_host_ed25519_key" = {
            sopsFile = ./secrets/laptop/ssh-host-key;
            mode = "0600";
          };
        }
      '';
      description = ''
        Files the installer's RESTORE mode decrypts out of the repo, with the
        owner's age key, and places on the new disk BEFORE the first boot.
        Nothing reads this option on a running machine; it is the config
        telling a restore what it needs that the Nix store must never hold.

        The case it exists for: a machine whose sops secrets are encrypted to
        its SSH host key (the fleet pattern, `sops.age.sshKeyPaths`) rather
        than to an age key file. Such a machine can decrypt nothing until
        that host key is back, so the repo keeps the private key encrypted to
        the admin key and a restore puts it at /etc/ssh before activation.
        A config set up by `wabisabi-secrets` needs none of this: its key is
        the one the restore is given.
      '';
    };

    llm.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        A local AI model on this machine: llama.cpp on the CPU, serving a small
        open-weights model (Gemma 4 E4B, Apache-2.0, ~4.2 GB download) over a
        unix socket. Prompts never leave the machine; the server itself runs
        with no network access at all.

        Every agent here is configured to use it, so the machine has a working
        assistant with no account anywhere. It is also the ONLY model the
        anonymous accounts can use without a hole in their jail.

        Costs the download and, while answering, CPU. Idle, it costs memory the
        kernel can reclaim. See nixos-modules.llm.* to change the model.
      '';
    };

    search.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Private web search: webveil, the search-and-fetch tool agents use, with
        a search backend on this machine (see `search.backend`): a local
        SearXNG by default, or webveil's own searchcast engines. No account, no
        tracking profile. Also usable from a shell: `webveil`.
      '';
    };

    search.backend = lib.mkOption {
      type = lib.types.enum [
        "auto"
        "searxng"
        "searchcast"
      ];
      default = "auto";
      description = ''
        Where web searches go: "searxng" (a local SearXNG asking many engines at once), "searchcast" (webveil asks the engines itself, from recipes, with a browser's network fingerprint, and no SearXNG runs at all), or "auto" (searchcast when you give a recipe set in `search.recipes`, else SearXNG).

        One backend per machine, for the owner and the anon accounts alike.

        SearXNG works well with no setup, but in practice many of its engines
        refuse it (CAPTCHAs, rate limits), more so over Tor, so its answers
        tend to come from whichever one engine still lets it through.
        searchcast's requests look like a real browser's and get through where
        SearXNG's do not, but it is only as good as its recipes: without a set
        of your own it runs webveil's bundled public engines (Mwmbl,
        Marginalia), which are weak alone (off-topic or empty answers to many
        queries). Hence "auto".

        Switching back is this option and a rebuild.
      '';
    };

    search.recipes = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            url = lib.mkOption {
              type = lib.types.str;
              example = "https://example.org/releases/my-set-1.0.0.tar.gz";
              description = ''
                Where the recipe-set archive is downloaded from: a .tar.gz
                holding *.mjs code recipes (and optionally a manifest.json),
                at its root or under one top-level directory, the format
                `searchcast install-recipes` takes.
              '';
            };
            sha256 = lib.mkOption {
              type = lib.types.strMatching "[0-9a-f]{64}|sha256-[A-Za-z0-9+/]{43}=";
              description = ''
                The archive's sha256, in hex as `sha256sum` prints it (the
                value `searchcast install-recipes --sha256` takes), or as an
                SRI hash. This is your trust decision: exactly these bytes and
                no others are ever loaded.
              '';
            };
          };
        }
      );
      default = null;
      example = lib.literalExpression ''
        {
          url = "https://example.org/releases/my-set-1.0.0.tar.gz";
          sha256 = "<the archive's sha256, hex>";
        }
      '';
      description = ''
        A searchcast recipe set to search with (with `search.backend` "auto" this also switches the backend to searchcast). THE URL IS WRITTEN INTO YOUR CONFIG, so if you publish your config you publish where your recipes come from. And RECIPES ARE CODE that webveil runs with full Node access, as you and as each anon account: pin only a set you trust, since the sha256 is that trust decision. Leave empty for none.

        The archive is fetched when the system is built, by Nix, from this
        machine's own address (`search.viaTor` routes searches, not this
        download), checked against the sha256, unpacked into the store, and
        handed to webveil from there for the owner and for every anon account.
        Only its code recipes (*.mjs, *.js) are loaded; declarative *.json
        recipes in it are not.

        Give its engine order in `search.engines` too (required with a set).
        To use a set from a flake input or a local path instead of a URL, set
        `search.recipeSet`.
      '';
    };

    search.recipeSet = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "inputs.my-recipes";
      description = ''
        An already unpacked recipe set (a directory holding the *.mjs code
        recipes), used instead of `search.recipes` when set: a flake input, or
        a path. Same trust rule: it is code webveil runs. It is copied into
        the store, so a set kept in a private input stays out of a published
        config.
      '';
    };

    search.engines = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "engine-a"
        "engine-b"
        "mwmbl"
      ];
      description = ''
        The searchcast engine chain: recipe names (usually the file names without .mjs), tried in order until one answers. REQUIRED with a recipe set; add "mwmbl" and "marginalia" for webveil's bundled engines as fallbacks.

        searchcast stops at the first engine that answers, and "no results"
        is an answer, so put first the engines you trust to answer well (over
        Tor too, for the anon accounts) and the ones that sometimes answer
        empty after them. That judgement belongs to whoever chose the set,
        which is why there is no default order.

        An engine's name is its recipe's `name`. "mwmbl" and "marginalia" name
        webveil's bundled recipes and bring their files along (so a set must
        not contain recipes of those names if they are listed here). With no
        recipe set, leave it empty for webveil's own default chain.
      '';
    };

    search.viaTor = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Send the search engines' requests through Tor, so they see a Tor exit
        rather than this machine's address.

        OFF by default because it costs results: many engines challenge or
        refuse Tor exits. Your queries are still sent without cookies or an
        account either way; this decides only which address they come from.

        With the searchcast backend, webveil itself is what talks to the
        engines, so this sets the owner's webveil egress to Tor, and web_fetch
        (which follows the same egress) goes through Tor as well. Typed
        `webveil install-recipes` and `install-libcurl` commands then ask you to
        choose their route (`--egress`, `--proxy` or `--direct`), which is
        webveil's rule for a proxied egress. The anon accounts are forced
        through Tor whatever this says.
      '';
    };

    agents.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        The pi coding agent for the machine's owner, set up to use the local
        model and private search, with memonaut (search your past agent
        conversations) and wherever (a web UI for agent sessions, on this
        machine only: run `wherever-link` for its address), and webhands (drive
        a real browser from the command line, on nixpkgs' free Chromium).
      '';
    };

    agents.guide = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Give the owner's agent a user-global AGENTS.md (~/.pi/agent/AGENTS.md)
        saying where it is: on the user's own computer, with real shell access,
        on NixOS, and which commands diagnose wifi, sound, disks and the rest.

        Without it the local model assumes it is a sandboxed coding assistant
        and refuses to look at the machine at all (measured on the live ISO:
        asked about wifi, it insisted its `ip addr` output came from "a virtual
        machine", after running it on the user's laptop).

        SEEDED, not declared: written once when the file is absent, then the
        owner's to edit, the same as settings.json. So an existing AGENTS.md is
        never touched, and a later change to this text does not reach a
        machine that already has one (delete the file to get the current text
        at the next boot).
      '';
    };

    agents.extraGuide = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        Text appended to the seeded AGENTS.md (see `agents.guide`), for what a
        particular machine needs its agent to know. The live ISO uses it to say
        that it is a live session.
      '';
    };

    agents.searchFolder = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "~/searches";
      description = ''
        Where wherever's search bar starts its sessions: the box on its home
        page that takes a question directly, with no project folder to create
        or pick first. Each question becomes a session in this folder, whose
        AGENTS.md (seeded here when absent, and only when search is enabled)
        tells the agent to answer from the web, with sources.

        `~` is the owner's home. null removes the search bar.
      '';
    };

    anon.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.wabisabi.llm.enable;
      defaultText = lib.literalExpression "config.wabisabi.llm.enable";
      description = ''
        Anonymous accounts: separate logins (anon, anon-john, anon-jane) whose
        EVERY connection is forced through Tor by the kernel, fail-closed
        (anonctl). If Tor is down, they have no network, never your address.

        Each comes with its own agent setup (pi on the local model, web search
        through its own Tor circuit) and its own wherever web UI, reachable from
        this machine: run `sudo anon-reconcile links`.

        They carry nothing of yours: no keys, no git identity, no history. Use
        one from a terminal with `sudo anonctl use anon`, or through its web
        UI. They are not desktop users: they have no password, the greeter
        does not list them, and a graphical session could not run in one,
        since they are refused the system bus (along with the other root-side
        services that could send traffic for them outside Tor).

        Runs the Tor client even if wabisabi.tor.enable is off, since it is
        their only way out (so a Tor SOCKS port on 127.0.0.1:9050 exists for
        every local account too, as with that option). Changes how this machine
        resolves hostnames (systemd-resolved, nscd not answering host lookups),
        because otherwise every name an anon account looks up would be
        resolved in the clear by the system resolver.

        NEEDS THE LOCAL MODEL (`llm.enable`), and follows it by default: the
        local model, over its socket, is the only model an anon account can
        use without a hole in its jail, and their agent setup requires one.
        Turning the model off therefore turns these off too, unless this is
        set to true, which is refused with that explanation.
      '';
    };

    anon.autoEnroll = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Put the declared anon accounts under anonctl's forcing automatically,
        at boot, instead of waiting for `sudo anonctl add <account>`.

        Until an account is enrolled it exists but is NOT forced; it is inert
        only because it has no password and no key. Enrolling makes the jail
        real, and a retry timer proves it (`anonctl verify`) once Tor is up, at
        which point each account's web UI appears. It never punches an
        exemption: the local model is reached over a unix socket, which needs
        none.
      '';
    };

    anon.accounts = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            uid = lib.mkOption {
              type = lib.types.ints.between 1000 29999;
              description = "Pinned uid of the login account (the forcing matches it, so it must never drift).";
            };
            shimUid = lib.mkOption {
              type = lib.types.ints.between 400 999;
              description = "Pinned uid of the account's shim (its private relay to Tor).";
            };
          };
        }
      );
      default = {
        anon = {
          uid = 8801;
          shimUid = 412;
        };
        anon-john = {
          uid = 8802;
          shimUid = 413;
        };
        anon-jane = {
          uid = 8803;
          shimUid = 414;
        };
      };
      description = ''
        The anonymous account slots, by anonctl account name ("anon" or
        "anon-<slot>"), with pinned uids. The names are world-readable and must
        never say what an account is FOR: "john" and "jane" are placeholder
        personas. Declare the whole pool at once; a pool that grows later
        records when an identity was created.

        uids are high (away from the 1000+ normal-user front) and shim uids low
        (away from the 999- system front), so neither is ever auto-allocated.
      '';
    };
  };
}