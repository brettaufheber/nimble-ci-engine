# SPDX-FileCopyrightText: 2025 Eric Löffler
# SPDX-License-Identifier: GPL-3.0-or-later

# ARGS  : (none)
# IN    : (unused)
# OUT   : self
# NOTE  : Gets the unwrapped properties of the current pipeline or job
def self: (
  $ctx.self | .latest_execution // .latest_attempt
);

# ARGS  : $name: string
# IN    : (unused)
# OUT   : need|null
# NOTE  : Fetch a need object by name or null if not found
def need($name): (
  $ctx.other[$name] | .latest_execution // .latest_attempt
);

# ARGS  : (none)
# IN    : (unused)
# OUT   : [need]
# NOTE  : Resolves the subject's need names against the context lookup and returns the list of need objects.
def needs: (
  [
    $ctx.subject.needs[] as $name
    | need($name)
  ]
);

# ARGS  : pred: filter (need -> boolean)
# IN    : (unused)
# OUT   : integer
# NOTE  : Count how many needs satisfy the predicate.
def needs_count(pred): (
  [ needs[] | select(pred) ] | length
);

# ARGS  : (none)
# IN    : (unused)
# OUT   : integer
# NOTE  : Gets the total number of needs.
def needs_total: (
  needs | length
);

# ARGS  : pred: filter (need -> boolean)
# IN    : (unused)
# OUT   : number
# NOTE  : Ratio of needs that satisfy the predicate over total needs.
def needs_ratio(pred): (
  if needs_total == 0 then
    1
  else
    needs_count(pred) / needs_total
  end
);

# ARGS  : pred: filter (need -> boolean)
# IN    : (unused)
# OUT   : boolean
# NOTE  : Returns true if pred holds for every need (true for an empty need list).
def needs_all(pred): (
  [ needs[] | pred ] | all
);

# ARGS  : pred: filter (need -> boolean)
# IN    : (unused)
# OUT   : boolean
# NOTE  : Returns true if pred holds for at least one need (false for an empty need list).
def needs_any(pred): (
  [ needs[] | pred ] | any
);

# ARGS  : (none)
# IN    : (unused)
# OUT   : true
# NOTE  : Convenience constant that always yields true.
def always: true;

# ARGS  : (none)
# IN    : (unused)
# OUT   : false
# NOTE  : Convenience constant that always yields false.
def never: false;

# ARGS  : (none)
# IN    : (unused)
# OUT   : filter (need -> boolean)
# NOTE  : Convenience predicate that is true if every need has status "success".
def ok: (.status == "success");

# ARGS  : (none)
# IN    : (unused)
# OUT   : filter (need -> boolean)
# NOTE  : Convenience predicate that is true if the need has status "failure" or "timeout".
def fail: (.status == "failure" or .status == "timeout");

# ARGS  : (none)
# IN    : (unused)
# OUT   : filter (need -> boolean)
# NOTE  : Convenience predicate that is true if the need has status "success" or "skipped".
def done: (.status == "success" or .status == "skipped");

# ARGS  : (none)
# IN    : (unused)
# OUT   : filter (need -> boolean)
# NOTE  : Convenience predicate that is true if the need has not status "skipped".
def active: (.status != "skipped");
