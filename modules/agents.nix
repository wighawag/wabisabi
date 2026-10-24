{
  config,
  lib,
  pkgs,
  ...
}:

# THE AGENT LAYER, as a wabisabi machine gets it: the building blocks in
# ./services switched on and wired to each other, from the handful of
# distro-level options in ./options.nix (llm, search, agents, anon).
#
# Everything is mkDefault, like the rest of wabisabi, so any value a machine
# sets wins; and every building block remains usable on its own for a machine
# that wants a different arrangement.
#
# THE SHAPE, in one picture:
#
#   llama.cpp ── /run/wabisabi-llm/llm.sock ──┬─ owner's pi / wherever  (group)
#   (no network)                              └─ anon accounts' pi      (group)
#
#   SearXNG ──── /run/wabisabi-search/search.sock ── owner's webveil / pi
#   SearXNG per anon account, as that account ── its own Tor circuit
#     or, with search.backend searchcast, no SearXNG at all:
#   webveil (owner, each anon account) ── recipes from the store ── engines
#
#   anon accounts: every packet forced through Tor by anonctl, fail-closed;
#   each with a wherever on a socket, routed by a loopback-only Caddy at
#   http://<handle>.localhost:8480/#token=...
#
# The local model is reached over a UNIX SOCKET throughout, which is what lets
# the anon accounts use it with NO exemption in their jail: a unix socket is
# not IP traffic, so the kernel's forcing never sees it. Access is the socket's
# group, which this module grants to the owner and to each anon account.
let
  cfg = config.wabisabi;
  svc = config.nixos-modules;
  wp = config.nixos-modules.pkgs;
  hasUser = cfg.user != "";
  # See the assertion where the anon accounts are set up.
  anonOn = cfg.anon.enable && cfg.llm.enable;

  llmModels = [
    {
      id = svc.llm.modelId;
      name = svc.llm.modelName;
      reasoning = svc.llm.reasoning;
      vision = svc.llm.mmproj != null;
      contextWindow = svc.llm.contextSize;
      maxTokens = svc.llm.maxTokens;
    }
  ];

  torSocks = "socks5h://127.0.0.1:9050";

  # ── the search backend: one per machine, owner and anon accounts alike ──
  #
  # The recipe set, unpacked into the store: the owner's `search.recipeSet`
  # as given, else the `search.recipes` archive, fetched with fetchurl so its
  # sha256 is the ARCHIVE's (the value `searchcast install-recipes --sha256`
  # takes and `sha256sum` prints), not fetchzip's hash of the unpacked tree,
  # which no publisher would hand out. The unpack is strict: see the script.
  recipeSet =
    if cfg.search.recipeSet != null then
      cfg.search.recipeSet
    else if cfg.search.recipes != null then
      unpackRecipeSet (
        pkgs.fetchurl (
          {
            name = "wabisabi-search-recipes.tar.gz";
            inherit (cfg.search.recipes) url;
          }
          // (
            if lib.hasPrefix "sha256-" cfg.search.recipes.sha256 then
              { hash = cfg.search.recipes.sha256; }
            else
              { inherit (cfg.search.recipes) sha256; }
          )
        )
      )
    else
      null;

  unpackRecipeSet =
    archive:
    pkgs.runCommand "wabisabi-search-recipes" { } ''
      bash ${./agents/unpack-recipe-set.sh} ${archive} $out
    '';

  backend =
    if cfg.search.backend != "auto" then
      cfg.search.backend
    else if recipeSet != null then
      "searchcast"
    else
      "searxng";
  searchcast = backend == "searchcast";

  # webveil's bundled recipes, which a chain of our own can still use: naming
  # any code recipe replaces webveil's default chain, so to keep one of these
  # its file has to be listed too. From the CLI package; they import nothing.
  bundledRecipes = {
    mwmbl = "${wp.webveil}/lib/node_modules/webveil/recipes/mwmbl.mjs";
    marginalia = "${wp.webveil}/lib/node_modules/webveil/recipes/marginalia.mjs";
  };
  # webveil's own default order.
  bundledOrder = [
    "mwmbl"
    "marginalia"
  ];

  # The chain is the owner's, verbatim. With a recipe set it is REQUIRED (an
  # assertion below): searchcast stops at the first engine that ANSWERS, and
  # an engine that answers "no results" counts, so the order is a judgement
  # about the engines, which only whoever chose the set can make. A default
  # read off the set's file names was tried first and failed in a VM test on
  # 2026-10-24: over Tor, the alphabetically first engine of a real set
  # answered empty, so every anon search returned nothing while another engine
  # of the same set had 9 relevant results.
  engines = cfg.search.engines;

  # The set as ONE directory (webveil loads every *.js/*.mjs in it), plus the
  # bundled recipes the chain names. With neither, the list is empty and
  # nixos-modules leaves the key out: webveil's own default chain.
  codeRecipes =
    lib.optional (recipeSet != null) "${recipeSet}"
    ++ map (name: bundledRecipes.${name}) (lib.filter (name: lib.elem name engines) bundledOrder);

  # The owner's webveil, on the searchcast backend. With `search.viaTor` the
  # ENGINE requests leave through Tor: with searchcast webveil is the one
  # talking to the engines, so that is its `egress`, not `fetchEgress`.
  # fetchEgress is left unset and inherits it, so web_fetch goes through Tor
  # too: a search that hides the address, followed by a fetch of the result
  # from the real one, would hand the same interest to the result's site.
  ownerSearchcastConfig = {
    backend = "searchcast";
    egress =
      if cfg.search.viaTor then
        {
          mode = "socks5";
          url = torSocks;
        }
      else
        { mode = "direct"; };
  }
  // lib.optionalAttrs (engines != [ ]) {
    # Passed even when no recipe file backs it, so an engine name nothing
    # provides is webveil's "unknown engine" error rather than a silent
    # fall back to its default chain.
    searchcast = {
      inherit engines;
    }
    // lib.optionalAttrs (codeRecipes != [ ]) { inherit codeRecipes; };
  };

  ownerHome = config.users.users.${cfg.user}.home or "/home/${cfg.user}";

  # The owner agent's user-global AGENTS.md: where it is and what it may do
  # (see wabisabi.agents.guide), plus whatever this machine adds.
  guideFile = pkgs.writeText "AGENTS.md" (
    builtins.readFile ./agents/AGENTS.md
    + lib.optionalString (cfg.agents.extraGuide != "") ("\n" + cfg.agents.extraGuide)
  );

  # wherever expands a leading `~` itself; tmpfiles needs the real path.
  searchDir =
    let
      f = cfg.agents.searchFolder;
    in
    if f == "~" then
      ownerHome
    else if lib.hasPrefix "~/" f then
      ownerHome + lib.removePrefix "~" f
    else
      f;
  searchBar = cfg.search.enable && cfg.agents.searchFolder != null;

  enrollScript = pkgs.writeShellScript "wabisabi-anon-enroll" ''
    # Idempotent, and self-healing, per declared account:
    #
    #   proven (a marker exists)          nothing to do; reconcile's own timer
    #                                     keeps checking the jail is loaded
    #   managed, forcing loaded           prove it (`verify`, which writes the
    #                                     marker on green)
    #   managed, forcing NOT loaded       a failed `add` (it records the account
    #                                     before installing the rules): remove
    #                                     and add again. Safe precisely because
    #                                     it was never proven, so reconcile never
    #                                     gave it an interface, a handle or a
    #                                     token that `rm` could take away.
    #   not managed                       `add` (adopting the declared account)
    #
    # Never fails the unit: an account that cannot be proven yet (Tor still
    # bootstrapping, no network) is retried by the timer, and until it is
    # proven it gets no interface, which is the safe direction.
    set -u
    anonctl=${lib.getExe wp.anonctl}
    jq=${lib.getExe pkgs.jq}
    for account in ${lib.escapeShellArgs (lib.attrNames cfg.anon.accounts)}; do
      [ -e "/etc/anonctl/$account.json" ] && continue
      if [ -e "/etc/anonctl/accounts/$account.json" ]; then
        state=$("$anonctl" status "$account" --json 2>/dev/null | "$jq" -r '.forcing.state // "unknown"')
        if [ "$state" = forced ]; then
          echo "proving $account"
          "$anonctl" verify "$account" >/dev/null || echo "verify $account is not green yet; will retry" >&2
          continue
        fi
        echo "$account is managed but its forcing is $state (a failed add); re-installing it"
        "$anonctl" rm "$account" || { echo "rm $account failed; will retry" >&2; continue; }
      fi
      echo "enrolling $account"
      "$anonctl" add --endpoint ${torSocks} "$account" || echo "add $account failed; will retry" >&2
    done
    exit 0
  '';
in
lib.mkIf cfg.enable (
  lib.mkMerge [
    # ── the local model ──
    (lib.mkIf cfg.llm.enable {
      nixos-modules.llm.enable = lib.mkDefault true;
    })

    # ── private search ──
    (lib.mkIf cfg.search.enable {
      environment.systemPackages = [ wp.webveil ];
    })
    (lib.mkIf searchcast {
      assertions = [
        {
          assertion = recipeSet == null || engines != [ ];
          message = ''
            wabisabi.search: a recipe set is given (search.recipes or search.recipeSet)
            but wabisabi.search.engines is empty. Set it to the engine chain, the
            recipe names in the order to try them, e.g. [ "engine-a" "engine-b" "mwmbl" ].
            searchcast stops at the first engine that answers, an empty answer
            included, so the order cannot be guessed from the file names.
          '';
        }
      ];
    })
    (lib.mkIf (cfg.search.enable && !searchcast) {
      nixos-modules.searxng = {
        enable = lib.mkDefault true;
        egressProxies = lib.mkIf cfg.search.viaTor (lib.mkDefault [ torSocks ]);
        requestTimeout = lib.mkIf cfg.search.viaTor (lib.mkDefault 10.0);
      };
    })

    # ── the owner's agent ──
    (lib.mkIf (cfg.agents.enable && hasUser) {
      nixos-modules.piUser = {
        enable = lib.mkDefault true;
        user = lib.mkDefault cfg.user;
        extensions = {
          memonaut-pi = lib.mkDefault wp.memonaut-pi;
          pi-webveil = lib.mkIf cfg.search.enable (lib.mkDefault wp.pi-webveil);
          pi-wabisabi-local = lib.mkIf cfg.llm.enable (lib.mkDefault wp.pi-wabisabi-local);
        };
        settings = lib.mkIf cfg.llm.enable (
          lib.mkDefault {
            defaultProvider = svc.llm.providerId;
            defaultModel = svc.llm.modelId;
          }
        );
        webveilConfig = lib.mkIf cfg.search.enable (
          lib.mkDefault (
            if searchcast then
              ownerSearchcastConfig
            else
              {
                backend = "searxng";
                baseUrl = svc.searxng.baseUrl;
                # The BACKEND hop is a local socket; proxying it would be fake
                # anonymity, and webveil refuses the combination.
                egress.mode = "direct";
              }
          )
        );
      };

      nixos-modules.wherever = {
        enable = lib.mkDefault true;
        user = lib.mkDefault cfg.user;
        # The search bar on wherever's home page: a question typed there
        # becomes a session in this folder, with no project to create or pick
        # first. Only with search on, since that is what its sessions are for.
        # (`settings` is a plain attrs option, so this merges shallowly with a
        # machine's own settings rather than replacing them.)
        settings = lib.mkIf searchBar {
          searchFolder = cfg.agents.searchFolder;
        };
      };

      # webhands drives a browser (nixpkgs' free Chromium) from the command
      # line, for agents and people; the use-webhands skill documents it.
      # pciutils and usbutils because the guide below tells the agent to
      # diagnose hardware with `lspci -k` and `lsusb`, and NixOS ships neither.
      environment.systemPackages = [
        wp.memonaut
        wp.webhands
        pkgs.pciutils
        pkgs.usbutils
      ];

      # SEEDED FILES, written when absent and then the owner's (`C` copies out
      # of the store, which leaves a root-owned 0444 file, and `z` hands it to
      # the owner, as nixos-modules' piUser does for settings.json).
      #
      # The search folder's AGENTS.md is seeded HERE, at boot, rather than left
      # to wherever, because wherever seeds its own on the first search and its
      # text is written for another setup: it names a skill this machine does
      # not have and tells the agent to blame Ollama when a search fails.
      systemd.tmpfiles.rules =
        lib.optionals cfg.agents.guide [
          "C ${ownerHome}/.pi/agent/AGENTS.md 0644 ${cfg.user} users - ${guideFile}"
          "z ${ownerHome}/.pi/agent/AGENTS.md 0644 ${cfg.user} users -"
        ]
        ++ lib.optionals searchBar [
          "d ${searchDir} 0700 ${cfg.user} users -"
          "C ${searchDir}/AGENTS.md 0644 ${cfg.user} users - ${./agents/searches-AGENTS.md}"
          "z ${searchDir}/AGENTS.md 0644 ${cfg.user} users -"
        ];
    })

    # The owner reaches the socket-served services through their groups.
    (lib.mkIf hasUser {
      users.users.${cfg.user}.extraGroups =
        lib.optional svc.llm.enable svc.llm.clientGroup
        ++ lib.optional svc.searxng.enable svc.searxng.clientGroup;
    })

    # ── anonymous accounts ──
    # The anon accounts' agent runs on the local model and nothing else (no
    # other model is reachable from inside the jail without an exemption), and
    # nixos-modules' anon-home requires a model. Without the model the block
    # below is not evaluated at all: its options would otherwise fail with
    # "anonHome.defaultModel was accessed but has no value", which names
    # neither cause nor fix. anon.enable follows llm.enable by default, so
    # this only fires when someone set it true explicitly.
    (lib.mkIf (cfg.anon.enable && !cfg.llm.enable) {
      assertions = [
        {
          assertion = false;
          message = ''
            wabisabi.anon.enable is true but wabisabi.llm.enable is false. The anon
            accounts' agent can only use the local model (the one model reachable
            from inside their jail without an exemption), so they need it. Turn
            wabisabi.llm.enable on, or leave wabisabi.anon.enable at its default,
            which follows it.
          '';
        }
      ];
    })

    (lib.mkIf anonOn {
      # The anon accounts' only way out, so they bring it: the same loopback
      # client wabisabi.tor.enable configures (nixpkgs' defaults: 127.0.0.1:9050,
      # per-destination circuit isolation), switched on even when that option
      # is off. anonctl additionally isolates each account on its own circuits.
      services.tor = {
        enable = lib.mkDefault true;
        client.enable = lib.mkDefault true;
      };

      assertions = [
        {
          assertion = config.services.tor.enable && config.services.tor.client.enable;
          message = ''
            wabisabi.anon.enable needs the Tor client (services.tor.client), and
            something turned it off: it is the endpoint every anon account's
            traffic is forced through. Without it the accounts would be jailed
            with no way out, which is safe but useless. Turn wabisabi.anon.enable
            off instead.
          '';
        }
      ];

      # nft too: anonctl runs it by name, and NixOS does not put it on the
      # system PATH unless the firewall backend happens to be nftables.
      environment.systemPackages = [
        wp.anonctl
        pkgs.nftables
      ];

      nixos-modules.anonAccounts = {
        enable = lib.mkDefault true;
        accounts = lib.mkDefault cfg.anon.accounts;
      };
      nixos-modules.anonctlUnits = {
        enable = lib.mkDefault true;
        package = lib.mkDefault wp.anonctl;
      };
      nixos-modules.anonDns.enable = lib.mkDefault true;

      nixos-modules.anonHome = {
        enable = lib.mkDefault true;
        # web_fetch needs no backend and leaves through the account's own
        # circuit; web_search uses the per-account SearXNG below, or, on the
        # searchcast backend, the same recipes and chain as the owner (with
        # engine state in memory and egress direct, which nixos-modules sets:
        # anonctl already forces every packet through the account's circuit).
        webTools = {
          enable = lib.mkDefault true;
          package = lib.mkDefault wp.pi-webveil;
          backend = lib.mkDefault backend;
          searchcast = lib.mkIf searchcast {
            codeRecipes = lib.mkDefault codeRecipes;
            engines = lib.mkDefault engines;
          };
        };
        extensions = {
          memonaut-pi = lib.mkDefault wp.memonaut-pi;
          pi-wabisabi-local = lib.mkIf cfg.llm.enable (lib.mkDefault wp.pi-wabisabi-local);
        };
        # A browser per account, for what web_fetch cannot see (pages that
        # render in the client). It runs AS the account, so its traffic is
        # forced through that account's Tor circuit like everything else, with
        # a profile per account under ~/.webhands. Headless: nothing here gives
        # an anon account a display.
        browser = {
          enable = lib.mkDefault true;
          package = lib.mkDefault wp.webhands;
        };
        skills.use-webhands = lib.mkDefault "${wp.webhands}/share/agent-skills/use-webhands";
        provider = lib.mkDefault svc.llm.providerId;
        models = lib.mkIf cfg.llm.enable (lib.mkDefault llmModels);
        defaultModel = lib.mkIf cfg.llm.enable (lib.mkDefault svc.llm.modelId);
      };

      # Off on the searchcast backend, where nothing would read its sockets
      # (nixos-modules refuses the combination).
      nixos-modules.anonSearch.enable = lib.mkDefault (!searchcast);

      nixos-modules.whereverAnon = {
        enable = lib.mkDefault true;
        reconcile.enable = lib.mkDefault true;
      };
      nixos-modules.anonDispatcher.enable = lib.mkDefault true;

      # Each anon account may reach the local model's socket, and nothing else
      # of the owner's.
      users.users = lib.mkIf svc.llm.enable (
        lib.mapAttrs (_: _: { extraGroups = [ svc.llm.clientGroup ]; }) cfg.anon.accounts
      );
    })

    (lib.mkIf (anonOn && cfg.anon.autoEnroll) {
      systemd.services.wabisabi-anon-enroll = {
        description = "Enrol and prove the declared anon accounts (anonctl add / verify)";
        # NOT wanted by multi-user.target: `verify` waits on Tor, and a boot
        # must never wait on Tor. The timer below starts it shortly after boot.
        wants = [ "network-online.target" ];
        after = [
          "network-online.target"
          "tor.service"
          "anonctl-nftables.service"
          "nscd.service"
        ];
        # anonctl execs nft, setpriv and nologin by name, and a unit's PATH
        # holds none of them: without these every `add` failed at its first
        # step (measured in the demo VM).
        path = [
          wp.anonctl
          pkgs.nftables
          "/run/current-system/sw"
        ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = enrollScript;
          # verify makes real connections through Tor; give a slow first
          # bootstrap room rather than a hung boot.
          TimeoutStartSec = "10min";
        };
      };
      systemd.timers.wabisabi-anon-enroll = {
        description = "Retry proving anon accounts that are not proven yet";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "1min";
          OnUnitInactiveSec = "15min";
          Unit = "wabisabi-anon-enroll.service";
        };
      };
    })
  ]
)
