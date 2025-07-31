# SPDX-FileCopyrightText: 2025 Eric Löffler <eric.loeffler@opalia.systems>
# SPDX-License-Identifier: GPL-3.0-or-later

{
  subject: {
    kind: "pipeline",
    name: $pipeline_name,
    needs: (
      [
        $config.pipelines[]
        | select(.name == $pipeline_name)
        | .needs // []
      ]
      | first
    )
  },
  self: (
    [
      $state.pipelines[]
      | select(.name == $pipeline_name)
    ]
    | first
  ),
  other: (
    reduce (
      $state.pipelines[]
      | select(.name != $pipeline_name)
    ) as $pipeline
    ({}; .[$pipeline.name] = $pipeline)
  )
}
