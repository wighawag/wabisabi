{
  description = "wabisabi: an opinionated, libre-only Wayland desktop, distributed as NixOS + home-manager modules";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # The Noctalia shell, as SOURCE not as a flake: its own flake pins a
    # separate nixos-unstable, which would put a second nixpkgs in every
    # consumer's closure and let the shell's GL stack drift from the
    # compositor's. nix/package.nix is a plain callPackage file, so we build
    # it against our pkgs. See home/noctalia.nix.
    noctalia = {
      url = "github:noctalia-dev/noctalia";
      flake = false;
    };

    # The agent layer's building blocks (local model, search, pi, wherever,
    # the anon accounts, the interactive bash) and the packages they run.
    # They live in their own repository so machines that are not wabisabi
    # desktops can use them too; wabisabi's modules/agents.nix switches them
    # on. Following our nixpkgs keeps one nixpkgs in the lock (the modules take
    # `pkgs` from the importing system anyway).
    nixos-modules = {
      url = "github:wighawag/nixos-modules";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Secrets for the owner's own config: the machine's flake keeps its
    # sensitive values (the login password's hash, tokens) sops-encrypted to
    # an age key, and sops-nix decrypts them on activation. Imported by the
    # system layer so the generated flake needs no extra input, and pinned in
    # the installed machine's lock like everything else. See
    # modules/secrets.nix.
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Used by the INSTALLER only (partitioning, and the hardware module the
    # generated flake offers users). Flake inputs are fetched on access, so
    # consumers who only import the module layers never pull these.
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-hardware = {
      url = "github:NixOS/nixos-hardware";
      # Follow our nixpkgs rather than letting it drag in a second one. This
      # also keeps the lock graph flat, which is what lets installer/lock.nix
      # hand the installed machine a lock that nix accepts as-is instead of
      # re-resolving on first boot.
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      noctalia,
      nixos-modules,
      sops-nix,
      disko,
      nixos-hardware,
      ...
    }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      pkgs = nixpkgs.legacyPackages.${system};

      # The release this tree installs. New machines get it as their
      # stateVersion: it records what a machine was FIRST installed from, so
      # it is a property of the installer media and never an answer.
      release = lib.trivial.release;

      # ── the installer, generated from the options ──
      questions = import ./installer/questions.nix { inherit lib; };
      questionsJson = pkgs.writeText "wabisabi-questions.json" (builtins.toJSON questions);
      targetLock = pkgs.callPackage ./installer/lock.nix { inherit self; };
      secretsTool = pkgs.callPackage ./pkgs/wabisabi-secrets/package.nix { };
      usbTool = pkgs.callPackage ./pkgs/wabisabi-usb/package.nix { };

      # The restore kit's passphrase in the VM test, and in the usb-tool check.
      # A published test value, like installer/test-age-key.txt.
      testKitPassphrase = pkgs.writeText "wabisabi-test-kit-passphrase" "testkitpassphrase";

      mkInstaller =
        { offline }:
        pkgs.callPackage ./installer/package.nix {
          inherit offline targetLock secretsTool usbTool;
          questions = questionsJson;
          template = ./template;
          stateVersion = release;
          nixpkgsSource = nixpkgs;
        };

      payloads = import ./installer/payloads.nix {
        inherit
          lib
          self
          system
          questions
          ;
        nixosSystem = nixpkgs.lib.nixosSystem;
        homeManagerModule = home-manager.nixosModules.home-manager;
        stateVersion = release;
      };

      # The unattended answers for the VM test, derived from one file so the
      # plain and LUKS runs cannot drift apart.
      autotestAnswers =
        diskLayout:
        pkgs.runCommand "wabisabi-autotest-answers-${diskLayout}.json" { nativeBuildInputs = [ pkgs.jq ]; }
          ''
            jq '.["disk:layout"] = "${diskLayout}"
                | .["disk:passphrase"] = "testpassphrase"' \
              ${./installer/test-answers-vm.json} > $out
          '';

      # A config repo to restore from, for the VM test: what a fresh install
      # leaves in ~/nixos (emit, pinned lock, the secrets step with the
      # published test key), as a real git repo with its two commits. Its
      # hostname and user are ones the restore answers never mention, so a
      # restored machine that has them can only have read them from the repo.
      restoreFixture =
        pkgs.runCommand "wabisabi-restore-fixture"
          {
            nativeBuildInputs = [
              pkgs.git
              pkgs.jq
              pkgs.mkpasswd
              pkgs.python3
            ];
          }
          ''
            export HOME=$TMPDIR
            jq '.["identity:hostname"] = "restored" | .["identity:username"] = "mira"' \
              ${./installer/test-answers-vm.json} > answers.json
            mkdir -p $out
            bash ${./installer/emit.sh} --questions ${questionsJson} --answers answers.json \
              --template ${./template} --out $out --state-version ${release} \
              --wabisabi-url ${targetLock.url}
            install -m 0644 ${targetLock}/flake.lock $out/flake.lock
            # A stand-in: the restore replaces it with the real machine's.
            install -m 0644 ${./installer/test-hardware.nix} $out/hardware-configuration.nix
            git -C $out init -q -b main
            git -C $out add -A
            git -C $out -c user.name=t -c user.email=t@t commit -q -m "Install restored"
            printf '%s' testpassword | mkpasswd -m yescrypt --stdin > $TMPDIR/hash
            ${lib.getExe secretsTool} init --repo $out --root $TMPDIR/root --user mira \
              --key-file ${./installer/test-age-key.txt} --password-hash-file $TMPDIR/hash --yes
          '';

      restoreAnswers = pkgs.writeText "wabisabi-autotest-answers-restore.json" (
        builtins.toJSON {
          "install:mode" = "restore";
          "restore:source" = "${restoreFixture}";
          "restore:ageKey" = lib.last (
            lib.filter (l: lib.hasPrefix "AGE-SECRET-KEY-1" l) (
              lib.splitString "\n" (builtins.readFile ./installer/test-age-key.txt)
            )
          );
          "disk:device" = "/dev/vda";
          "disk:layout" = "plain";
        }
      );

      # A FLEET repo to restore from: two hosts, the wabisabi one declaring
      # its disks with disko, decrypting with its SSH host key, taking its
      # password from its own secret, and keeping its private host key in the
      # repo encrypted to the admin key (the test key) only. my-boxes' nono,
      # in miniature. See installer/test-fleet/hosts/laptop/default.nix.
      restoreFleetFixture =
        pkgs.runCommand "wabisabi-restore-fleet-fixture"
          {
            nativeBuildInputs = [
              pkgs.age
              pkgs.git
              pkgs.mkpasswd
              pkgs.openssh
              pkgs.sops
              pkgs.ssh-to-age
            ];
          }
          ''
            export HOME=$TMPDIR
            cp -r ${./installer/test-fleet} $out
            chmod -R u+w $out
            cd $out
            sed -i "s#WABISABI_URL#${targetLock.url}#" flake.nix
            sed -i "s#CHANGEME_STATE_VERSION#${release}#" hosts/laptop/default.nix
            install -m 0644 ${targetLock}/flake.lock flake.lock

            # The host key, minted ahead of the machine, as my-boxes does.
            ssh-keygen -q -t ed25519 -N "" -C laptop -f $TMPDIR/hostkey
            cp $TMPDIR/hostkey.pub hosts/laptop/ssh_host_ed25519_key.pub
            admin=$(age-keygen -y ${./installer/test-age-key.txt})
            hostage=$(ssh-to-age < $TMPDIR/hostkey.pub)
            cat > .sops.yaml <<EOF
            keys:
              - &admin $admin
              - &host_laptop $hostage
            creation_rules:
              # The host's own key material: admin only (it cannot decrypt
              # itself before it exists).
              - path_regex: secrets/laptop/ssh-host-key$
                key_groups:
                  - age: [*admin]
              - path_regex: secrets/laptop/[^/]+$
                key_groups:
                  - age: [*admin, *host_laptop]
              - path_regex: secrets/fleet.env$
                key_groups:
                  - age: [*admin]
            EOF

            mkdir -p secrets/laptop
            export SOPS_AGE_KEY_FILE=${./installer/test-age-key.txt}
            printf '%s' testpassword | mkpasswd -m yescrypt --stdin > $TMPDIR/hash
            sops encrypt --input-type binary --output-type binary \
              --filename-override secrets/laptop/user-password $TMPDIR/hash > secrets/laptop/user-password
            sops encrypt --input-type binary --output-type binary \
              --filename-override secrets/laptop/ssh-host-key $TMPDIR/hostkey > secrets/laptop/ssh-host-key
            printf 'FLEET_TOKEN=not-a-real-one\n' > $TMPDIR/fleet.env
            sops encrypt --input-type dotenv --output-type dotenv \
              --filename-override secrets/fleet.env $TMPDIR/fleet.env > secrets/fleet.env

            git init -q -b main
            git add -A
            git -c user.name=t -c user.email=t@t commit -q -m "A two-host fleet"
          '';

      restoreFleetAnswers = pkgs.writeText "wabisabi-autotest-answers-restore-fleet.json" (
        builtins.toJSON {
          "install:mode" = "restore";
          "restore:source" = "${restoreFleetFixture}";
          "restore:host" = "laptop";
          "restore:ageKey" = lib.last (
            lib.filter (l: lib.hasPrefix "AGE-SECRET-KEY-1" l) (
              lib.splitString "\n" (builtins.readFile ./installer/test-age-key.txt)
            )
          );
          "restore:repoPath" = "/home/tester/src/fleet";
        }
      );

      mkIso =
        {
          offline,
          autotest ? null,
        }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = {
            inherit offline autotest;
            # The offline medium is the LIVE one: it carries the whole desktop
            # anyway, so booting into it costs little, and it lets the machine
            # be tried before anything touches its disk (hosts/live.nix).
            live = offline;
            wabisabiModules = {
              system = self.nixosModules.wabisabi;
              home = self.homeModules.wabisabi;
              homeManager = home-manager.nixosModules.home-manager;
            };
            installer = mkInstaller { inherit offline; };
            nixpkgsSource = nixpkgs;
            # Everything the generated flake.lock names, so that the install
            # resolves entirely from the medium.
            sources = [
              self
              nixpkgs
              home-manager
              noctalia
              nixos-modules
              nixos-modules.inputs.wherever
              sops-nix
              disko
              nixos-hardware
            ];
            wabisabiRev = self.rev or "dirty";
            payloads = lib.optionals offline payloads.toplevels;
          };
          modules = [ ./hosts/iso.nix ];
        };

      # ── the emit-roundtrip check ──
      # Run the real emitter on a canned answer file, then evaluate what it
      # produced as a real NixOS configuration and assert that the answers
      # actually took effect. This is the join between template/ and the
      # installer: if either drifts, this stops evaluating or stops matching.
      emitted =
        pkgs.runCommand "wabisabi-emitted-flake"
          {
            nativeBuildInputs = [
              pkgs.jq
              pkgs.python3
            ];
          }
          ''
            bash ${./installer/emit.sh} \
              --questions ${questionsJson} \
              --answers ${./installer/test-answers.json} \
              --template ${./template} \
              --out $out \
              --state-version ${release}
            cp ${./installer/test-hardware.nix} $out/hardware-configuration.nix
          '';

      # The same, then put through the real secrets step exactly as the
      # installer runs it, with the published test key. What comes out is the
      # two-commit repo an installed machine starts from.
      emittedWithSecrets =
        pkgs.runCommand "wabisabi-emitted-flake-secrets"
          {
            nativeBuildInputs = [
              pkgs.git
              pkgs.mkpasswd
            ];
          }
          ''
            export HOME=$TMPDIR
            root=$TMPDIR/target
            repo=$root/home/wighawag/nixos
            mkdir -p "$repo"
            cp -r ${emitted}/. "$repo/"
            chmod -R u+w "$repo"
            git -C "$repo" init -q -b main
            git -C "$repo" add -A
            git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m install
            printf '%s' testpassword | mkpasswd -m yescrypt --stdin > $TMPDIR/hash
            ${lib.getExe secretsTool} init --repo "$repo" --root "$root" --user wighawag \
              --key-file ${./installer/test-age-key.txt} \
              --password-hash-file $TMPDIR/hash --yes
            test "$(git -C "$repo" rev-list --count HEAD)" = 2
            test -s "$root/var/lib/sops-nix/key.txt"
            test -s "$root/home/wighawag/.config/sops/age/keys.txt"
            git -C "$repo" diff --quiet HEAD
            rm -rf "$repo/.git"
            cp -r "$repo" $out
          '';

      emittedSecretsSystem = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          wabisabi = self;
        };
        modules = [
          self.nixosModules.wabisabi
          home-manager.nixosModules.home-manager
          "${emittedWithSecrets}/configuration.nix"
        ];
      };

      emittedSystem = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          wabisabi = self;
        };
        modules = [
          self.nixosModules.wabisabi
          home-manager.nixosModules.home-manager
          "${emitted}/configuration.nix"
        ];
      };

      # ── the searchcast backend, against a FIXTURE recipe set ──
      # Never a real set: two code recipes that answer from memory (no request
      # anywhere), packed the way `searchcast install-recipes` takes a set
      # (one top-level directory, a manifest, *.mjs files). It is served to
      # the real `search.recipes` path as a file:// URL: the URL carries the
      # archive's store path as context, so the fetch sees it in the sandbox,
      # and the whole route (fetchurl against the sha256, the strict unpack,
      # the chain read from the set's file names) runs with no network.
      recipeFixtureArchive = pkgs.runCommand "wabisabi-fixture-recipes.tar.gz" { } ''
        mkdir fixture-set
        echo '{"name": "fixture-set", "version": "0.0.0"}' > fixture-set/manifest.json
        for e in engine-a engine-b; do
          printf '%s\n' \
            'export default {' \
            "  name: '$e'," \
            '  async search(query) {' \
            "    return [{title: '$e answer', url: 'https://example.invalid/$e?q=' + encodeURIComponent(query)}];" \
            '  },' \
            '};' > fixture-set/$e.mjs
        done
        tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@1 -czf $out fixture-set
      '';
      recipeFixture = {
        url = "file://${recipeFixtureArchive}";
        # Hex, as a publisher hands it out and the installer asks for it.
        sha256 = builtins.hashFile "sha256" recipeFixtureArchive;
      };

      # The installer's route: the recipe answers emitted into a config.
      emittedSearchcast =
        pkgs.runCommand "wabisabi-emitted-flake-searchcast"
          {
            nativeBuildInputs = [
              pkgs.jq
              pkgs.python3
            ];
          }
          ''
            # test-answers.json forces searxng (its SearXNG checks must not
            # depend on what auto means); this one answers auto.
            jq '.["system:search.backend"] = "auto"
                | .["system:search.recipes.url"] = "${recipeFixture.url}"
                | .["system:search.recipes.sha256"] = "${recipeFixture.sha256}"
                | .["system:search.engines"] = "engine-b engine-a"' \
              ${./installer/test-answers.json} > answers.json
            bash ${./installer/emit.sh} \
              --questions ${questionsJson} \
              --answers answers.json \
              --template ${./template} \
              --out $out \
              --state-version ${release}
            cp ${./installer/test-hardware.nix} $out/hardware-configuration.nix
          '';

      emittedSearchcastSystem = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          wabisabi = self;
        };
        modules = [
          self.nixosModules.wabisabi
          home-manager.nixosModules.home-manager
          "${emittedSearchcast}/configuration.nix"
        ];
      };
    in
    {
      # System-level layer: services, programs, sane hardware-agnostic defaults.
      # Knows nothing about your disks, drivers or CPU.
      #
      # It includes nixos-modules' building blocks, which modules/agents.nix
      # switches on; a consumer imports this one module and gets both.
      nixosModules.wabisabi = {
        imports = [
          ./modules
          nixos-modules.nixosModules.default
          # For wabisabi.secrets (modules/secrets.nix). A config that already
          # imports sops-nix should make wabisabi's input follow its own, so
          # both imports are the same path and the module system dedups them.
          sops-nix.nixosModules.sops
        ];
      };

      # User-level layer: apps, dotfiles, keybinds, theming.
      # Also usable standalone with home-manager on any distro.
      homeModules.wabisabi = {
        imports = [ ./home ];
        # Injected rather than fetched inside the module, so the pin lives in
        # flake.lock (updatable with `nix flake update noctalia`) and consumers
        # need to wire nothing.
        _module.args.noctaliaSrc = noctalia;
      };

      # A demo machine proving the layers are hardware-agnostic:
      #   nixos-rebuild build-vm --flake .#demo   → boots the whole desktop in QEMU
      nixosConfigurations.demo = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit self; };
        modules = [
          home-manager.nixosModules.home-manager
          self.nixosModules.wabisabi
          (
            { config, ... }:
            {
              # Wire the home layer for the demo user.
              home-manager.users.demo = {
                imports = [ self.homeModules.wabisabi ];
                wabisabi.enable = true;
                # QEMU on a desktop host: your compositor eats Super+key before the
                # VM can see it. Use ALT in the VM; back to SUPER on real hardware.
                wabisabi.modKey = "ALT";
                # The demo VM renders through VirGL, which is a real GL stack but
                # not a fast one. Animations are full-screen redraws; turn them off.
                wabisabi.animations = false;
                # Ghostty compiles its shaders on first launch, which on a virtual
                # GPU takes ~35s before a window appears. foot is CPU-rendered and
                # opens instantly, which is what you want when kicking the tyres.
                # On real hardware the default (ghostty) is fine.
                wabisabi.terminal = "foot";
              };
            }
          )
          ./hosts/demo.nix
        ];
      };

      # The installer media. Both install the exact revision they were built
      # from; see installer/lock.nix for why that matters.
      nixosConfigurations.isoNetinstall = mkIso { offline = false; };
      nixosConfigurations.isoOffline = mkIso { offline = true; };

      # Test media: identical to the above but installs unattended and powers
      # off. Built by scripts/test-install-vm.sh, not meant for a USB stick.
      nixosConfigurations.isoAutotest = mkIso {
        offline = false;
        autotest = autotestAnswers "plain";
      };
      nixosConfigurations.isoAutotestLuks = mkIso {
        offline = false;
        autotest = autotestAnswers "luks";
      };
      nixosConfigurations.isoAutotestRestore = mkIso {
        offline = false;
        autotest = restoreAnswers;
      };
      nixosConfigurations.isoAutotestRestoreFleet = mkIso {
        offline = false;
        autotest = restoreFleetAnswers;
      };
      # The fleet restore again, but from a RESTORE KIT on the installer's own
      # stick (wabisabi-usb), with no answers file at all: the harness writes
      # this ISO and a kit to a stick image, and boots from it.
      nixosConfigurations.isoAutotestRestoreKit = mkIso {
        offline = false;
        autotest = {
          kitPassphrase = testKitPassphrase;
          # The fixture the kit points at, in the medium's store.
          keep = [ restoreFleetFixture ];
        };
      };
      nixosConfigurations.isoAutotestOffline = mkIso {
        offline = true;
        autotest = autotestAnswers "plain";
      };

      packages.${system} =
        # The agent layer's packages: nixos-modules' own, which build against
        # our nixpkgs through its follows, so they can be built and cached here
        # (`nix build .#anonctl`). The modules do not use these: they build the
        # same files against the importing system's pkgs.
        nixos-modules.packages.${system}
        // {
        default = self.packages.${system}.installer;
        installer = mkInstaller { offline = false; };
        questions = questionsJson;
        target-lock = targetLock;
        wabisabi-secrets = secretsTool;
        usb = usbTool;
        wabisabi-usb = usbTool;
        iso-netinstall = self.nixosConfigurations.isoNetinstall.config.system.build.isoImage;
        iso-offline = self.nixosConfigurations.isoOffline.config.system.build.isoImage;
        iso-autotest = self.nixosConfigurations.isoAutotest.config.system.build.isoImage;
        iso-autotest-luks = self.nixosConfigurations.isoAutotestLuks.config.system.build.isoImage;
        iso-autotest-offline = self.nixosConfigurations.isoAutotestOffline.config.system.build.isoImage;
        iso-autotest-restore = self.nixosConfigurations.isoAutotestRestore.config.system.build.isoImage;
        restore-fixture = restoreFixture;
        iso-autotest-restore-fleet = self.nixosConfigurations.isoAutotestRestoreFleet.config.system.build.isoImage;
        restore-fleet-fixture = restoreFleetFixture;
        iso-autotest-restore-kit = self.nixosConfigurations.isoAutotestRestoreKit.config.system.build.isoImage;
        test-kit-passphrase = testKitPassphrase;
      };

      checks.${system} =
        let
          c = emittedSystem.config;
          home = c.home-manager.users.wighawag.wabisabi;

          # Answers from installer/test-answers.json, and what each one should
          # have done to the evaluated system.
          expectations = [
            {
              name = "hostname is substituted";
              expected = "kestrel";
              actual = c.networking.hostName;
            }
            {
              name = "the user account exists";
              expected = true;
              actual = c.users.users ? wighawag;
            }
            {
              name = "no password material reached the config";
              expected = null;
              actual = c.users.users.wighawag.initialPassword;
            }
            {
              name = "stateVersion is the installing release";
              expected = release;
              actual = c.system.stateVersion;
            }
            {
              name = "the keyboard answer reaches xkb";
              expected = "fr";
              actual = c.services.xserver.xkb.layout;
            }
            {
              name = "the keyboard answer reaches localed's file";
              expected = true;
              actual = lib.hasInfix ''"XkbLayout" "fr"'' c.environment.etc."X11/xorg.conf.d/00-keyboard.conf".text;
            }
            {
              name = "the console follows the same layout";
              expected = true;
              actual = c.console.useXkbConfig;
            }
            {
              name = "xkb options reach xkb";
              expected = "caps:escape";
              actual = c.services.xserver.xkb.options;
            }
            {
              name = "a false answer is honoured (tor)";
              expected = false;
              actual = c.services.tor.enable;
            }
            {
              name = "the owner is the created user (wabisabi.user)";
              expected = "wighawag";
              actual = c.wabisabi.user;
            }
            {
              name = "an unanswered agent option keeps the project default (local model on)";
              expected = true;
              actual = c.systemd.services ? wabisabi-llm;
            }
            {
              name = "the owner may reach the local model's socket";
              expected = true;
              actual = lib.elem "wabisabi-llm" c.users.users.wighawag.extraGroups;
            }
            {
              name = "the owner's pi gets the local-model extension";
              expected = true;
              actual = c.environment.etc ? "wabisabi/pi-extensions/pi-wabisabi-local";
            }
            # test-answers.json answers backend = searxng, so this is checked
            # on a machine forced to SearXNG, whatever `auto` comes to mean.
            {
              name = "the backend answer is honoured (searxng: the owner's webveil asks the local SearXNG)";
              expected = {
                searxng = true;
                backend = "searxng";
              };
              actual = {
                searxng = c.nixos-modules.searxng.enable;
                backend =
                  (builtins.fromJSON (
                    builtins.unsafeDiscardStringContext c.environment.etc."wabisabi/pi-seed/webveil.json".text
                  )).backend;
              };
            }
            {
              name = "search through Tor, answered, reaches SearXNG";
              expected = [ "socks5h://127.0.0.1:9050" ];
              actual = c.nixos-modules.searxng.egressProxies;
            }
            {
              name = "a false answer is honoured (anon accounts)";
              expected = false;
              actual = c.users.users ? anon-john;
            }
            {
              name = "the greeter answer is honoured";
              expected = true;
              actual = c.services.greetd.settings.default_session.command != null;
            }
            {
              name = "splash off means no plymouth";
              expected = false;
              actual = c.boot.plymouth.enable;
            }
            {
              name = "the firmware answer is honoured";
              expected = true;
              actual = c.hardware.enableRedistributableFirmware;
            }
            {
              name = "the detected GPU driver reaches the initrd";
              expected = true;
              actual = lib.elem "amdgpu" c.boot.initrd.kernelModules;
            }
            {
              name = "home answers reach the home layer (browser)";
              expected = "librewolf";
              actual = home.browser;
            }
            {
              name = "home answers reach the home layer (shell)";
              expected = "classic";
              actual = home.shell;
            }
            {
              name = "the owner's home surfaces the assistant (it runs wherever for them)";
              expected = true;
              actual = home.assistant.enable;
            }
            {
              name = "the classic bar carries the assistant button";
              expected = "custom/assistant";
              actual = lib.head c.home-manager.users.wighawag.programs.waybar.settings.mainBar.modules-right;
            }
            {
              name = "an optional app answer is honoured";
              expected = true;
              actual = home.apps.office;
            }
            # test-answers.json deliberately leaves these two out, one per
            # layer: an option nobody answered must keep tracking wabisabi's
            # default rather than being frozen into the generated config.
            {
              name = "an unanswered home option keeps the project default";
              expected = "neovim";
              actual = home.editor;
            }
            {
              name = "an unanswered system option keeps the project default";
              expected = "";
              actual = c.services.xserver.xkb.variant;
            }
            {
              name = "the flake's home is linked from /etc/nixos";
              expected = "/home/wighawag/nixos";
              actual = c.environment.etc.nixos.source;
            }
            {
              name = "without the secrets step, no secrets are configured";
              expected = null;
              actual = c.wabisabi.secrets.sopsFile;
            }
            {
              name = "unanswered options are not written into the config";
              expected = false;
              actual = lib.hasInfix "wabisabi.editor" (builtins.readFile "${emitted}/configuration.nix");
            }
          ];

          s = emittedSecretsSystem.config;
          secretsExpectations = [
            {
              name = "the secrets step enables the secrets file";
              expected = true;
              actual = s.wabisabi.secrets.sopsFile != null;
            }
            {
              name = "sops-nix reads the machine's age key, and only that";
              expected = {
                keyFile = "/var/lib/sops-nix/key.txt";
                sshKeyPaths = [ ];
              };
              actual = {
                inherit (s.sops.age) keyFile sshKeyPaths;
              };
            }
            {
              name = "the owner's password comes from the secret, decrypted before users exist";
              expected = {
                file = "/run/secrets-for-users/owner-password";
                early = true;
              };
              actual = {
                file = s.users.users.wighawag.hashedPasswordFile;
                early = s.sops.secrets.owner-password.neededForUsers;
              };
            }
          ];

          failures = lib.filter (e: e.actual != e.expected) (expectations ++ secretsExpectations);

          report = lib.concatMapStringsSep "\n  " (
            e: "${e.name}: expected ${builtins.toJSON e.expected}, got ${builtins.toJSON e.actual}"
          ) failures;

          # The agent layer as the DEMO host gets it: every default on, so
          # this is the shape a fresh install has. Each claim is one of the
          # load-bearing properties the modules' comments argue for, pinned
          # so a refactor that quietly drops one fails `nix flake check`.
          d = self.nixosConfigurations.demo.config;
          anonHomeSettings = builtins.fromJSON (
            builtins.unsafeDiscardStringContext d.environment.etc."anon-home/settings.json".text
          );
          agentClaims = [
            {
              name = "the model server has no network at all";
              ok = d.systemd.services.wabisabi-llm.serviceConfig.PrivateNetwork;
            }
            {
              name = "the model is served on a unix socket";
              ok = lib.hasInfix "--host /run/wabisabi-llm/llm.sock" d.systemd.services.wabisabi-llm.serviceConfig.ExecStart;
            }
            {
              name = "the declared anon slots exist with their pinned uids";
              ok =
                d.users.users.anon.uid == 8801
                && d.users.users.anon-john.uid == 8802
                && d.users.users.anon-jane.uid == 8803;
            }
            {
              name = "every anon slot may reach the model socket (no jail exemption needed)";
              ok = lib.all (a: lib.elem "wabisabi-llm" d.users.users.${a}.extraGroups) [
                "anon"
                "anon-john"
                "anon-jane"
              ];
            }
            {
              name = "anon sessions start on the local model";
              ok = anonHomeSettings.defaultProvider == "local" && anonHomeSettings.defaultModel == "gemma-4-e4b";
            }
            {
              name = "anon sessions load the local-model extension from the store";
              ok = lib.any (p: lib.hasInfix "pi-wabisabi-local" p) anonHomeSettings.packages;
            }
            {
              name = "the anon dispatcher binds loopback only";
              ok = d.services.caddy.virtualHosts."http://*.localhost:8480".listenAddresses == [ "127.0.0.1" ];
            }
            {
              name = "the Tor client is on for the anon accounts";
              ok = d.services.tor.enable && d.services.tor.client.enable;
            }
            {
              name = "the agent layer opens no firewall port";
              ok =
                !(lib.any (p: lib.elem p d.networking.firewall.allowedTCPPorts) [
                  8480
                  11435
                  31415
                ]);
            }
            {
              name = "the owner's desktop reaches the assistant: launcher entry, Mod+A, welcome";
              ok =
                let
                  h = d.home-manager.users.demo;
                in
                h.xdg.desktopEntries ? wabisabi-assistant
                && h.wayland.windowManager.niri.settings.binds ? "Mod+A"
                && h.systemd.user.services ? wabisabi-assistant-welcome;
            }
            {
              name = "the assistant's URL (and so its token) is resolved at click time, never baked in";
              ok =
                let
                  h = d.home-manager.users.demo;
                  exec = h.xdg.desktopEntries.wabisabi-assistant.exec;
                in
                lib.hasSuffix "/bin/wabisabi-assistant" exec
                && h.wayland.windowManager.niri.settings.binds."Mod+A".spawn == exec;
            }
            {
              name = "with the local model off, the anon accounts follow it off and the machine evaluates";
              ok =
                let
                  h = self.nixosConfigurations.demo.extendModules {
                    modules = [ { wabisabi.llm.enable = false; } ];
                  };
                in
                !h.config.wabisabi.anon.enable
                && !(h.config.users.users ? anon)
                && builtins.isString h.config.system.build.toplevel.drvPath;
            }
            {
              name = "anon accounts forced on without the local model are refused, saying why";
              ok =
                let
                  h = self.nixosConfigurations.demo.extendModules {
                    modules = [
                      {
                        wabisabi.llm.enable = false;
                        wabisabi.anon.enable = true;
                      }
                    ];
                  };
                in
                lib.any (
                  a: !a.assertion && lib.hasInfix "wabisabi.anon.enable is true but wabisabi.llm.enable is false" a.message
                ) h.config.assertions;
            }
            {
              name = "enrolment never holds up the boot";
              ok = !(lib.elem "multi-user.target" (d.systemd.services.wabisabi-anon-enroll.wantedBy or [ ]));
            }
          ];
          # The interactive bash stack's ORDER, read from the generated
          # /etc/bashrc because it is decided by how NixOS merges the pieces,
          # which is the thing that can silently change: atuin must come after
          # fzf or fzf owns Ctrl-R, and ble.sh is sourced first, attached last.
          # (Carried over from my-boxes' interactive-shell-order check.)
          bashrc = d.environment.etc.bashrc.text;
          bashMarkers = [
            "share/blesh/ble.sh --noattach"
            "/bin/fzf --bash"
            "/bin/zoxide init bash"
            "/bin/atuin init bash --disable-up-arrow --disable-ai"
            "/bin/starship init bash"
            "shell-integration/bash/ghostty.bash"
            "&& ble-attach"
          ];
          offsetIn =
            m:
            let
              parts = lib.splitString m bashrc;
            in
            if lib.length parts < 2 then -1 else lib.stringLength (lib.head parts);
          bashOffsets = map offsetIn bashMarkers;
          ascending = l: lib.length l < 2 || (lib.elemAt l 0 < lib.elemAt l 1 && ascending (lib.tail l));
          shellClaims = [
            {
              name = "every step of the interactive bash init is in /etc/bashrc, in order (ble.sh, fzf, zoxide, atuin, starship, ghostty's integration, ble-attach)";
              ok = lib.all (o: o >= 0) bashOffsets && ascending bashOffsets;
            }
            {
              name = "fzf does not bind Ctrl-R, and nothing else layers on top of atuin";
              ok =
                lib.hasInfix "FZF_CTRL_R_COMMAND=\n" bashrc
                && !lib.hasInfix "fzf/key-bindings.bash" bashrc
                && !lib.hasInfix "bash-preexec" bashrc;
            }
            {
              name = "the bash stack is gated on an interactive shell at a real terminal (never an agent's TERM=dumb shell)";
              ok = lib.hasInfix "if [[ $- == *i* && \${TERM-dumb} != dumb ]]; then" bashrc;
            }
          ];
          agentFailures = map (c: c.name) (lib.filter (c: !c.ok) (agentClaims ++ shellClaims));

          # ── the search backend, both ways ──
          # The demo host with the FIXTURE recipe set given the way an owner
          # gives one (`search.recipes`, here with an SRI hash; the emitted
          # config below uses hex), and variants of it. `auto` must turn it
          # into searchcast for the owner and every anon account, with no
          # SearXNG anywhere; forcing `searxng` must give today's setup back.
          withSearch =
            m:
            self.nixosConfigurations.demo.extendModules {
              modules = [ { wabisabi.search = m; } ];
            };
          fixtureSri = builtins.convertHash {
            hash = recipeFixture.sha256;
            hashAlgo = "sha256";
            toHashFormat = "sri";
          };
          # The chain names Mwmbl but not Marginalia, so only Mwmbl's bundled
          # file may come along.
          fixtureChain = [
            "engine-a"
            "engine-b"
            "mwmbl"
          ];
          sc = withSearch {
            recipes = {
              inherit (recipeFixture) url;
              sha256 = fixtureSri;
            };
            engines = fixtureChain;
          };
          scTor = withSearch {
            recipes = {
              inherit (recipeFixture) url;
              sha256 = fixtureSri;
            };
            viaTor = true;
            engines = fixtureChain;
          };
          scForcedSearxng = withSearch {
            recipes = {
              inherit (recipeFixture) url;
              sha256 = fixtureSri;
            };
            backend = "searxng";
            engines = fixtureChain;
          };
          scBare = withSearch { backend = "searchcast"; };
          # A set with no chain: refused, since the order cannot be guessed.
          scNoChain = withSearch {
            recipes = {
              inherit (recipeFixture) url;
              sha256 = fixtureSri;
            };
          };

          readJson = text: builtins.fromJSON (builtins.unsafeDiscardStringContext text);
          ownerJson = h: readJson h.config.environment.etc."wabisabi/pi-seed/webveil.json".text;
          anonJson = h: a: readJson h.config.environment.etc."anon-home/webveil-${a}.json".text;
          anonSlots = [
            "anon"
            "anon-john"
            "anon-jane"
          ];
          noSearxng =
            h:
            !(h.config.systemd.services ? wabisabi-searxng)
            && !(h.config.systemd.sockets ? wabisabi-searxng)
            && !(lib.any (lib.hasPrefix "anon-search") (
              lib.attrNames h.config.systemd.sockets ++ lib.attrNames h.config.systemd.services
            ))
            && !h.config.nixos-modules.searxng.enable
            && !h.config.nixos-modules.anonSearch.enable;

          scOwner = ownerJson sc;
          setPath = lib.head scOwner.searchcast.codeRecipes;
          searchClaims = [
            {
              name = "with no recipe set, auto is SearXNG, as before (the demo)";
              ok =
                d.nixos-modules.searxng.enable
                && d.nixos-modules.anonSearch.enable
                && (ownerJson self.nixosConfigurations.demo).backend == "searxng"
                && d.nixos-modules.anonHome.webTools.backend == "searxng";
            }
            {
              name = "with a recipe set, auto is searchcast and no SearXNG runs: no unit, no anon-search socket";
              ok = noSearxng sc;
            }
            {
              name = "the owner's webveil is on searchcast, direct, with the set and only the bundled recipes the chain names, from the store";
              ok =
                scOwner.backend == "searchcast"
                && scOwner.egress == { mode = "direct"; }
                && !(scOwner ? baseUrl)
                && !(scOwner ? fetchEgress)
                && lib.hasSuffix "-wabisabi-search-recipes" setPath
                && lib.all (lib.hasPrefix "/nix/store/") scOwner.searchcast.codeRecipes
                && map baseNameOf (lib.tail scOwner.searchcast.codeRecipes) == [ "mwmbl.mjs" ];
            }
            {
              name = "the chain is the owner's, as given";
              ok = scOwner.searchcast.engines == fixtureChain;
            }
            {
              name = "a recipe set with no chain is refused, saying why";
              ok = lib.any (
                a: !a.assertion && lib.hasInfix "wabisabi.search.engines is empty" a.message
              ) scNoChain.config.assertions;
            }
            {
              name = "every anon account gets searchcast with the same recipes and chain, egress direct, state in memory";
              ok = lib.all (
                a:
                let
                  j = anonJson sc a;
                in
                j.backend == "searchcast"
                && j.egress == { mode = "direct"; }
                && !(j ? baseUrl)
                && j.searchcast.state.persist == false
                && j.searchcast.codeRecipes == scOwner.searchcast.codeRecipes
                && j.searchcast.engines == fixtureChain
              ) anonSlots;
            }
            {
              name = "the owner is not put in SearXNG's group when there is none";
              ok = !(lib.elem sc.config.nixos-modules.searxng.clientGroup sc.config.users.users.demo.extraGroups);
            }
            {
              name = "search through Tor, on searchcast, is the owner's webveil egress (web_fetch inherits it); the anon accounts stay direct under anonctl";
              ok =
                (ownerJson scTor).egress == {
                  mode = "socks5";
                  url = "socks5h://127.0.0.1:9050";
                }
                && !((ownerJson scTor) ? fetchEgress)
                && (anonJson scTor "anon").egress == { mode = "direct"; }
                && noSearxng scTor;
            }
            {
              name = "backend = searxng wins over a recipe set: today's SearXNG setup, owner and anon";
              ok =
                scForcedSearxng.config.nixos-modules.searxng.enable
                && scForcedSearxng.config.nixos-modules.anonSearch.enable
                && ownerJson scForcedSearxng == ownerJson self.nixosConfigurations.demo
                && (anonJson scForcedSearxng "anon").backend == "searxng";
            }
            {
              name = "searchcast with no recipe set is webveil's own default chain (no recipes, no chain written, as webveil requires), and still no SearXNG";
              ok =
                let
                  o = ownerJson scBare;
                  j = anonJson scBare "anon";
                in
                o.backend == "searchcast"
                && !(o ? searchcast)
                && j.backend == "searchcast"
                && j.searchcast == { state.persist = false; }
                && noSearxng scBare;
            }
          ];
          searchFailures = map (c: c.name) (lib.filter (c: !c.ok) searchClaims);

          # The installer's route to searchcast: the recipe answers, emitted.
          e = emittedSearchcastSystem.config;
          eOwner = readJson e.environment.etc."wabisabi/pi-seed/webveil.json".text;
          emittedSearchcastExpectations = [
            {
              name = "the recipe answers make the emitted machine searchcast (auto), with no SearXNG";
              expected = {
                backend = "searchcast";
                searxng = false;
              };
              actual = {
                inherit (eOwner) backend;
                searxng = e.nixos-modules.searxng.enable;
              };
            }
            {
              name = "the answered chain is used as given, with only the set behind it";
              expected = {
                engines = [
                  "engine-b"
                  "engine-a"
                ];
                recipes = 1;
              };
              actual = {
                inherit (eOwner.searchcast) engines;
                recipes = lib.length eOwner.searchcast.codeRecipes;
              };
            }
            {
              name = "search through Tor, answered, is the searchcast egress";
              expected = "socks5h://127.0.0.1:9050";
              actual = eOwner.egress.url or null;
            }
            {
              name = "the recipe answers are written into the config (as the question says)";
              expected = true;
              actual = lib.hasInfix (builtins.unsafeDiscardStringContext ''wabisabi.search.recipes.url = "${recipeFixture.url}";'') (
                builtins.readFile "${emittedSearchcast}/configuration.nix"
              );
            }
          ];
          emittedSearchcastFailures = lib.filter (x: x.actual != x.expected) emittedSearchcastExpectations;
        in
        {
          agent-layer = lib.throwIf (agentFailures != [ ]) ''
            wabisabi: the agent layer no longer holds these claims on the demo host:
              ${lib.concatStringsSep "\n  " agentFailures}
          '' pkgs.writeText "wabisabi-agent-layer" (lib.concatMapStringsSep "\n" (c: c.name) (agentClaims ++ shellClaims));

          # `niri validate` runs inside this derivation, which is the reason
          # the compositor was chosen. Until it was a check, nothing in
          # `nix flake check` ever built it, so nothing ever ran it.
          niri-config = self.nixosConfigurations.demo.config.home-manager.users.demo.xdg.configFile."niri/config.kdl".source;

          # Forces the coverage rule in installer/questions.nix.
          installer-questions = questionsJson;

          # Which questions the installer ASKS, walked in order with the rule
          # it runs (applies.jq) over sample answers: the recipe set only for
          # a backend that can use one, its hash and chain only once a URL is
          # given, and the existing conditions (the LUKS passphrase) intact.
          installer-question-flow =
            pkgs.runCommand "wabisabi-installer-question-flow" { nativeBuildInputs = [ pkgs.jq ]; }
              ''
                # walk SCENARIO: answer every asked question from SCENARIO,
                # else with its default; print the asked keys, in order.
                walk() {
                  local answers='{}' item key value
                  while IFS= read -r item; do
                    jq -e --argjson answers "$answers" -f ${./installer/applies.jq} <<<"$item" >/dev/null || continue
                    key=$(jq -r .key <<<"$item")
                    value=$(jq -r --arg k "$key" --argjson item "$item" '.[$k] // $item.default // ""' <<<"$1")
                    answers=$(jq --arg k "$key" --arg v "$value" '. + {($k): $v}' <<<"$answers")
                    echo "$key"
                  done < <(jq -c '.groups[].items[]' ${questionsJson})
                }
                search() { walk "$1" | grep '^system:search\.' | tr '\n' ' '; }
                expect() {
                  if [ "$2" != "$3" ]; then
                    echo "$1:"; echo "  expected: $3"; echo "  got:      $2"; exit 1
                  fi
                }

                expect "backend searxng: no recipe questions" \
                  "$(search '{"system:search.backend": "searxng"}')" \
                  "system:search.enable system:search.backend system:search.viaTor "
                expect "auto, no URL: the URL is offered, nothing after it" \
                  "$(search '{}')" \
                  "system:search.enable system:search.backend system:search.recipes.url system:search.viaTor "
                expect "auto with a URL: its hash and the chain follow, in order" \
                  "$(search '{"system:search.recipes.url": "https://example.invalid/set.tar.gz"}')" \
                  "system:search.enable system:search.backend system:search.recipes.url system:search.recipes.sha256 system:search.engines system:search.viaTor "
                expect "searchcast with a URL: the same" \
                  "$(search '{"system:search.backend": "searchcast", "system:search.recipes.url": "https://example.invalid/set.tar.gz"}')" \
                  "system:search.enable system:search.backend system:search.recipes.url system:search.recipes.sha256 system:search.engines system:search.viaTor "
                anon() { walk "$1" | grep -c '^system:anon\.' || true; }
                expect "no local model: no anon questions" "$(anon '{"system:llm.enable": "false"}')" "0"
                expect "the local model: both anon questions" "$(anon '{}')" "2"
                expect "anon off: no enrolment question" "$(anon '{"system:anon.enable": "false"}')" "1"
                expect "the LUKS passphrase still follows its layout" \
                  "$(walk '{"disk:layout": "plain"}' | grep -c '^disk:passphrase$' || true)" "0"
                expect "the LUKS passphrase is asked for LUKS" \
                  "$(walk '{"disk:layout": "luks"}' | grep -c '^disk:passphrase$')" "1"

                # Once a URL is given, the chain cannot be left empty.
                jq -e '.groups[].items[] | select(.key == "system:search.engines") | .required == true' ${questionsJson}

                # The hash question refuses what Nix would refuse.
                pattern=$(jq -r '.groups[].items[] | select(.key == "system:search.recipes.sha256") | .pattern' ${questionsJson})
                [[ "${recipeFixture.sha256}" =~ ^($pattern)$ ]]
                [[ "sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=" =~ ^($pattern)$ ]]
                ! [[ "not-a-hash" =~ ^($pattern)$ ]]
                ! [[ "${recipeFixture.sha256}x" =~ ^($pattern)$ ]]
                touch $out
              '';

          search-backend = lib.throwIf (searchFailures != [ ]) ''
            wabisabi: the search backend no longer holds these claims:
              ${lib.concatStringsSep "\n  " searchFailures}
          '' pkgs.writeText "wabisabi-search-backend" (lib.concatMapStringsSep "\n" (c: c.name) searchClaims);

          emit-searchcast =
            lib.throwIf (emittedSearchcastFailures != [ ])
              ''
                wabisabi: the installer's recipe answers did not do what was answered:
                  ${lib.concatMapStringsSep "\n  " (
                    x: "${x.name}: expected ${builtins.toJSON x.expected}, got ${builtins.toJSON x.actual}"
                  ) emittedSearchcastFailures}
              ''
              pkgs.runCommand "wabisabi-emit-searchcast" { }
              ''
                echo ${builtins.hashString "sha256" emittedSearchcastSystem.config.system.build.toplevel.drvPath} > $out
              '';

          # The generated configs, RUN: webveil (the package the bundled
          # recipe paths come from) searches with the owner's and an anon
          # account's config exactly as the demo-with-fixture host writes
          # them. Building this fetches the fixture through the real
          # fetchurl-and-unpack route. The fixture's first engine answers from
          # memory, and a build sandbox has no network anyway, so no request
          # leaves. Then the unpack script's refusals, on bad archives.
          searchcast-runs =
            pkgs.runCommand "wabisabi-searchcast-runs"
              {
                nativeBuildInputs = [
                  pkgs.jq
                  pkgs.gnutar
                  pkgs.gzip
                ];
              }
              ''
                run() {
                  local home=$TMPDIR/home-$1
                  mkdir -p $home/.config/webveil
                  cp $2 $home/.config/webveil/config.json
                  HOME=$home XDG_CONFIG_HOME=$home/.config XDG_STATE_HOME=$home/.local/state \
                    ${sc.config.nixos-modules.pkgs.webveil}/bin/webveil search hello --format json > $TMPDIR/$1.json
                  jq -e '.results[0].title == "engine-a answer"' $TMPDIR/$1.json
                }
                run owner ${sc.config.environment.etc."wabisabi/pi-seed/webveil.json".source}
                run anon ${sc.config.environment.etc."anon-home/webveil-anon.json".source}

                unpack=${./modules/agents/unpack-recipe-set.sh}
                mk() { tar --sort=name --owner=0 --group=0 --mtime=@1 -czf $TMPDIR/$1.tar.gz -C $TMPDIR/$1 .; }
                refuses() {
                  if bash $unpack $TMPDIR/$1.tar.gz $TMPDIR/out-$1 2>$TMPDIR/err-$1; then
                    echo "the unpack accepted a bad set: $1"; exit 1
                  fi
                  grep -q "$2" $TMPDIR/err-$1 || { cat $TMPDIR/err-$1; exit 1; }
                }
                mkdir -p $TMPDIR/flat $TMPDIR/nested/set/sub $TMPDIR/link/set $TMPDIR/hidden/set $TMPDIR/other/set
                echo 'export default {}' > $TMPDIR/flat/engine-a.mjs
                mk flat
                bash $unpack $TMPDIR/flat.tar.gz $TMPDIR/out-flat
                test -f $TMPDIR/out-flat/engine-a.mjs
                echo x > $TMPDIR/nested/set/sub/engine-a.mjs; mk nested; refuses nested "nested directory"
                ln -s /etc/passwd $TMPDIR/link/set/engine-a.mjs; mk link; refuses link "only regular files"
                echo x > $TMPDIR/hidden/set/.engine-a.mjs; mk hidden; refuses hidden "hidden file"
                echo x > $TMPDIR/other/set/run.sh; mk other; refuses other "not a recipe file"
                touch $out
              '';

          installer-lint =
            pkgs.runCommand "wabisabi-installer-lint" { nativeBuildInputs = [ pkgs.shellcheck ]; }
              ''
                shellcheck --shell=bash --severity=style \
                  ${./installer/install.sh} ${./installer/emit.sh} \
                  ${./installer/disks.sh} ${./pkgs/wabisabi-usb/wabisabi-usb.sh} \
                  ${./pkgs/wabisabi-secrets/wabisabi-secrets.sh}
                touch $out
              '';

          # wabisabi-usb on image FILES, which it supports for exactly this:
          # no root, no device. A fake ISO (random bytes behind an MBR, like
          # an isohybrid image) is written, a kit added, read back, replaced
          # and erased. The real ISO booting from a real stick layout, with a
          # kit the installer opens, is scripts/test-install-vm.sh --restore-kit.
          usb-tool =
            pkgs.runCommand "wabisabi-usb-tool"
              {
                nativeBuildInputs = [
                  usbTool
                  pkgs.cryptsetup
                  pkgs.util-linux
                  pkgs.jq
                ];
              }
              ''
                set -euo pipefail
                export HOME=$TMPDIR
                cd $TMPDIR
                fail() { echo "FAIL: $*" >&2; exit 1; }

                head -c $((16 * 1024 * 1024)) /dev/urandom > fake.iso
                # An MBR partition reaching the end, as an isohybrid image's does.
                echo "start=2048, size=30720, type=ef" | sfdisk --quiet fake.iso
                truncate -s 200M stick.img
                cp ${testKitPassphrase} pass
                printf wrong > wrong

                # Too small a stick is refused before anything is written.
                truncate -s 40M small.img
                if wabisabi-usb write small.img --iso fake.iso --yes; then fail "a too-small stick was accepted"; fi

                # write --kit checks the kit's inputs BEFORE writing anything:
                # a missing age key leaves the stick as it was.
                truncate -s 200M untouched.img
                if wabisabi-usb write untouched.img --iso fake.iso --kit --source x --host h \
                     --age-key $TMPDIR/no-such-key --ssh-key none --passphrase-file pass --yes; then
                  fail "write --kit accepted a missing age key"
                fi
                cmp -s -n $((16 * 1024 * 1024)) untouched.img /dev/zero || fail "write --kit wrote before checking the kit's inputs"

                # A kit needs an installer image first.
                if wabisabi-usb kit stick.img --source x --host h --age-key ${./installer/test-age-key.txt} \
                     --ssh-key none --passphrase-file pass --yes; then fail "kit without an installer image"; fi

                wabisabi-usb write stick.img --iso fake.iso --yes > write.log; cat write.log
                grep -q WABISABI_USB_WRITTEN write.log || fail "no write sentinel"
                # THE PARTITION TABLE IS THE ISO'S, untouched: a ThinkPad refused
                # to boot a stick whose MBR had gained an entry.
                cmp -s -n $((16 * 1024 * 1024)) fake.iso stick.img || fail "the stick is not the ISO byte for byte"
                [ "$(sfdisk -J stick.img | jq '.partitiontable.partitions | length')" = 1 ] || fail "a partition was added"

                wabisabi-usb kit stick.img --source https://example.org/fleet.git --host laptop \
                  --repo-path /home/tester/src/fleet --age-key ${./installer/test-age-key.txt} \
                  --ssh-key none --passphrase-file pass --yes > kit.log; cat kit.log
                grep -q WABISABI_USB_KIT kit.log || fail "no kit sentinel"
                wabisabi-usb show stick.img > show.log; grep -q "A restore kit is on it" show.log || fail "show does not see the kit"

                cmp -s -n $((16 * 1024 * 1024)) fake.iso stick.img || fail "the kit touched the ISO"
                [ "$(sfdisk -J stick.img | jq '.partitiontable.partitions | length')" = 1 ] || fail "the kit added a partition"
                dd if=stick.img of=kit.img bs=1M skip=16 count=64 status=none
                [ "$(blkid -p -o value -s LABEL kit.img)" = WABISABI-DATA ] || fail "kit not at 16 MiB, or not labelled WABISABI-DATA"
                cryptsetup open --test-passphrase --disable-locks --key-file pass kit.img || fail "the passphrase does not open the kit"
                if cryptsetup open --test-passphrase --disable-locks --key-file wrong kit.img 2>/dev/null; then fail "a wrong passphrase opens the kit"; fi

                # Writing the stick again must not leave the old kit behind.
                wabisabi-usb write stick.img --iso fake.iso --yes >/dev/null
                wabisabi-usb show stick.img > show.log; grep -q "No restore kit" show.log || fail "a rewrite kept the old kit"

                wabisabi-usb kit stick.img --source x --host laptop --age-key ${./installer/test-age-key.txt} \
                  --ssh-key none --passphrase-file pass --yes >/dev/null
                wabisabi-usb wipe stick.img --yes > wipe.log; grep -q WABISABI_USB_WIPED wipe.log || fail "no wipe sentinel"
                wabisabi-usb show stick.img > show.log; grep -q "No restore kit" show.log || fail "the kit survived the wipe"
                dd if=stick.img of=kit.img bs=1M skip=16 count=64 status=none
                [ -z "$(blkid -p -o value -s TYPE kit.img || true)" ] || fail "something is still recognisable after the wipe"

                touch $out
              '';

          emit-roundtrip = lib.throwIf (failures != [ ]) ''
            wabisabi: the installer emitted a config that does not do what was answered:
              ${report}
          '' pkgs.runCommand "wabisabi-emit-roundtrip" { } ''
            # Referencing the toplevel's drvPath forces the whole generated
            # configuration to EVALUATE (so a broken option fails here) while
            # deliberately not building the desktop, which is what the VM
            # install test is for.
            echo ${builtins.hashString "sha256" emittedSystem.config.system.build.toplevel.drvPath} > $out
            echo ${builtins.hashString "sha256" emittedSecretsSystem.config.system.build.toplevel.drvPath} >> $out
            cp ${emitted}/configuration.nix $out-config 2>/dev/null || true
          '';

          # sops-nix's own validation of the secrets file the step wrote: it
          # must parse as sops, and hold every secret the config declares.
          # This is a BUILD, so it also proves sops-install-secrets builds
          # against our nixpkgs.
          emit-secrets = emittedSecretsSystem.config.system.build.sops-nix-users-manifest;

          # The offline ISO's claim, checked: every value of every enum
          # appears in some payload.
          payload-coverage = pkgs.writeText "wabisabi-payload-coverage.json" (
            builtins.toJSON {
              inherit (payloads) count coverage;
            }
          );
        }
        # The lock can only be pinned from a committed tree, so this check
        # exists when there is a revision to pin and not during local edits.
        // { target-lock = targetLock; };

      # The "installer experience" for people who would rather not use an ISO:
      # scaffolds the same flake the installer writes.
      #   nix flake new -t github:wighawag/wabisabi ~/systems/my-laptop
      templates.default = {
        path = ./template;
        description = "A new machine on wabisabi: fill in your username, drop in hardware-configuration.nix, rebuild.";
      };
    };
}
