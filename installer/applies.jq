# Whether a question is asked, given the answers so far: its `onlyIf` (one
# condition, or a list that must all hold), each condition `equals` or
# `notEquals` an earlier answer, which is "" when that question was not asked.
#
# Input: one question item from questions.json. $answers: an object of the
# answers so far ("layer:path" keys, string values). Output: true or false.
#
# One file for the installer (install.sh's ask_item) and for the flake check
# that walks the question list with sample answers, so the check tests the
# rule the installer actually runs.

def answer($k): ($answers[$k] // "" | tostring);

[ (.onlyIf // [])
  | if type == "object" then [.] else . end
  | .[]
  | if has("notEquals") then answer(.key) != .notEquals else answer(.key) == .equals end
] | all
