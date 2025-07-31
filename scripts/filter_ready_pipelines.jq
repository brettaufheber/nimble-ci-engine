# SPDX-FileCopyrightText: 2025 Eric Löffler <eric.loeffler@opalia.systems>
# SPDX-License-Identifier: GPL-3.0-or-later

map(select(
  ((.needs // []) | length) == 0 or ((.needs // []) | all(
    . as $dependency_name
    | $state.pipelines[]
    | select(.name == $dependency_name)
    | .latest_execution.status != "pending" and .latest_execution.status != "started"
  ))
))
