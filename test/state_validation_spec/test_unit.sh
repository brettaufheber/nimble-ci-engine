#!/usr/bin/env bash

function test_spec {

  export TEST_DIR="$1"
  export TEST_NAME="$(basename "$TEST_DIR")"
  TEST_PARTS_FAILED=0

  CI_CONFIG_FILE="$TEST_DIR/ci.yaml"
  STATE_FILE="$TEST_DIR/state.json"

  set_env_defaults
  load_ci_config

  it "dag_find_pipeline finds existing pipeline"
  ACTUAL="$(run_jq 'dag_find_pipeline($config; "p1") | .name')"
  EXPECTED='"p1"'
  assert_json_eq "$EXPECTED" "$ACTUAL" "pipeline name"

  it "dag_find_pipeline returns null for unknown pipeline"
  ACTUAL="$(run_jq 'dag_find_pipeline($config; "zzz")')"
  EXPECTED='null'
  assert_json_eq "$EXPECTED" "$ACTUAL" "unknown pipeline returns null"

  it "dag_find_job finds existing job in pipeline"
  ACTUAL="$(run_jq 'dag_find_pipeline($config; "p1") as $p | dag_find_job($p; "build") | .name')"
  EXPECTED='"build"'
  assert_json_eq "$EXPECTED" "$ACTUAL" "job name"

  it "dag_find_job returns null for unknown job"
  ACTUAL="$(run_jq 'dag_find_pipeline($config; "p1") as $p | dag_find_job($p; "unknown")')"
  EXPECTED='null'
  assert_json_eq "$EXPECTED" "$ACTUAL" "unknown job returns null"

  ### Node list
  it "dag_node_list flattens all jobs across pipelines"
  ACTUAL="$(run_jq 'dag_node_list($config) | sort_by(.pipeline, .job)')"
  EXPECTED='[
    {"pipeline":"p1","job":"build"},
    {"pipeline":"p1","job":"cycle1"},
    {"pipeline":"p1","job":"cycle2"},
    {"pipeline":"p1","job":"deploy"},
    {"pipeline":"p1","job":"test"},
    {"pipeline":"p2","job":"lint"},
    {"pipeline":"p2","job":"package"},
    {"pipeline":"p3","job":"only"}
  ]'
  assert_json_eq "$EXPECTED" "$ACTUAL" "node list (sorted)"

  ### Edge list (intra + inter, dedup, unknown refs ignored, self-edge)
  it "dag_edge_list builds correct number of edges incl. inter-pipeline expansion and dedup"
  ACTUAL="$(run_jq 'dag_edge_list($config) | length')"
  EXPECTED='15'
  assert_json_eq "$EXPECTED" "$ACTUAL" "edge count"

  it "dag_edge_list contains an intra-pipeline edge (p1.test -> p1.build)"
  ACTUAL="$(run_jq 'dag_edge_list($config) | any(.from.pipeline=="p1" and .from.job=="test" and .to.pipeline=="p1" and .to.job=="build")')"
  EXPECTED='true'
  assert_json_eq "$EXPECTED" "$ACTUAL" "test->build"

  it "dag_edge_list contains a deduped edge (p1.deploy -> p1.test) exactly once"
  ACTUAL="$(run_jq 'dag_edge_list($config) | map(select(.from.pipeline=="p1" and .from.job=="deploy" and .to.pipeline=="p1" and .to.job=="test")) | length')"
  EXPECTED='1'
  assert_json_eq "$EXPECTED" "$ACTUAL" "deploy->test deduped"

  it "dag_edge_list contains inter-pipeline edges from p2 jobs to all p1 jobs"
  ACTUAL="$(run_jq 'dag_edge_list($config) | any(.from.pipeline=="p2" and .from.job=="lint" and .to.pipeline=="p1" and .to.job=="build")')"
  EXPECTED='true'
  assert_json_eq "$EXPECTED" "$ACTUAL" "p2.lint->p1.build sample"

  it "fan-out count for p2.lint to p1.* is 5"
  ACTUAL="$(run_jq 'dag_edge_list($config) | map(select(.from.pipeline=="p2" and .from.job=="lint" and .to.pipeline=="p1")) | length')"
  EXPECTED='5'
  assert_json_eq "$EXPECTED" "$ACTUAL" "p2.lint fan-out to p1.*"

  it "dag_edge_list includes self-edge for p3.only"
  ACTUAL="$(run_jq 'dag_edge_list($config) | any(.from.pipeline=="p3" and .from.job=="only" and .to.pipeline=="p3" and .to.job=="only")')"
  EXPECTED='true'
  assert_json_eq "$EXPECTED" "$ACTUAL" "self-edge present"

  ### Adjacency (successors)
  it "dag_adjacency_list creates entries for all nodes (including those without outgoing edges)"
  ACTUAL="$(run_jq '
    dag_node_list($config) as $n
    | dag_edge_list($config) as $e
    | dag_adjacency_list($n; $e)
    | has("p1") and (.p1 | has("build"))
  ')"
  EXPECTED='true'
  assert_json_eq "$EXPECTED" "$ACTUAL" "p1/build key exists"

  it "adjacency successors for p1.test is [p1.build]"
  ACTUAL="$(run_jq '
    dag_node_list($config) as $n
    | dag_edge_list($config) as $e
    | dag_adjacency_list($n; $e)
    | .p1.test | sort_by(.pipeline,.job)
  ')"
  EXPECTED='[{"pipeline":"p1","job":"build"}]'
  assert_json_eq "$EXPECTED" "$ACTUAL" "succ p1.test"

  it "adjacency successors for p1.build is empty"
  ACTUAL="$(run_jq '
    dag_node_list($config) as $n
    | dag_edge_list($config) as $e
    | dag_adjacency_list($n; $e)
    | .p1.build
  ')"
  EXPECTED='[]'
  assert_json_eq "$EXPECTED" "$ACTUAL" "succ p1.build empty"

  it "adjacency successors for p2.lint contains all p1 jobs (fan-out)"
  ACTUAL="$(run_jq '
    dag_node_list($config) as $n
    | dag_edge_list($config) as $e
    | dag_adjacency_list($n; $e)
    | .p2.lint | length
  ')"
  EXPECTED='5'
  assert_json_eq "$EXPECTED" "$ACTUAL" "succ p2.lint size=5"

  it "adjacency successors for p3.only contains itself (due to self-edge)"
  ACTUAL="$(run_jq '
    dag_node_list($config) as $n
    | dag_edge_list($config) as $e
    | dag_adjacency_list($n; $e)
    | .p3.only
  ')"
  EXPECTED='[{"pipeline":"p3","job":"only"}]'
  assert_json_eq "$EXPECTED" "$ACTUAL" "succ p3.only self"

  ### Reverse adjacency (predecessors)
  it "dag_adjacency_reverse_list builds predecessors (e.g., p1.build has p1.test + p2.*)"
  ACTUAL="$(run_jq '
    dag_node_list($config) as $n
    | dag_edge_list($config) as $e
    | dag_adjacency_reverse_list($n; $e)
    | .p1.build | length
  ')"
  EXPECTED='3'
  assert_json_eq "$EXPECTED" "$ACTUAL" "pred p1.build size"

  it "reverse adjacency for p3.only contains itself (self-edge)"
  ACTUAL="$(run_jq '
    dag_node_list($config) as $n
    | dag_edge_list($config) as $e
    | dag_adjacency_reverse_list($n; $e)
    | .p3.only
  ')"
  EXPECTED='[{"pipeline":"p3","job":"only"}]'
  assert_json_eq "$EXPECTED" "$ACTUAL" "pred p3.only self"

  ### Reach / DFS
  it "dag_reach (forward) from p2.lint reaches all p1 jobs (5)"
  ACTUAL="$(run_jq '
    dag_node_list($config) as $n
    | dag_edge_list($config) as $e
    | dag_adjacency_list($n; $e) as $a
    | dag_reach($a; {pipeline:"p2",job:"lint"}) | length
  ')"
  EXPECTED='5'
  assert_json_eq "$EXPECTED" "$ACTUAL" "forward reach count"

  it "dag_reach (forward) from p1.build is empty"
  ACTUAL="$(run_jq '
    dag_node_list($config) as $n
    | dag_edge_list($config) as $e
    | dag_adjacency_list($n; $e) as $a
    | dag_reach($a; {pipeline:"p1",job:"build"}) | length
  ')"
  EXPECTED='0'
  assert_json_eq "$EXPECTED" "$ACTUAL" "forward reach empty"

  it "dag_reach handles cycles: from p1.cycle1 reaches only p1.cycle2"
  ACTUAL="$(run_jq '
    dag_node_list($config) as $n
    | dag_edge_list($config) as $e
    | dag_adjacency_list($n; $e) as $a
    | dag_reach($a; {pipeline:"p1",job:"cycle1"}) | sort_by(.pipeline,.job)
  ')"
  EXPECTED='[{"pipeline":"p1","job":"cycle2"}]'
  assert_json_eq "$EXPECTED" "$ACTUAL" "cycle reach"

  it "dag_reach on self-edge: from p3.only reaches [] (self excluded)"
  ACTUAL="$(run_jq '
    dag_node_list($config) as $n
    | dag_edge_list($config) as $e
    | dag_adjacency_list($n; $e) as $a
    | dag_reach($a; {pipeline:"p3",job:"only"}) | length
  ')"
  EXPECTED='0'
  assert_json_eq "$EXPECTED" "$ACTUAL" "self-edge excluded"

  ### Non-parallel nodes (ancestors + descendants, strict, sorted)
  it "dag_non_parallel_nodes for p1/test is [p1/build, p1/deploy] + p2 jobs"
  ACTUAL="$(run_jq 'dag_non_parallel_nodes($config; "p1"; "test")')"
  EXPECTED='[
    {"pipeline":"p1","job":"build"},
    {"pipeline":"p1","job":"deploy"},
    {"pipeline":"p2","job":"lint"},
    {"pipeline":"p2","job":"package"}
  ]'
  assert_json_eq "$EXPECTED" "$ACTUAL" "non-parallel set p1/test"

  it "dag_non_parallel_nodes for p2/lint contains all p1 jobs (descendants only)"
  ACTUAL="$(run_jq 'dag_non_parallel_nodes($config; "p2"; "lint") | sort_by(.pipeline,.job)')"
  EXPECTED='[
    {"pipeline":"p1","job":"build"},
    {"pipeline":"p1","job":"cycle1"},
    {"pipeline":"p1","job":"cycle2"},
    {"pipeline":"p1","job":"deploy"},
    {"pipeline":"p1","job":"test"}
  ]'
  assert_json_eq "$EXPECTED" "$ACTUAL" "non-parallel set p2/lint"

  ### State lookups
  it "state_find_job returns job when present"
  ACTUAL="$(run_jq 'state_find_job($state; "p1"; "test") | .name')"
  EXPECTED='"test"'
  assert_json_eq "$EXPECTED" "$ACTUAL" "find p1/test"

  it "state_find_job returns null when pipeline is unknown"
  ACTUAL="$(run_jq 'state_find_job($state; "zzz"; "test")')"
  EXPECTED='null'
  assert_json_eq "$EXPECTED" "$ACTUAL" "unknown pipeline -> null"

  it "state_find_job returns null when job is unknown"
  ACTUAL="$(run_jq 'state_find_job($state; "p1"; "nope")')"
  EXPECTED='null'
  assert_json_eq "$EXPECTED" "$ACTUAL" "unknown job -> null"

  ### Needs-order issues
  it "state_issues_needs_order: p1/test has no blocking started non-parallel jobs"
  ACTUAL="$(run_jq 'state_issues_needs_order($config; $state; "p1"; "test") | length')"
  EXPECTED='0'
  assert_json_eq "$EXPECTED" "$ACTUAL" "no issues for p1/test"

  it "state_issues_needs_order: p1/deploy is blocked by p1/test (started)"
  ACTUAL="$(run_jq '
    state_issues_needs_order($config; $state; "p1"; "deploy")
    | length
  ')"
  EXPECTED='1'
  assert_json_eq "$EXPECTED" "$ACTUAL" "one blocking issue"

  it "state_issues_needs_order: issue shape for p1/deploy names offender and cause"
  ACTUAL="$(run_jq '
    state_issues_needs_order($config; $state; "p1"; "deploy")
    | first
    | {kind, pipeline, job, cause, has_expected:(has("expected")), actual, by}
  ')"
  EXPECTED='{"kind":"job","pipeline":"p1","job":"deploy","cause":"violated_needs_order","has_expected":false,"actual":"started","by":{"pipeline":"p1","job":"test"}}'
  assert_json_eq "$EXPECTED" "$ACTUAL" "issue shape ok"

  ### Concurrency issues (0 means "disabled"; only status=="started" counts as running)
  it "state_issues_concurrency_limits: no limits (0/0) -> no issues"
  ACTUAL="$(run_jq 'state_issues_concurrency_limits($state; 0; 0) | length')"
  EXPECTED='0'
  assert_json_eq "$EXPECTED" "$ACTUAL" "no limits -> ok"

  it "state_issues_concurrency_limits: pipeline limit exact match (1 running) -> no issues"
  ACTUAL="$(run_jq 'state_issues_concurrency_limits($state; 1; 0) | length')"
  EXPECTED='0'
  assert_json_eq "$EXPECTED" "$ACTUAL" "exactly at limit -> ok"

  it "state_issues_concurrency_limits: pipeline limit violation when > limit"
  ACTUAL="$(run_jq '
    # mutate: mark p3 as started so running pipelines = 2
    ($state | .pipelines |= (map(if .name=="p3" then (.latest_execution.status="started") else . end))) as $s
    | state_issues_concurrency_limits($s; 1; 0) | length
  ')"
  EXPECTED='2'
  assert_json_eq "$EXPECTED" "$ACTUAL" "two running > limit -> two issues"

  it "state_issues_job_concurrency_limit: exact limit -> no issues"
  ACTUAL="$(run_jq 'state_issues_job_concurrency_limit($state; 1) | length')"
  EXPECTED='0'
  assert_json_eq "$EXPECTED" "$ACTUAL" "one started job in p1, limit 1 -> ok"

  it "state_issues_job_concurrency_limit: violation when > limit for a pipeline"
  ACTUAL="$(run_jq '
    # mutate: mark p1.deploy as started so p1 has 2 started jobs
    ($state
      | .pipelines |= (map(
          if .name=="p1" then
            (.latest_execution.jobs |= (map(if .name == "deploy" then (.latest_attempt.status="started") else . end)))
          else . end))) as $s
    | state_issues_job_concurrency_limit($s; 1)
    | map(select(.pipeline=="p1")) | length
  ')"
  EXPECTED='2'
  assert_json_eq "$EXPECTED" "$ACTUAL" "two started jobs in p1 > limit -> two issues"

  ### Allowed pipeline statuses
  it "state_issues_pipeline_status flags pipelines not in allowed set"
  ACTUAL="$(run_jq 'state_issues_pipeline_status($state; . == "success") | map(.pipeline) | sort | unique')"
  EXPECTED='["p1","p3"]'
  assert_json_eq "$EXPECTED" "$ACTUAL" "p1(started), p3(pending) flagged"

  ### History helpers
  it "pipeline_execution_status_history sorts previous_executions by timestamp (p1)"
  ACTUAL="$(run_jq 'pipeline_execution_status_history($state; "p1")')"
  EXPECTED='["failure","success","started"]'
  assert_json_eq "$EXPECTED" "$ACTUAL" "p1 status history sorted"

  it "pipeline_execution_status_history returns [latest] when previous_executions is empty (p3)"
  ACTUAL="$(run_jq 'pipeline_execution_status_history($state; "p3")')"
  EXPECTED='["pending"]'
  assert_json_eq "$EXPECTED" "$ACTUAL" "p3 empty history -> latest only"

  it "job_attempt_status_history sorts previous_attempts by timestamp (p1/test)"
  ACTUAL="$(run_jq 'job_attempt_status_history($state; "p1"; "test")')"
  EXPECTED='["failure","success","started"]'
  assert_json_eq "$EXPECTED" "$ACTUAL" "p1/test attempt history sorted"

  it "job_attempt_status_history returns [latest] when previous_attempts is empty (p3/only)"
  ACTUAL="$(run_jq 'job_attempt_status_history($state; "p3"; "only")')"
  EXPECTED='["pending"]'
  assert_json_eq "$EXPECTED" "$ACTUAL" "p3/only empty history -> latest only"

  ### Expectation helpers
  it "state_issue_expect_pipeline_status: ok when full history matches (p2)"
  ACTUAL="$(run_jq 'state_issue_expect_pipeline_status($state; "p2"; ["failure","success"]) | length')"
  EXPECTED='0'
  assert_json_eq "$EXPECTED" "$ACTUAL" "p2 expected full history"

  it "state_issue_expect_pipeline_status: mismatch when scalar expected differs from history (p2)"
  ACTUAL="$(run_jq 'state_issue_expect_pipeline_status($state; "p2"; "started") | first | {pipeline,cause,expected,actual}')"
  EXPECTED='{"pipeline":"p2","cause":"mismatch","expected":["started"],"actual":["failure","success"]}'
  assert_json_eq "$EXPECTED" "$ACTUAL" "pipeline mismatch"

  it "state_issue_expect_pipeline_status: ok when previous_executions empty and scalar matches latest (p3)"
  ACTUAL="$(run_jq 'state_issue_expect_pipeline_status($state; "p3"; "pending") | length')"
  EXPECTED='0'
  assert_json_eq "$EXPECTED" "$ACTUAL" "p3 scalar vs latest"

  it "state_issue_expect_pipeline_status: mismatch when previous_executions empty but expected history too long (p3)"
  ACTUAL="$(run_jq 'state_issue_expect_pipeline_status($state; "p3"; ["success","pending"]) | first | {pipeline,cause,expected,actual}')"
  EXPECTED='{"pipeline":"p3","cause":"mismatch","expected":["success","pending"],"actual":["pending"]}'
  assert_json_eq "$EXPECTED" "$ACTUAL" "p3 history length mismatch"

  it "state_issue_expect_pipeline_status: missing pipeline emits issue"
  ACTUAL="$(run_jq 'state_issue_expect_pipeline_status($state; "zzz"; "success") | first | {pipeline,cause,expected,actual}')"
  EXPECTED='{"pipeline":"zzz","cause":"missing","expected":["success"],"actual":null}'
  assert_json_eq "$EXPECTED" "$ACTUAL" "missing pipeline"

  it "state_issue_expect_job_status: ok when full attempt history matches (p1/build)"
  ACTUAL="$(run_jq 'state_issue_expect_job_status($state; "p1"; "build"; ["failure","success"]) | length')"
  EXPECTED='0'
  assert_json_eq "$EXPECTED" "$ACTUAL" "job history match"

  it "state_issue_expect_job_status: mismatch reflects full actual history (p1/deploy)"
  ACTUAL="$(run_jq 'state_issue_expect_job_status($state; "p1"; "deploy"; "success") | first | {pipeline,job,cause,expected,actual}')"
  EXPECTED='{"pipeline":"p1","job":"deploy","cause":"mismatch","expected":["success"],"actual":["failure","skipped","pending"]}'
  assert_json_eq "$EXPECTED" "$ACTUAL" "job mismatch w/ full history"

  it "state_issue_expect_job_status: ok when previous_attempts empty and scalar matches latest (p3/only)"
  ACTUAL="$(run_jq 'state_issue_expect_job_status($state; "p3"; "only"; "pending") | length')"
  EXPECTED='0'
  assert_json_eq "$EXPECTED" "$ACTUAL" "job scalar vs latest"

  it "state_issue_expect_job_status: mismatch when previous_attempts empty but expected longer history (p3/only)"
  ACTUAL="$(run_jq 'state_issue_expect_job_status($state; "p3"; "only"; ["success","pending"]) | first | {pipeline,job,cause,expected,actual}')"
  EXPECTED='{"pipeline":"p3","job":"only","cause":"mismatch","expected":["success","pending"],"actual":["pending"]}'
  assert_json_eq "$EXPECTED" "$ACTUAL" "job history length mismatch"

  it "state_issue_expect_job_status: missing job emits issue"
  ACTUAL="$(run_jq 'state_issue_expect_job_status($state; "p1"; "ghost"; "success") | first | {pipeline,job,cause,expected,actual}')"
  EXPECTED='{"pipeline":"p1","job":"ghost","cause":"missing","expected":["success"],"actual":null}'
  assert_json_eq "$EXPECTED" "$ACTUAL" "job missing"

  it "state_issues_expectations aggregates pipeline + job expectations (keeps 3 issues)"
  ACTUAL="$(run_jq '
    {
      pipelines: {"p1":"success","p2":["failure","success"]},
      jobs: {
        "p1": {"build":["failure","success"],"deploy":"success","ghost":"success"},
        "p2": {"lint":["failure","success"]}
      }
    } as $exp
    | state_issues_expectations($state; $exp)
    | length
  ')"
  EXPECTED='3'
  assert_json_eq "$EXPECTED" "$ACTUAL" "combined expectations -> 3 issues"

  ### Empty state behavior (no pipelines/jobs present)
  STATE_FILE="$TEST_DIR/state_empty.json"

  it "state_issues_concurrency_limits with empty state yields no issues"
  ACTUAL="$(run_jq 'state_issues_concurrency_limits($state; 1; 1) | length')"
  EXPECTED='0'
  assert_json_eq "$EXPECTED" "$ACTUAL" "empty state -> ok"

  return $(( TEST_PARTS_FAILED > 0 ? 1 : 0 ))
}

function run_jq {
  local FILTER
  FILTER="$1"
  shift
  jqw -nc \
    --argjson 'config' "$CI_CONFIG" \
    --argfile 'state' "$STATE_FILE" \
    "$@" \
    'include "lib/state_validation"; '"$FILTER"
}
