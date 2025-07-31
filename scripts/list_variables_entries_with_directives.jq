# SPDX-FileCopyrightText: 2025 Eric Löffler <eric.loeffler@opalia.systems>
# SPDX-License-Identifier: GPL-3.0-or-later

$config
| path(
    ..
    | select(type == "object" and has("variables"))
    | .variables
  ) as $base_path
  | getpath($base_path)
  | to_entries[]
  | if (.value | type == "object") and ((.value | has("src")) or (.value | has("tpl"))) then
      .value + { key: .key, path: ($base_path + [.key]) }
    else
      . + { path: ($base_path + [.key]) }
    end
