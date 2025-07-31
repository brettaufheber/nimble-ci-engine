# SPDX-FileCopyrightText: 2025 Eric Löffler <eric.loeffler@opalia.systems>
# SPDX-License-Identifier: GPL-3.0-or-later

# Allgemeine Funktion: erwartet als Parameter ein Graph-Array: [{name: "...", needs: ["..."]}, ...]
# Liefert: array von Zyklen — jeder Zyklus ist ein Array von Knotennamen (kanonisiert, kein doppeltes End-Element).
def cycles_from_graph($graph): (
  ($graph | map(.name)) as $nodes
  |
  def dfs($node; $visited; $stack):
    if ($stack | index($node)) then
      [ ($stack[$stack | index($node):] + [$node]) ]
    elif ($visited | index($node)) then
      []
    else
      ($visited + [$node]) as $v
      | ($stack + [$node]) as $s
      | ($graph[] | select(.name == $node) | .needs // [])
      | (. | map(dfs(.; $v; $s)) | add // [])
    end
  ;
  def normalize_cycle($c):
    ($c | .[0:(length-1)]) as $path
    | ($path | length) as $n
    | [ range(0; $n) as $i
        | [ (range($i; $n), range(0; $i))
            | . as $idx
            | $path[$idx]
          ]
      ]
    | min_by(join("|"))
  ;
  ($nodes | map(dfs(.; []; [])) | add // [])
  | map(select(length > 0))
  | map(normalize_cycle(.))
  | unique_by(. | map(. | @base64) | join("|"))
);

# Any duplicate pipeline‐name?
def duplicate_pipeline_errors: (
  $config.pipelines
  | map(.name)
  | group_by(.)
  | map(select(length > 1)[0])
  | map({ kind: "duplicate_pipeline", pipeline: . })
);

# Any duplicate job‐name within the same pipeline?
def duplicate_job_errors: (
  $config.pipelines
  | reduce .[] as $p ([]; . + ($p.jobs | map({ pipeline: $p.name, job: .name })))
  | group_by(.pipeline, .job)
  | map(select(length > 1)[0])
  | map({ kind: "duplicate_job", pipeline: .pipeline, job: .job })
);

# Any pipeline‐level missing `needs` targets?
def missing_pipeline_errors: (
  ($config.pipelines | map(.name)) as $pipelines_names
  | [
      $config.pipelines[]
      | .name as $pipeline_name
      | (.needs // [])[]
      | . as $need
      | select($pipelines_names | index($need) | not)
      | { kind: "missing_pipeline", pipeline: $pipeline_name, missing: . }
    ]
);

# Any job‐level missing `needs` targets?
def missing_job_errors: (
  [
    $config.pipelines[]
    | .name as $pipeline_name
    | (.jobs | map(.name)) as $job_names
    | .jobs[]
    | .name as $job_name
    | (.needs // [])[]
    | . as $need
    | select($job_names | index($need) | not)
    | { kind: "missing_job", pipeline: $pipeline_name, job: $job_name, missing: . }
  ]
);

# Any cyclic pipeline dependencies?
def cycle_pipeline_errors: (
  [ $config.pipelines[] | { name: .name, needs: (.needs // []) } ] as $graph
  | cycles_from_graph($graph) as $cycles
  | ($cycles | map({ kind: "pipeline_cycle", cycle: . }))
);

# Any cyclic job dependencies?
def cycle_job_errors: (
  $config.pipelines
  | map(
      . as $pipeline
      | [ $pipeline.jobs[] | { name: .name, needs: (.needs // []) } ] as $graph
      | cycles_from_graph($graph) as $cycles
      | ($cycles | map({ kind: "job_cycle", pipeline: $pipeline.name, cycle: . }))
    )
    | add // []
);

# collect all errors
def all_errors: (
  duplicate_pipeline_errors
  + duplicate_job_errors
  + missing_pipeline_errors
  + missing_job_errors
  + cycle_pipeline_errors
  + cycle_job_errors
);

def format_error: (
  if .kind == "duplicate_pipeline" then
    "Error: Duplicate pipeline name: \(.pipeline | @json)"
  elif .kind == "duplicate_job" then
    "Error: Pipeline \(.pipeline | @json): duplicate job name: \(.job | @json)"
  elif .kind == "missing_pipeline" then
    "Error: Pipeline \(.pipeline | @json): missing reference \(.missing | @json)"
  elif .kind == "missing_job" then
    "Error: Pipeline \(.pipeline | @json), Job \(.job | @json): missing reference \(.missing | @json)"
  elif .kind == "pipeline_cycle" then
    "Error: Pipeline cycle detected: \(.cycle | map(. | @json) | join(" → "))"
  elif .kind == "job_cycle" then
    "Error: Pipeline \(.pipeline | @json): job cycle detected: \(.cycle | map(. | @json) | join(" → "))"
  else
    "Error: Unknown error: " + ( . | @json )
  end
);

def fail_on_errors: (
  all_errors as $errors
  | if ($errors | length) > 0 then
      $errors | map(format_error) | join("\n") | error
    else
      true
    end
);
