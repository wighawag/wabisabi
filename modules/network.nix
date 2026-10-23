{ lib, config, ... }:

# Connectivity. Deliberately includes WWAN (LTE modems) and Bluetooth:
# both are harmless when the hardware is absent, which keeps this layer
# hardware-agnostic.

let cfg = config.wabisabi; in
lib.mkIf cfg.enable {
  networking.networkmanager.enable = lib.mkDefault true;
  networking.firewall.enable = lib.mkDefault true;

  hardware.bluetooth = lib.mkIf cfg.bluetooth.enable (lib.mkDefault {
    enable = true;
    powerOnBoot = true;
  });

  services.blueman.enable = lib.mkIf cfg.bluetooth.enable (lib.mkDefault true);

  networking.modemmanager.enable = lib.mkIf cfg.cellular.enable (lib.mkDefault true);

  # mDNS: announce <hostname>.local and resolve other machines' .local names.
  # Per leaf rather than one mkDefault attrset, so it merges with the printing
  # half in core.nix (which enables resolution for printer discovery) and with
  # a machine's own avahi settings instead of racing them.
  services.avahi = lib.mkIf cfg.mdns.enable {
    enable = lib.mkDefault true;
    nssmdns4 = lib.mkDefault true;
    openFirewall = lib.mkDefault true;
    publish = {
      enable = lib.mkDefault true;
      addresses = lib.mkDefault true;
    };
  };

  # A Tor CLIENT: SOCKS5 on loopback, nothing else. `client.enable` is the
  # part that actually opens the port -- a bare `services.tor.enable` runs a
  # daemon that proxies nothing.
  #
  # LOOPBACK IS NOT NEGOTIABLE and is why no address option is offered. A SOCKS
  # listener reachable off-box is an OPEN PROXY, and "anonymous egress for
  # anyone on the LAN" is not something to leave one setting away. nixpkgs'
  # default already binds 127.0.0.1 with IsolateDestAddr (per-destination
  # circuit isolation, so two sites cannot be correlated by sharing an exit),
  # which is the right behaviour, so this deliberately does NOT override
  # `settings.SOCKSPort`. Note that option is a LIST and therefore CONCATENATES
  # rather than replaces: defining it here would add a SECOND listener on the
  # same port, which cannot bind and fails the unit at startup.
  services.tor = lib.mkIf cfg.tor.enable (lib.mkDefault {
    enable = true;
    client.enable = true;
  });
}