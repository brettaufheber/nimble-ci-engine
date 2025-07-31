# SPDX-FileCopyrightText: 2025 Eric Löffler <eric.loeffler@opalia.systems>
# SPDX-License-Identifier: GPL-3.0-or-later

{
  subject: {
    kind: "job",
    name: $job_name,
  },
  self: (
    [
      $state.pipelines[]
      | select(.name == $pipeline_name)
      | .latest_execution.jobs[]
      | select(.name == $job_name)
    ]
    | first
  ),
  backoff: (
    [
      $config.pipelines[]
      | select(.name == $pipeline_name)
      | .jobs[]
      | select(.name == $job_name)
      | .retry_policy.backoff
    ]
    | first
  )
}
