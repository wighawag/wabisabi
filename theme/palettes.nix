# The desktop's palettes, as data. Every app that draws colour reads its
# colours from here through `wabisabi.theme`, so a palette is one attrset and
# not a hunt through a dozen config files.
#
# Hex without the leading '#', because the consumers disagree about it (niri
# and CSS want it, swaylock, foot and fuzzel refuse it).
#
# The roles, same keys in every palette:
#   base mantle crust            backgrounds, from the window to the deepest
#   surface0..2, overlay0        raised surfaces, borders, muted text
#   subtext text bright          text, from secondary to emphasised
#   focus                        the focused window's ring
#   highlight                    the ONE thing to look at: the current
#                                workspace, a launcher match, the clock
#   info                         links and borders that are not the focus
#   urgent warning success       states
#   ansi                         the 16 terminal colours, 0..15
{
  # Sumi (墨, ink): sampled from the default wallpaper, the enso risograph.
  # Indigo ink and warm paper, with pigment accents muted enough to sit on
  # paper rather than glow on a screen. The website uses the same values.
  sumi = {
    name = "sumi";
    base = "182329";
    mantle = "131c21";
    crust = "0e1519";
    surface0 = "1f2c33";
    surface1 = "2a3a44";
    surface2 = "38454d";
    overlay0 = "5a6163";
    subtext = "a59e92";
    text = "e4d0b5";
    bright = "f4e1c3";
    # The active window is outlined in the brush stroke's own colour.
    focus = "e4d0b5";
    highlight = "d9b76e"; # kihada, ochre
    info = "7fa3c0"; # hanada, faded indigo
    urgent = "d0694f"; # shu, vermilion: the seal colour, lifted for a dark ground
    warning = "e0955f"; # kaki, persimmon
    success = "9fb07e"; # moss
    ansi = [
      "2a3a44" "d0694f" "9fb07e" "d9b76e" "7fa3c0" "a894c4" "8fb8aa" "c8b9a4"
      "5a6163" "e07f66" "b3c393" "e8ca86" "97b8d3" "bba9d4" "a5cbbd" "f4e1c3"
    ];
  };

  # Catppuccin Mocha, the previous default, kept as a choice.
  # https://catppuccin.com/palette
  catppuccin-mocha = {
    name = "catppuccin-mocha";
    base = "1e1e2e";
    mantle = "181825";
    crust = "11111b";
    surface0 = "313244";
    surface1 = "45475a";
    surface2 = "585b70";
    overlay0 = "6c7086";
    subtext = "bac2de";
    text = "cdd6f4";
    bright = "f5e0dc";
    focus = "cba6f7"; # mauve
    highlight = "cba6f7";
    info = "89b4fa"; # blue
    urgent = "f38ba8"; # red
    warning = "fab387"; # peach
    success = "a6e3a1"; # green
    ansi = [
      "45475a" "f38ba8" "a6e3a1" "f9e2af" "89b4fa" "f5c2e7" "94e2d5" "bac2de"
      "585b70" "f38ba8" "a6e3a1" "f9e2af" "89b4fa" "f5c2e7" "94e2d5" "a6adc8"
    ];
  };
}
