# SPDX-FileCopyrightText: 2025 Eric Löffler <eric.loeffler@opalia.systems>
# SPDX-License-Identifier: GPL-3.0-or-later

to_entries
| map(
    . as $entry
    | select(
        if $use_regex_keys then
          $key | test($entry.key)
        else
          $entry.key == $key
        end
    )
  )
| map(.value)
| first
