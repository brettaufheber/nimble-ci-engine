# SPDX-FileCopyrightText: 2025 Eric Löffler <eric.loeffler@opalia.systems>
# SPDX-License-Identifier: GPL-3.0-or-later

def ltrim: sub("^\\s+"; "");

def rtrim: sub("\\s+$"; "");

def trim: ltrim | rtrim;

def default($key; $value): (
  if has($key) and .[$key] != null then
    .[$key]
  else
    $value
  end
);

def to_millis: (
  capture("^(?<date>\\d+-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2})(?:\\.(?<frac>\\d+))?Z$")
  | ((.date | strptime("%Y-%m-%dT%H:%M:%S") | mktime) * 1000 + ((.frac // "0") | "0." + . | tonumber) * 1000) | floor
);

def to_millis($t): ($t | to_millis);

def tobool: (
  if type == "boolean" then
    .
  elif type == "string" then
      ascii_downcase
      | if . == "true" or . == "on" or . == "yes" then
          true
        elif . == "false" or . == "off" or . == "no" then
          false
        else
          null
        end
  elif type == "integer" or type == "number" then
    . != 0
  else
    null
  end
);

def as_array: (
  if type == "array" then
    .
  else
    [ . ]
  end
);
