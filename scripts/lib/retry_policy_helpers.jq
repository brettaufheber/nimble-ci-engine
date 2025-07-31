# SPDX-FileCopyrightText: 2025 Eric Löffler
# SPDX-License-Identifier: GPL-3.0-or-later

# ARGS  : (none)
# IN    : (unused)
# OUT   : number
# NOTE  : Returns the number of attempts including latest_attempt.
def attempts: (
($ctx.self.previous_attempts | length) + 1
);

# ARGS  : (none)
# IN    : (unused)
# OUT   : number
# NOTE  : Returns the number of retries (attempts-1).
def retries: (
  $ctx.self.previous_attempts | length
);

# ARGS  : $count: integer (>= 1)
# IN    : (unused)
# OUT   : boolean
# NOTE  : Returns true if another attempt is still allowed under a total attempt budget of $count.
def max_attempts($count): (
  attempts < $count
);

# ARGS  : pred: filter (attempt -> boolean)
# IN    : (unused)
# OUT   : boolean
# NOTE  : Applies the predicate to the most recent attempt (the last element
#         in previous_attempts). If there is no history, returns false.
def retry_on(pred): (
  $ctx.self.latest_attempt | pred
);

# ARGS  : (none)
# IN    : (unused)
# OUT   : filter (attempt -> boolean)
# NOTE  : Convenience predicate that is true if the previous attempt has status "success".
def success: (.status == "success");

# ARGS  : (none)
# IN    : (unused)
# OUT   : filter (attempt -> boolean)
# NOTE  : Convenience predicate that is true if the previous attempt has status "failure".
def failure: (.status == "failure");

# ARGS  : (none)
# IN    : (unused)
# OUT   : filter (attempt -> boolean)
# NOTE  : Convenience predicate that is true if the previous attempt has status "timeout".
def timeout: (.status == "timeout");
