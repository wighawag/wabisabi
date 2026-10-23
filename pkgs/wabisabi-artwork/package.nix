{ lib, stdenvNoCC }:

# wabisabi's artwork: the default wallpaper and the Plymouth theme. The
# images are generated and committed under artwork/ (see artwork/README.md);
# this only installs them where the consumers look.
#
#   share/backgrounds/wabisabi/enso.jpg        the default wallpaper
#   share/plymouth/themes/wabisabi/            the boot splash
stdenvNoCC.mkDerivation {
  pname = "wabisabi-artwork";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../../artwork;
    fileset = lib.fileset.unions [
      ../../artwork/wallpapers
      ../../artwork/plymouth
    ];
  };

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    install -Dm444 wallpapers/enso.jpg $out/share/backgrounds/wabisabi/enso.jpg
    install -Dm444 wallpapers/LICENSE $out/share/licenses/wabisabi-artwork/LICENSE

    theme=$out/share/plymouth/themes/wabisabi
    install -Dm444 -t $theme plymouth/*.png

    # two-step, the plugin behind plymouth's own "spinner" theme. It shows
    # progress-NNNN.png by boot progress, so the enso is painted as the machine
    # starts. ImageDir is a store path; NixOS's plymouth module rewrites it to
    # wherever it copies the theme (the initrd, /etc/plymouth/themes).
    # The Font must be the family of boot.plymouth.font, the only font in the
    # initrd (modules/boot.nix sets it to Inter). UseEndAnimation: the end
    # animation paints the dry tail that closes the circle, then holds, so the
    # greeter always replaces a finished enso (artwork/generate.mjs).
    cat > $theme/wabisabi.plymouth <<EOF
    [Plymouth Theme]
    Name=wabisabi
    Description=An enso, painted as the machine boots
    ModuleName=two-step

    [two-step]
    Font=Inter Variable 12
    TitleFont=Inter Variable 24
    ImageDir=$theme
    HorizontalAlignment=.5
    VerticalAlignment=.45
    WatermarkHorizontalAlignment=.5
    WatermarkVerticalAlignment=.66
    DialogHorizontalAlignment=.5
    DialogVerticalAlignment=.5
    TitleHorizontalAlignment=.5
    TitleVerticalAlignment=.382
    Transition=none
    TransitionDuration=0.0
    BackgroundStartColor=0x182329
    BackgroundEndColor=0x182329
    ProgressBarBackgroundColor=0x2a3a44
    ProgressBarForegroundColor=0xe4d0b5
    MessageBelowAnimation=true

    [boot-up]
    UseEndAnimation=true
    UseFirmwareBackground=false

    [shutdown]
    UseEndAnimation=false

    [reboot]
    UseEndAnimation=false

    [updates]
    SuppressMessages=true
    ProgressBarShowPercentComplete=true
    UseProgressBar=true
    Title=Installing updates
    SubTitle=Do not turn off your computer
    EOF

    runHook postInstall
  '';

  meta = {
    description = "wabisabi's wallpaper and boot splash";
    license = lib.licenses.cc0;
    platforms = lib.platforms.all;
  };
}
