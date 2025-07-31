# SPDX-FileCopyrightText: 2025 Eric Löffler <eric.loeffler@opalia.systems>
# SPDX-License-Identifier: GPL-3.0-or-later

($state.pipelines[] | select(.name == $pipeline_name) | .latest_execution.jobs) as $jobs
| map(select(
    ((.needs // []) | length) == 0 or ((.needs // []) | all(
      . as $dependency_name
      | $jobs[]
      | select(.name == $dependency_name)
      | .latest_attempt.status != "pending" and .latest_attempt.status != "started"
    ))
  ))
