# The installer's question list, GENERATED FROM THE OPTION DECLARATIONS.
#
# For every wabisabi option the plan says to ask about, the prompt, the type,
# the allowed values and the default are read out of modules/options.nix and
# home/options.nix rather than restated here. Adding an enum value, changing a
# default or rewording a description therefore changes the installer, with no
# second place to edit and nothing to keep in sync.
#
# It also enforces the coverage rule from ./plan.nix: every declared option is
# either asked or skipped-with-a-reason, and anything else is a build error.
#
# Output is plain data (a list of groups of items), serialised to JSON for the
# installer script, so the TUI is a renderer with no knowledge of wabisabi.

{ lib }:

let
  plan = import ./plan.nix;

  optionsOf = path: (lib.evalModules { modules = [ path ]; }).options.wabisabi;

  layers = {
    system = optionsOf ../modules/options.nix;
    home = optionsOf ../home/options.nix;
  };

  # Walk an option tree down to its leaves, returning { "greetd.greeter" = opt; }.
  leaves =
    prefix: attrs:
    lib.concatMapAttrs (
      name: value:
      let
        path = if prefix == "" then name else "${prefix}.${name}";
      in
      if lib.isOption value then
        { ${path} = value; }
      else if lib.isAttrs value && !lib.isDerivation value then
        leaves path value
      else
        { }
    ) (lib.filterAttrs (name: _: !lib.hasPrefix "_" name) attrs);

  declared = lib.concatMapAttrs (
    layer: opts: lib.mapAttrs' (path: opt: lib.nameValuePair "${layer}:${path}" opt) (leaves "" opts)
  ) layers;

  # Descriptions are written for `nixos-option` and run to several paragraphs.
  # The TUI shows the first one; the rest stays in the JSON for --help-full.
  firstParagraph =
    text:
    let
      head = lib.head (lib.splitString "\n\n" (lib.removePrefix "\n" text));
    in
    lib.concatStringsSep " " (lib.filter (s: s != "") (map lib.trim (lib.splitString "\n" head)));

  renderDefault =
    opt:
    let
      d = opt.default or null;
    in
    if lib.isBool d then
      lib.boolToString d
    else if lib.isString d then
      d
    else
      "";

  kindOf =
    opt:
    let
      n = opt.type.name;
    in
    if n == "bool" then
      "bool"
    else if n == "enum" then
      "enum"
    else if n == "str" || n == "string" then
      "text"
    else
      throw "wabisabi installer: option type '${n}' has no question kind. Teach installer/questions.nix how to ask it.";

  # An item is either a reference to a declared option, or one of the
  # installer's own questions (identity, disks), which have no declaration.
  resolve =
    item:
    if item ? option then
      let
        key = item.option;
        opt =
          declared.${key}
            or (throw "wabisabi installer: plan.nix asks about '${key}', which is not a declared option.");
        path = lib.elemAt (lib.splitString ":" key) 1;
        layer = lib.head (lib.splitString ":" key);
      in
      {
        inherit key;
        kind = kindOf opt;
        prompt = "wabisabi.${path}";
        help = firstParagraph (opt.description or "");
        helpFull = opt.description or "";
        default = renderDefault opt;
        values = opt.type.functor.payload.values or [ ];
        emit = {
          attr = "wabisabi.${path}";
          block = layer;
        };
      }
    else
      {
        values = [ ];
        default = "";
        helpFull = item.help or "";
        emit = null;
      }
      // item;

  groups = map (g: g // { items = map resolve g.items; }) plan.groups;

  asked = lib.concatMap (g: map (i: i.key) g.items) groups;
  askedOptions = lib.filter (k: declared ? ${k}) asked;
  classified = askedOptions ++ lib.attrNames plan.skip;

  unclassified = lib.subtractLists classified (lib.attrNames declared);
  phantom = lib.subtractLists (lib.attrNames declared) (lib.attrNames plan.skip);
  duplicated = lib.subtractLists (lib.unique askedOptions) askedOptions;
in

# The coverage rule, as throws rather than asserts: an `assert` reports only
# the failing expression, and a rule whose whole value is telling you what to
# do about it should say so.
lib.throwIf (unclassified != [ ]) ''
  wabisabi installer: these options are declared but the installer neither asks about them nor skips them:
    ${lib.concatStringsSep "\n    " unclassified}
  Add each to a group in installer/plan.nix, or to `skip` with the reason it is not worth asking.
''

  lib.throwIf
  (phantom != [ ])
  ''
    wabisabi installer: installer/plan.nix skips options that do not exist:
      ${lib.concatStringsSep "\n    " phantom}
  ''

  lib.throwIf
  (duplicated != [ ])
  ''
    wabisabi installer: these options are asked about more than once:
      ${lib.concatStringsSep "\n    " (lib.unique duplicated)}
  ''

  {
    inherit groups;
    optionCount = lib.length (lib.attrNames declared);
    askedCount = lib.length askedOptions;
  }
