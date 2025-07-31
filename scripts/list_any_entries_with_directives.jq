# SPDX-FileCopyrightText: 2025 Eric Löffler <eric.loeffler@opalia.systems>
# SPDX-License-Identifier: GPL-3.0-or-later

$config
| path(
    ..
    | select(type == "object" and (has("src") or has("tpl")))
  ) as $path
  | getpath($path)
  | . + { $path }
