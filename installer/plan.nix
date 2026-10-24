# The installer's question plan: what gets asked, in what order, under which
# heading, and -- for anything NOT asked -- why not.
#
# This file is the only hand-maintained half of the installer's questions. The
# other half (prompt text, type, allowed values, default) is read out of the
# option declarations themselves by ./questions.nix, so an option and its
# question cannot describe different things.
#
# THE COVERAGE RULE. Every leaf option in modules/options.nix and
# home/options.nix must appear exactly once, either in a group below or in
# `skip` with a reason. questions.nix throws otherwise, and that throw is a
# flake check, so adding an option to the API without deciding its installer
# story fails the build rather than silently producing an installer that
# cannot reach half the system.
#
# Keys are layer-qualified: "system:greetd.greeter", "home:terminal". Items
# with a `kind` are the installer's own questions (identity, disks), which are
# not wabisabi options and therefore have nothing to read a declaration from.

{
  groups = [
    {
      title = "Install or restore";
      essential = true;
      items = [
        {
          key = "install:mode";
          kind = "enum";
          prompt = "What to install";
          default = "fresh";
          values = [ "fresh" "restore" ];
          help = "fresh: a new machine, from the questions that follow. restore: this machine (or a wiped one) from a config repo you already have, the ~/nixos a previous install made: the same system, the same password, only the disks are new. Restore asks for the repo and your age key instead of the questions, because the answers are in the repo.";
        }
        {
          key = "restore:source";
          kind = "text";
          prompt = "Your config repo";
          default = "";
          help = "Anything `git clone` takes: https://github.com/you/nixos, a path on a USB stick you mounted (mount /dev/sdX1 /media), or a git bundle file. A private repo over https needs its token in the URL.";
          onlyIf = { key = "install:mode"; equals = "restore"; };
        }
        {
          key = "restore:host";
          kind = "text";
          prompt = "Which machine in it";
          default = "";
          help = "The nixosConfigurations name. Leave empty when the repo has only one, which is the case for a repo the installer made.";
          onlyIf = { key = "install:mode"; equals = "restore"; };
        }
        {
          key = "restore:sshKeyFile";
          kind = "text";
          prompt = "An SSH key for fetching it (optional)";
          default = "";
          help = "Path to a private SSH key file, e.g. on the USB stick, for a repo or flake inputs fetched over ssh (git@github.com:..., git+ssh://). It is used only by this installer, from RAM, and not copied to the new disk. Leave empty for a public repo or a local path.";
          onlyIf = { key = "install:mode"; equals = "restore"; };
        }
        {
          key = "restore:ageKey";
          kind = "agekey";
          optional = true;
          prompt = "Your age secret key";
          help = "The key you saved when the config was set up (AGE-SECRET-KEY-1...), or, for a fleet repo, the admin key its secrets are encrypted to. It is checked against the repo's secrets before any disk is touched. Leave empty only if the repo has no secrets.";
          onlyIf = { key = "install:mode"; equals = "restore"; };
        }
        {
          key = "restore:repoPath";
          kind = "text";
          prompt = "Where to put the repo on the new disk";
          default = "";
          help = "An absolute path, e.g. /home/you/src/my-boxes. Empty: where the config says it lives (the /etc/nixos link a wabisabi config declares), else ~/nixos of the machine's owner.";
          onlyIf = { key = "install:mode"; equals = "restore"; };
        }
      ];
    }

    {
      title = "Machine identity";
      # Essential groups are always asked. The rest are wabisabi's own
      # opinions, which the installer offers to skip in one go: see install.sh.
      essential = true;
      # A restore takes identity, secrets and options from the repo: asking
      # them again could only disagree with it. (Every non-essential group is
      # skipped on restore too; see install.sh.)
      skipWhen = { key = "install:mode"; equals = "restore"; };
      items = [
        {
          key = "identity:hostname";
          kind = "text";
          prompt = "Hostname";
          default = "wabisabi";
          help = "The machine's name on the network, and the name of its nixosConfiguration in the flake this installer writes.";
          validate = "hostname";
        }
        {
          key = "identity:username";
          kind = "text";
          prompt = "Username";
          default = "";
          help = "Your login account. It goes in the wheel group, so it can sudo, and in networkmanager and video.";
          validate = "username";
        }
        {
          key = "identity:password";
          kind = "password";
          prompt = "Password for that account";
          help = "Never written into the flake in the clear. With secrets set up (asked after the disk) its hash goes in encrypted, so a reinstall from your config keeps it; without, it is set on this machine only, with chpasswd.";
        }
        { option = "system:timeZone"; }
        { option = "system:locale"; }
        { option = "system:keyboard.layout"; }
        { option = "system:keyboard.variant"; }
        { option = "system:keyboard.options"; }
      ];
    }

    {
      title = "Disk";
      essential = true;
      # A restored config that declares its own disks (disko) is partitioned
      # by that declaration, so there is nothing to choose here. Set by
      # install.sh, never answered.
      skipWhen = { key = "restore:disko"; equals = "true"; };
      items = [
        {
          key = "disk:device";
          kind = "device";
          prompt = "Install to which disk";
          help = "EVERYTHING ON THE CHOSEN DISK IS DESTROYED. The installer lists what it found and asks you to type the device name back before it touches anything.";
        }
        {
          key = "disk:layout";
          kind = "enum";
          prompt = "Disk layout";
          default = "plain";
          values = [ "plain" "luks" "manual" ];
          help = "plain: GPT, a 512M EFI partition, ext4 root. luks: the same with the root inside LUKS2, unlocked by passphrase at boot. manual: you already partitioned and mounted the target at /mnt yourself, and the installer will not touch any disk. No swap partition is made in either automatic layout, because zram is on by default; hibernation needs one and is therefore a manual-layout job.";
        }
        {
          key = "disk:passphrase";
          kind = "password";
          prompt = "LUKS passphrase";
          help = "Asked twice. Type it on the keyboard layout you chose above: that layout is carried into the initrd, which is the keyboard this passphrase will be typed on at every boot.";
          onlyIf = { key = "disk:layout"; equals = "luks"; };
        }
      ];
    }

    {
      title = "Secrets";
      essential = true;
      skipWhen = { key = "install:mode"; equals = "restore"; };
      items = [
        {
          key = "secrets:mode";
          kind = "enum";
          prompt = "Encrypted secrets for your config (recommended)";
          default = "generate";
          values = [ "generate" "import" "skip" ];
          help = "Your config is a git repo at ~/nixos that can rebuild this machine, and can be pushed anywhere. Secrets in it (your password's hash first) are encrypted with sops to an age key that stays OFF the repo. generate: make a new key now; you will be shown it and asked to save a copy, because with the repo and that key a wiped machine comes back as it was. import: paste the key of a config you already have. skip: set it up later with `wabisabi-secrets init`; the password is then set the classic way and lives only on this machine.";
        }
        {
          key = "secrets:ageKey";
          kind = "agekey";
          prompt = "Your age secret key";
          help = "The line starting AGE-SECRET-KEY-1 that you saved when this config was first set up. It is not echoed and is never written to the repo.";
          onlyIf = { key = "secrets:mode"; equals = "import"; };
        }
      ];
    }

    {
      title = "The libre rule";
      items = [
        { option = "system:enforceLibre"; }
        {
          key = "extra:firmware";
          kind = "bool";
          prompt = "Install redistributable firmware blobs";
          default = "true";
          help = "Vendor firmware for wifi, bluetooth and some GPUs. It is binary-only, so it sits at the edge of the libre rule, but it does NOT trip the enforceLibre assertion: nixpkgs marks these licences free = true. Without it a great many laptops have no wifi at all. Says yes by default because the alternative is a machine that cannot reach the network it was just installed from.";
          emit = { attr = "hardware.enableRedistributableFirmware"; block = "system"; };
        }
      ];
    }

    {
      title = "Login and boot";
      items = [
        { option = "system:greetd.enable"; }
        { option = "system:greetd.greeter"; }
        { option = "system:splash.enable"; }
        { option = "system:splash.hideBootMenu"; }
        {
          key = "extra:initrdKernelModules";
          kind = "strlist";
          prompt = "Early KMS driver for the boot splash";
          default = "";
          help = "The GPU driver loaded in the initrd, so Plymouth owns the screen from the start instead of falling back to printing the boot log. The installer fills in what it detects on this machine (amdgpu, i915, nouveau, virtio_gpu). This is hardware knowledge, which is why it lands in your config rather than in wabisabi's modules. Leave it empty if you do not want early KMS.";
          emit = { attr = "boot.initrd.kernelModules"; block = "system"; };
        }
      ];
    }

    {
      title = "Hardware services";
      items = [
        { option = "system:zram.enable"; }
        { option = "system:bluetooth.enable"; }
        { option = "system:cellular.enable"; }
        { option = "system:printing.enable"; }
      ];
    }

    {
      title = "Network services";
      items = [
        { option = "system:tor.enable"; }
        { option = "system:mdns.enable"; }
      ];
    }

    {
      title = "AI and privacy";
      items = [
        { option = "system:llm.enable"; }
        { option = "system:agents.enable"; }
        { option = "system:search.enable"; }
        # The backend, then the recipe set it is for, then that set's chain:
        # each asked only when the answer before makes it mean something.
        # `onlyIf` takes one condition or a list (all must hold), each with
        # `equals` or `notEquals`; an unasked question's answer is "", so
        # the engines question also stays away when the backend is searxng.
        { option = "system:search.backend"; }
        {
          # A nullOr-submodule option is asked field by field, in this order;
          # every field after the first is asked only when the first was
          # answered. Leaving the URL empty leaves the option null.
          option = "system:search.recipes";
          fields = [
            "url"
            "sha256"
          ];
          onlyIf = {
            key = "system:search.backend";
            notEquals = "searxng";
          };
        }
        {
          option = "system:search.engines";
          # Required once a set is given: the config refuses a set without a
          # chain, so an empty answer here would be an install that fails.
          required = true;
          onlyIf = {
            key = "system:search.recipes.url";
            notEquals = "";
          };
        }
        { option = "system:search.viaTor"; }
        {
          # Only with the local model: without it the accounts have no model
          # to run on, and the option's default follows llm.enable, so an
          # unasked question leaves them off.
          option = "system:anon.enable";
          onlyIf = {
            key = "system:llm.enable";
            equals = "true";
          };
        }
        {
          option = "system:anon.autoEnroll";
          onlyIf = [
            {
              key = "system:llm.enable";
              equals = "true";
            }
            {
              key = "system:anon.enable";
              equals = "true";
            }
          ];
        }
      ];
    }

    {
      title = "Desktop";
      items = [
        { option = "system:theme"; }
        { option = "home:shell"; }
        { option = "system:bash.enable"; }
        { option = "system:zellij.enable"; }
        { option = "system:nixLd.enable"; }
        { option = "home:modKey"; }
        { option = "home:animations"; }
      ];
    }

    {
      title = "Programs";
      items = [
        { option = "home:terminal"; }
        { option = "home:editor"; }
        { option = "home:browser"; }
        { option = "home:fileManager"; }
      ];
    }

    {
      title = "Extra apps";
      items = [
        { option = "home:apps.media"; }
        { option = "home:apps.office"; }
        { option = "home:apps.email"; }
        { option = "home:apps.passwords"; }
        { option = "home:apps.syncthing"; }
      ];
    }
  ];

  skip = {
    "system:enable" = "The installer is installing wabisabi; asking whether to enable it is not a question.";
    "home:enable" = "Same: the home layer is the point of installing, and the generated configuration.nix shows the line so it can be removed by hand later.";
    "system:user" = "Not a question: it is the account created under Machine identity, substituted into the template (CHANGEME_USERNAME), so it can never name a different user than the one being created.";
    "system:secrets.sopsFile" = "Not a question: it is set by the secrets step (`wabisabi-secrets init`), which the installer runs after its own Secrets question, because the file has to exist and be encrypted before the line can point at it.";
    "system:secrets.ageKeyFile" = "Where the key lives is plumbing, not a preference; the default is where sops-nix documents it and where `wabisabi-secrets` puts it.";
    "system:secrets.ownerPassword" = "Follows from answering the Secrets question at all: an owner who sets secrets up gets a reinstallable password, and one who does not never reaches this option.";
    "system:restore.files" = "Not a question: it is read BY the restore mode, out of a config that already exists, and a fresh install has nothing encrypted to place.";
    "system:agents.guide" = "Follows from the agent being enabled: without it the local model refuses to look at the machine it runs on. It is a seeded file the owner can edit or delete, not a preference to decide before seeing it.";
    "system:agents.extraGuide" = "Free text for a particular machine's agent; nothing an installer can usefully ask for.";
    "system:search.recipeSet" = "A path or flake input, which only exists in a config that someone is editing; the installer asks for the URL form instead (search.recipes).";
    "system:agents.searchFolder" = "A path, and the default (~/searches) is fine for everyone; it only names where search-bar sessions live.";
    "system:wallpaper" = "A path to an image, which a terminal installer cannot usefully show you; the default is the enso the whole theme was drawn from, and Noctalia's settings pick another one on the running desktop.";
    "home:theme" = "Follows system:theme, which is asked under Desktop: one machine, one palette, unless a home deliberately sets its own in configuration.nix.";
    "home:wallpaper" = "Follows system:wallpaper, for the same reason.";
    "system:anon.accounts" = "A pool of account names with pinned uids is structure, not an answer; the defaults (anon, anon-john, anon-jane) are what every machine should start with, and changing the pool is a deliberate edit to configuration.nix.";
  };
}
