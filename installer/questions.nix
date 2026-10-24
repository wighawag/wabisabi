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
      # The functor's name: a strMatching type's own name carries its pattern.
      n = opt.type.functor.name or opt.type.name;
    in
    if n == "bool" then
      "bool"
    else if n == "enum" then
      "enum"
    else if n == "str" || n == "string" || n == "strMatching" then
      "text"
    else if n == "listOf" && opt.type.nestedTypes.elemType.name == "str" then
      "strlist"
    else
      throw "wabisabi installer: option type '${n}' has no question kind. Teach installer/questions.nix how to ask it.";

  # A strMatching option's pattern, for the installer to check an answer
  # against before accepting it (Nix's builtins.match is a whole-string POSIX
  # ERE, which the installer anchors to mean the same).
  patternOf = opt: if (opt.type.functor.name or "") == "strMatching" then opt.type.functor.payload.pattern else null;

  # One question for one declared option (or one field of one).
  optionQuestion =
    {
      key,
      opt,
      path,
      layer,
      help,
      helpFull,
    }:
    {
      inherit key help helpFull;
      kind = kindOf opt;
      prompt = "wabisabi.${path}";
      default = renderDefault opt;
      values = opt.type.functor.payload.values or [ ];
      pattern = patternOf opt;
      emit = {
        attr = "wabisabi.${path}";
        block = layer;
      };
    };

  # The plan's condition(s) as a list, whichever form it was written in.
  conditions = c: if c == null then [ ] else if lib.isList c then c else [ c ];

  # An item is either a reference to a declared option, or one of the
  # installer's own questions (identity, disks), which have no declaration.
  # Each resolves to a LIST of questions: one, except for an option whose
  # value is a null-or-record (search.recipes), which is asked field by field
  # as the plan lists them, emitted as `wabisabi.<option>.<field>`. Its later
  # fields are asked only when the first was answered, so an empty first
  # answer leaves the option null.
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
        onlyIf = conditions (item.onlyIf or null);
        withCondition =
          extra: q:
          q
          // lib.optionalAttrs (onlyIf ++ extra != [ ]) { onlyIf = onlyIf ++ extra; }
          // lib.optionalAttrs (item.required or false) { required = true; };
      in
      if item ? fields then
        let
          sub = opt.type.nestedTypes.elemType.getSubOptions [ ];
          firstKey = "${key}.${lib.head item.fields}";
          fieldQuestion =
            i: field:
            let
              subOpt =
                sub.${field} or (throw "wabisabi installer: plan.nix asks for field '${field}' of '${key}', which has none.");
              first = i == 0;
            in
            withCondition (lib.optional (!first) {
              key = firstKey;
              notEquals = "";
            }) (optionQuestion {
              key = "${key}.${field}";
              opt = subOpt;
              path = "${path}.${field}";
              inherit layer;
              # The option's own first paragraph goes with its first field,
              # since that is where its warnings must be read.
              help =
                lib.optionalString first (firstParagraph (opt.description or "") + " ")
                + firstParagraph (subOpt.description or "");
              helpFull = lib.optionalString first ((opt.description or "") + "\n\n") + (subOpt.description or "");
            })
            # A later field is required once the first is given: half a record
            # is a config that does not evaluate.
            // lib.optionalAttrs (!first) { required = true; };
          missing = lib.subtractLists item.fields (
            lib.attrNames (lib.filterAttrs (n: _: !lib.hasPrefix "_" n) sub)
          );
        in
        lib.throwIf (missing != [ ])
          "wabisabi installer: plan.nix asks '${key}' field by field but leaves out: ${lib.concatStringsSep ", " missing}"
          (lib.imap0 fieldQuestion item.fields)
      else
        [
          (withCondition [ ] (optionQuestion {
            inherit
              key
              opt
              path
              layer
              ;
            help = firstParagraph (opt.description or "");
            helpFull = opt.description or "";
          }))
        ]
    else
      [
        (
          {
            values = [ ];
            default = "";
            helpFull = item.help or "";
            emit = null;
          }
          // item
        )
      ];

  groups = map (g: g // { items = lib.concatMap resolve g.items; }) plan.groups;

  # Coverage counts the plan's option references, so an option asked field by
  # field counts once, as itself.
  askedOptions = lib.concatMap (g: map (i: i.option) (lib.filter (i: i ? option) g.items)) plan.groups;
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
