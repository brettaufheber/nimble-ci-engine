# SPDX-FileCopyrightText: 2025 Eric Löffler
# SPDX-License-Identifier: GPL-3.0-or-later

# -----------------------------------------------------------------------------
# Data models (informal, for documentation)
#
# job:
# {
#   name: string,
#   needs: [string] | null,   # job-level dependencies within the same pipeline
#   ...
# }
#
# pipeline:
# {
#   name: string,
#   needs: [string] | null,   # pipeline-level dependencies (on other pipelines)
#   jobs: [job],
#   ...
# }
#
# ci_config:
# {
#   pipelines: [pipeline],
#   ...
# }
#
# status: "pending" | "started" | "skipped" | "success" | "failure" | "timeout"
#
# job_state:
# {
#   name: string,
#   latest_attempt: { status: status, timestamp: string, ... },
#   previous_attempts: [ { status: status, timestamp: string, ... }, ... ],
#   ...
# }
#
# pipeline_state:
# {
#   name: string,
#   latest_execution: { status: status, timestamp: string, jobs: [job_state], ... },
#   previous_executions: [ { status: status, timestamp: string, ... }, ... ],
#   ...
# }
#
# state:
# {
#   pipelines: [pipeline_state],
#   ...
# }
#
# node: { pipeline: string, job: string }
# edge: { from: node, to: node }
#
# adjacency (successor map):
# { "<pipeline>": { "<job>": [ node, ... ], ... }, ... }
#
# issue:
# {
#   kind: "pipeline" | "job",
#   pipeline: string,
#   job?: string,        # present for job-scoped issues
#   cause: string,       # machine-readable cause
#   expected?: any,      # optional expected value
#   actual?: any,        # optional actual value
#   by?: node            # optional offender (e.g., for needs-order violations)
# }
#
# pipeline_expectations:
# { "<pipeline>": status, ... }
#
# job_expectations:
# { "<pipeline>": { "<job>": status, ... }, ... }
#
# expectations:
# {
#   pipelines: pipeline_expectations,
#   jobs: job_expectations
# }
#
# -----------------------------------------------------------------------------

include "lib/common";

# ARGS  : $config: ci_config, $pipeline_name: string
# IN    : (unused)
# OUT   : pipeline | null  — the pipeline with .name == $pipeline_name, or null
# NOTE  : Helper: look up a pipeline by name.
def dag_find_pipeline($config; $pipeline_name): (
  [ $config.pipelines[] | select(.name == $pipeline_name) ] | first
);

# ARGS  : $pipeline: pipeline, $job_name: string
# IN    : (unused)
# OUT   : job | null  — the job with .name == $job_name, or null
# NOTE  : Helper: look up a job by name within a pipeline.
def dag_find_job($pipeline; $job_name): (
  [ $pipeline.jobs[] | select(.name == $job_name) ] | first
);

# ARGS  : $config: ci_config
# IN    : (unused)
# OUT   : [node]
# NOTE  : Produce a flat list of all (pipeline, job) nodes across the config.
def dag_node_list($config): (
  [
    $config.pipelines[] as $pipeline
    | $pipeline.jobs[] as $job
    | { pipeline: $pipeline.name, job: $job.name }
  ]
);

# ARGS  : $config: ci_config
# IN    : (unused)
# OUT   : [edge]
# NOTE  : Build directed edges from:
#         (1) job-level "needs" (job to its needed job within the same pipeline)
#         (2) pipeline-level "needs" expanded as a complete bipartite set:
#             every job in the needing pipeline to every job in the needed pipeline.
#         Duplicate edges are removed.
def dag_edge_list($config): (
  [
    # Intra-pipeline job to job edges from job-level needs
    $config.pipelines[] as $pipeline
    | $pipeline.jobs[] as $src_job
    | ($src_job.needs // [])[] as $dst_job_name
    | dag_find_job($pipeline; $dst_job_name) as $dst_job
    | select($dst_job != null)
    | {
        from: { pipeline: $pipeline.name, job: $src_job.name },
        to: { pipeline: $pipeline.name, job: $dst_job.name }
      }
  ] + [
    # Inter-pipeline edges expanded from pipeline-level needs
    $config.pipelines[] as $src_pipeline
    | ($src_pipeline.needs // [])[] as $dst_pipeline_name
    | dag_find_pipeline($config; $dst_pipeline_name) as $dst_pipeline
    | select($dst_pipeline != null)
    | $src_pipeline.jobs[] as $src_job
    | $dst_pipeline.jobs[] as $dst_job
    | {
        from: { pipeline: $src_pipeline.name, job: $src_job.name },
        to: { pipeline: $dst_pipeline.name, job: $dst_job.name }
      }
  ]
  | unique_by([ .from.pipeline, .from.job, .to.pipeline, .to.job ])
);

# ARGS  : $adjacency: adjacency, $src_node: node, $dst_node: node | null
# IN    : (unused)
# OUT   : adjacency
# NOTE  : Append $dst_node (if non-null) to the successor list of $src_node.
#         Missing map keys are created on demand.
def dag_adjacency_append($adjacency; $src_node; $dst_node): (
  (if $dst_node == null then [] else [$dst_node] end) as $neighbor
  | $adjacency
  | .[$src_node.pipeline] = (.[$src_node.pipeline] // {})
  | .[$src_node.pipeline][$src_node.job] = (.[$src_node.pipeline][$src_node.job] // []) + $neighbor
);

# ARGS  : $nodes: [node], $edges: [edge]
# IN    : (unused)
# OUT   : adjacency
# NOTE  : Build a successors adjacency map: pipeline → job → [direct successors].
#         Ensures all nodes exist in the map and de-duplicates neighbor lists.
def dag_adjacency_list($nodes; $edges): (
  reduce $edges[] as $edge ({}; dag_adjacency_append(.; $edge.from; $edge.to))
  | reduce $nodes[] as $node (.; dag_adjacency_append(.; $node; null))
  | map_values(map_values(unique_by([.pipeline, .job])))
);

# ARGS  : $nodes: [node], $edges: [edge]
# IN    : (unused)
# OUT   : adjacency
# NOTE  : Build a predecessors adjacency map by reversing all edges.
#         Ensures all nodes exist in the map and de-duplicates neighbor lists.
def dag_adjacency_reverse_list($nodes; $edges): (
  reduce $edges[] as $edge ({}; dag_adjacency_append(.; $edge.to; $edge.from))
  | reduce $nodes[] as $node (.; dag_adjacency_append(.; $node; null))
  | map_values(map_values(unique_by([.pipeline, .job])))
);

# ARGS  : $adjacency: adjacency, $start_node: node
# IN    : (unused)
# OUT   : [node]
# NOTE  : Depth-first search from $start_node over the given adjacency map.
#         Returns all reachable nodes, excluding the start node itself.
def dag_reach($adjacency; $start_node): (
  def dfs($node): (
    if .[$node.pipeline][$node.job] then
      .
    else
      . |= setpath([$node.pipeline, $node.job]; true)
      | reduce ($adjacency[$node.pipeline][$node.job])[] as $neighbor (. ; dfs($neighbor))
    end
  );
  ($adjacency | map_values(map_values(false)))
  | dfs($start_node)
  | [
      to_entries[]
      | .key as $pipeline_name
      | (.value | to_entries)[]
      | .key as $job_name
      | select(.value and (($pipeline_name == $start_node.pipeline and $job_name == $start_node.job) | not))
      | { pipeline: $pipeline_name, job: $job_name }
    ]
);

# ARGS  : $config: ci_config, $pipeline_name: string, $job_name: string
# IN    : (unused)
# OUT   : [node] — sorted
# NOTE  : Return the strict ancestors and descendants of the given node (i.e., all
#         nodes that must run before it or can run only after it). Sorted by pipeline/job.
def dag_non_parallel_nodes($config; $pipeline_name; $job_name): (
  dag_node_list($config) as $nodes
  | dag_edge_list($config) as $edges
  | dag_adjacency_list($nodes; $edges) as $forward_adj
  | dag_adjacency_reverse_list($nodes; $edges) as $backward_adj
  | { pipeline: $pipeline_name, job: $job_name } as $start
  | dag_reach($forward_adj; $start) + dag_reach($backward_adj; $start)
  | unique_by([ .pipeline, .job ])
  | sort_by(.pipeline, .job)
);

# ARGS  : $kind: "pipeline"|"job", $pipeline: string, $job: string|null, $cause: string, $expected: any, $actual: any
# IN    : (unused)
# OUT   : issue
# NOTE  : Construct a generic issue object. Fields with null values are omitted.
def issue_base($kind; $pipeline; $job; $cause; $expected; $actual):
  { kind: $kind, pipeline: $pipeline, cause: $cause }
  | (if $job == null then . else . + { job: $job } end)
  | (if $expected == null then . else . + { expected: $expected } end)
  | (if $actual   == null then . else . + { actual:   $actual   } end);

# ARGS  : $pipeline: string, $cause: string, $expected: any, $actual: any
# IN    : (unused)
# OUT   : issue
# NOTE  : Construct a pipeline-scoped issue.
def issue_pipeline($pipeline; $cause; $expected; $actual):
  issue_base("pipeline"; $pipeline; null; $cause; $expected; $actual);

# ARGS  : $pipeline: string, $job: string, $cause: string, $expected: any, $actual: any
# IN    : (unused)
# OUT   : issue
# NOTE  : Construct a job-scoped issue.
def issue_job($pipeline; $job; $cause; $expected; $actual):
  issue_base("job"; $pipeline; $job; $cause; $expected; $actual);

# ARGS  : $state: state, $pipeline_name: string
# IN    : (unused)
# OUT   : pipeline_state | null
# NOTE  : Helper: look up a pipeline within the state document.
def state_find_pipeline($state; $pipeline_name): (
  [
    $state.pipelines[]
    | select(.name == $pipeline_name)
  ]
  | first
);

# ARGS  : $state: state, $pipeline_name: string, $job_name: string
# IN    : (unused)
# OUT   : job_state | null
# NOTE  : Helper: look up a job within the state's latest_execution for a pipeline.
def state_find_job($state; $pipeline_name; $job_name): (
  [
    $state.pipelines[]
    | select(.name == $pipeline_name)
    | .latest_execution.jobs[]
    | select(.name == $job_name)
  ]
  | first
);

# ARGS  : $config: ci_config, $state: state, $pipeline_name: string, $job_name: string
# IN    : (unused)
# OUT   : [issue]  — cause "violated_needs_order"
# NOTE  : For the given job, emit one issue per *running* (status=="started")
#         non-parallel node that would block execution according to the DAG.
#         Returns an empty list if none.
def state_issues_needs_order($config; $state; $pipeline_name; $job_name): (
  dag_non_parallel_nodes($config; $pipeline_name; $job_name) as $nodes
  | [
      $nodes[] as $node
      | state_find_job($state; $node.pipeline; $node.job) as $job_state
      | select($job_state != null and $job_state.latest_attempt.status == "started")
      | issue_job($pipeline_name; $job_name; "violated_needs_order"; null; $job_state.latest_attempt.status) + { by: $node }
    ]
);

# ARGS  : $state: state, $limit: integer
# IN    : (unused)
# OUT   : [issue]
# NOTE  : If the number of running pipelines (latest_execution.status=="started")
#         exceeds $limit, emit an issue per running pipeline. A limit of 0 disables
#         the check. $actual contains the total running count.
def state_issues_pipeline_concurrency_limit($state; $limit): (
  [ $state.pipelines[] | select(.latest_execution.status == "started") ] as $running_pipelines
  | ($running_pipelines | length) as $running_pipeline_count
  | if ($limit != 0 and $running_pipeline_count > $limit) then
      [
        $running_pipelines[]
        | issue_pipeline(.name; "concurrent_limit_exceeded"; $limit; $running_pipeline_count)
      ]
    else
      []
    end
);

# ARGS  : $state: state, $limit: integer
# IN    : (unused)
# OUT   : [issue]
# NOTE  : For each pipeline, if the count of running jobs exceeds $limit,
#         emit an issue per running job. A limit of 0 disables the check.
#         $actual contains the running job count for that pipeline.
def state_issues_job_concurrency_limit($state; $limit): (
  [
    $state.pipelines[] as $pipeline
    | [ $pipeline.latest_execution.jobs[] | select(.latest_attempt.status == "started") ] as $running_jobs
    | ($running_jobs | length) as $running_job_count
    | if ($limit != 0 and $running_job_count > $limit) then
        [
          $running_jobs[]
          | issue_job($pipeline.name; .name; "concurrent_limit_exceeded"; $limit; $running_job_count)
        ]
      else
        []
      end
  ]
  | add
);

# ARGS  : $state: state, $max_concurrent_pipelines: integer, $max_concurrent_jobs_per_pipeline: integer
# IN    : (unused)
# OUT   : [issue]
# NOTE  : Aggregate concurrency issues for pipelines and jobs. A limit of 0 means
#         “no restriction” for the corresponding dimension.
def state_issues_concurrency_limits($state; $max_concurrent_pipelines; $max_concurrent_jobs_per_pipeline): (
  state_issues_pipeline_concurrency_limit($state; $max_concurrent_pipelines)
    + state_issues_job_concurrency_limit($state; $max_concurrent_jobs_per_pipeline)
);

# ARGS  : $state: state, $pipeline_name: string
# IN    : (unused)
# OUT   : [status] | null  — sorted previous_executions.status + [latest_execution.status]
# NOTE  : Returns the pipeline execution status history or null if the pipeline is missing.
def pipeline_execution_status_history($state; $pipeline_name): (
  state_find_pipeline($state; $pipeline_name) as $pipeline
  | if $pipeline == null then
      null
    else
      $pipeline.previous_executions
      | sort_by(.timestamp | to_millis)
      | map(.status)
      | . + [ $pipeline.latest_execution.status ]
    end
);

# ARGS  : $state: state, $pipeline_name: string, $job_name: string
# IN    : (unused)
# OUT   : [status] | null  — sorted previous_attempts.status + [latest_attempt.status]
# NOTE  : Returns the job attempt status history within the pipeline or null if missing.
def job_attempt_status_history($state; $pipeline_name; $job_name): (
  state_find_job($state; $pipeline_name; $job_name) as $job
  | if $job == null then
      null
    else
      $job.previous_attempts
      | sort_by(.timestamp | to_millis)
      | map(.status)
      | . + [ $job.latest_attempt.status ]
    end
);

# ARGS  : $state: state, $pipeline_name: string, $expected_status: [status]
# IN    : (unused)
# OUT   : [issue]
# NOTE  : Expect exact pipeline status history; emits "missing" or "mismatch".
def state_issue_expect_pipeline_status($state; $pipeline_name; $expected_status): (
  pipeline_execution_status_history($state; $pipeline_name) as $actual
  | ($expected_status | as_array) as $expected
  | if $actual == null then
      [ issue_pipeline($pipeline_name; "missing"; $expected; null) ]
    elif $actual != $expected then
      [ issue_pipeline($pipeline_name; "mismatch"; $expected; $actual) ]
    else
      []
    end
);

# ARGS  : $state: state, $pipeline_name: string, $job_name: string, $expected_status: [status]
# IN    : (unused)
# OUT   : [issue]
# NOTE  : Expect exact job attempt status history; emits "missing" or "mismatch".
def state_issue_expect_job_status($state; $pipeline_name; $job_name; $expected_status): (
  job_attempt_status_history($state; $pipeline_name; $job_name) as $actual
  | ($expected_status | as_array) as $expected
  | if $actual == null then
      [ issue_job($pipeline_name; $job_name; "missing"; $expected; null) ]
    elif $actual != $expected then
      [ issue_job($pipeline_name; $job_name; "mismatch"; $expected; $actual) ]
    else
      []
    end
);

# ARGS  : $state: state, $pipeline_expectations: pipeline_expectations
# IN    : (unused)
# OUT   : [issue]
# NOTE  : Validate pipeline expectations: emit issues for missing/mismatched pipelines.
def state_issues_expectations_pipelines($state; $pipeline_expectations): (
  reduce (($pipeline_expectations // {}) | to_entries[]) as $pe
    ([]; . + state_issue_expect_pipeline_status($state; $pe.key; $pe.value))
);

# ARGS  : $state: state, $job_expectations: job_expectations
# IN    : (unused)
# OUT   : [issue]
# NOTE  : Validate job expectations per pipeline: emit issues for missing/mismatched jobs.
def state_issues_expectations_jobs($state; $job_expectations): (
  reduce (($job_expectations // {}) | to_entries[]) as $pe
    ([]; . + (
      reduce (($pe.value // {}) | to_entries[]) as $je
        ([]; . + state_issue_expect_job_status($state; $pe.key; $je.key; $je.value))
    ))
);

# ARGS  : $state: state, $expectations: expectations
# IN    : (unused)
# OUT   : [issue]
# NOTE  : Validate both pipeline- and job-level expectations and concatenate results.
def state_issues_expectations($state; $expectations): (
  state_issues_expectations_pipelines($state; $expectations.pipelines // {})
    + state_issues_expectations_jobs($state; $expectations.jobs // {})
);

# ARGS  : $state: state, pred: filter(status -> boolean)
# IN    : (unused)
# OUT   : [issue] — cause "predicate_failed"
# NOTE  : Emit issue for status that does not satisfy pred.
def state_issues_pipeline_status($state; pred): (
  [
    $state.pipelines[] as $pipeline
    | select(($pipeline.latest_execution.status | pred) | not)
    | issue_pipeline($pipeline.name; "predicate_failed"; "latest_execution | pred"; $pipeline.latest_execution.status)
  ]
);
