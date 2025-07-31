#!/usr/bin/env bash

function test_spec {

  export TEST_DIR="$1"
  export TEST_NAME="$(basename "$TEST_DIR")"
  TEST_PARTS_FAILED=0

  set_env_defaults

  # ==================================
  # 1) duplicate_pipeline_errors
  # ==================================

  it "returns no errors for an empty pipelines array (duplicate_pipeline_errors)"
  JSON='{"pipelines":[]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       duplicate_pipeline_errors | sort_by(.pipeline)'
  )"
  EXPECTED='[]'
  assert_json_eq \
    "$EXPECTED" \
    "$ACTUAL" \
    "duplicate_pipeline_errors: empty"

  it "reports no duplicates when pipeline names are unique (duplicate_pipeline_errors)"
  JSON='{"pipelines":[{"name":"A"},{"name":"B"}]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       duplicate_pipeline_errors | sort_by(.pipeline)'
  )"
  EXPECTED='[]'
  assert_json_eq \
    "$EXPECTED" \
    "$ACTUAL" \
    "duplicate_pipeline_errors: unique"

  it "emits one error for a single duplicate name pair (duplicate_pipeline_errors)"
  JSON='{"pipelines":[{"name":"A"},{"name":"A"}]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       duplicate_pipeline_errors | sort_by(.pipeline)'
  )"
  EXPECTED='[{"kind":"duplicate_pipeline","pipeline":"A"}]'
  assert_json_eq \
    "$EXPECTED" \
    "$ACTUAL" \
    "duplicate_pipeline_errors: single duplicate pair"

  it "detects duplicates even if they are non-adjacent (duplicate_pipeline_errors)"
  JSON='{"pipelines":[{"name":"A"},{"name":"C"},{"name":"A"},{"name":"B"}]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       duplicate_pipeline_errors | sort_by(.pipeline)'
  )"
  EXPECTED='[{"kind":"duplicate_pipeline","pipeline":"A"}]'
  assert_json_eq \
    "$EXPECTED" \
    "$ACTUAL" \
    "duplicate_pipeline_errors: non-adjacent duplicates"

  it "emits one error per duplicated name across groups (duplicate_pipeline_errors)"
  JSON='{"pipelines":[{"name":"A"},{"name":"C"},{"name":"A"},{"name":"B"},{"name":"A"},{"name":"B"}]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       duplicate_pipeline_errors | sort_by(.pipeline)'
  )"
  EXPECTED='[
    {"kind":"duplicate_pipeline","pipeline":"A"},
    {"kind":"duplicate_pipeline","pipeline":"B"}
  ]'
  assert_json_eq \
    "$(printf '%s' "$EXPECTED" | jqw -c 'sort_by(.pipeline)')" \
    "$ACTUAL" \
    "duplicate_pipeline_errors: multiple dup groups"

  # =========================
  # 2) duplicate_job_errors
  # =========================

  it "returns no errors when there are no pipelines (duplicate_job_errors)"
  JSON='{"pipelines":[]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       duplicate_job_errors | sort_by(.pipeline, .job)'
  )"
  EXPECTED='[]'
  assert_json_eq \
    "$EXPECTED" \
    "$ACTUAL" \
    "duplicate_job_errors: no pipelines"

  it "returns no errors for pipelines that each have empty job lists (duplicate_job_errors)"
  JSON='{"pipelines":[{"name":"P","jobs":[]},{"name":"Q","jobs":[]},{"name":"R","jobs":[]}]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       duplicate_job_errors | sort_by(.pipeline, .job)'
  )"
  EXPECTED='[]'
  assert_json_eq \
    "$EXPECTED" \
    "$ACTUAL" \
    "duplicate_job_errors: pipelines without jobs"

  it "allows the same job name across pipelines but no duplicates within one (duplicate_job_errors)"
  JSON='{"pipelines":[{"name":"P","jobs":[{"name":"j1"},{"name":"j2"}]},{"name":"Q","jobs":[{"name":"j1"}]}]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       duplicate_job_errors | sort_by(.pipeline, .job)'
  )"
  EXPECTED='[]'
  assert_json_eq \
    "$EXPECTED" \
    "$ACTUAL" \
    "duplicate_job_errors: unique jobs"

  it "flags duplicates only inside the same pipeline (duplicate_job_errors)"
  JSON='{"pipelines":[{"name":"P","jobs":[{"name":"j"},{"name":"j"}]},{"name":"Q","jobs":[{"name":"j"}]}]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       duplicate_job_errors | sort_by(.pipeline, .job)'
  )"
  EXPECTED='[{"kind":"duplicate_job","pipeline":"P","job":"j"}]'
  assert_json_eq \
    "$EXPECTED" \
    "$ACTUAL" \
    "duplicate_job_errors: duplicate inside same pipeline only"

  it "emits one error per duplicated job name within a pipeline (duplicate_job_errors)"
  JSON='{"pipelines":[{"name":"P","jobs":[{"name":"j1"},{"name":"j2"},{"name":"j1"},{"name":"j1"},{"name":"j2"}]}]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       duplicate_job_errors | sort_by(.pipeline, .job)'
  )"
  EXPECTED='[
    {"kind":"duplicate_job","pipeline":"P","job":"j1"},
    {"kind":"duplicate_job","pipeline":"P","job":"j2"}
  ]'
  assert_json_eq \
    "$(printf '%s' "$EXPECTED" | jqw -c 'sort_by(.pipeline, .job)')" \
    "$ACTUAL" \
    "duplicate_job_errors: multiple groups within one pipeline"

  it "handles multiple pipelines each with its own duplicates (duplicate_job_errors)"
  JSON='{"pipelines":[
    {"name":"P","jobs":[{"name":"x"},{"name":"x"},{"name":"y"}]},
    {"name":"Q","jobs":[{"name":"x"},{"name":"z"},{"name":"x"}]}
  ]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       duplicate_job_errors | sort_by(.pipeline, .job)'
  )"
  EXPECTED='[
    {"kind":"duplicate_job","pipeline":"P","job":"x"},
    {"kind":"duplicate_job","pipeline":"Q","job":"x"}
  ]'
  assert_json_eq \
    "$(printf '%s' "$EXPECTED" | jqw -c 'sort_by(.pipeline, .job)')" \
    "$ACTUAL" \
    "duplicate_job_errors: multiple pipelines each with duplicates"

  # ===============================
  # 3) missing_pipeline_errors
  # ===============================

  it "returns no errors for an empty pipelines array (missing_pipeline_errors)"
  JSON='{"pipelines":[]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       missing_pipeline_errors | sort_by(.pipeline, .missing)'
  )"
  EXPECTED='[]'
  assert_json_eq \
    "$EXPECTED" \
    "$ACTUAL" \
    "missing_pipeline_errors: empty pipelines array"

  it "reports a missing pipeline referenced in needs (missing_pipeline_errors)"
  JSON='{"pipelines":[{"name":"A","needs":["B"]}]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       missing_pipeline_errors | sort_by(.pipeline, .missing)'
  )"
  EXPECTED='[{"kind":"missing_pipeline","pipeline":"A","missing":"B"}]'
  assert_json_eq \
    "$EXPECTED" \
    "$ACTUAL" \
    "missing_pipeline_errors: single missing"

  it "ignores present references and reports only missing ones (missing_pipeline_errors)"
  JSON='{"pipelines":[{"name":"A","needs":["B","C"]},{"name":"C"}]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       missing_pipeline_errors | sort_by(.pipeline, .missing)'
  )"
  EXPECTED='[{"kind":"missing_pipeline","pipeline":"A","missing":"B"}]'
  assert_json_eq \
    "$EXPECTED" \
    "$ACTUAL" \
    "missing_pipeline_errors: mixed present/missing"

  it "handles missing/absent needs fields and empty arrays (missing_pipeline_errors)"
  JSON='{"pipelines":[{"name":"X"},{"name":"Y","needs":[]},{"name":"Z","needs":[]}]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       missing_pipeline_errors | sort_by(.pipeline, .missing)'
  )"
  EXPECTED='[]'
  assert_json_eq \
    "$EXPECTED" \
    "$ACTUAL" \
    "missing_pipeline_errors: no needs variants"

  it "reports no errors when all referenced pipelines exist (missing_pipeline_errors)"
  JSON='{"pipelines":[{"name":"A","needs":["B","C"]},{"name":"B"},{"name":"C"}]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       missing_pipeline_errors | sort_by(.pipeline, .missing)'
  )"
  EXPECTED='[]'
  assert_json_eq \
    "$EXPECTED" \
    "$ACTUAL" \
    "missing_pipeline_errors: all present"

  it "reports all missing references across multiple pipelines (missing_pipeline_errors)"
  JSON='{"pipelines":[{"name":"A","needs":["B","C","X"]},{"name":"C"},{"name":"D","needs":["E"]}]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       missing_pipeline_errors | sort_by(.pipeline, .missing)'
  )"
  EXPECTED='[
    {"kind":"missing_pipeline","pipeline":"A","missing":"B"},
    {"kind":"missing_pipeline","pipeline":"A","missing":"X"},
    {"kind":"missing_pipeline","pipeline":"D","missing":"E"}
  ]'
  assert_json_eq \
    "$EXPECTED" \
    "$ACTUAL" \
    "missing_pipeline_errors: multiple pipelines & missings"

  # ===========================
  # 4) missing_job_errors
  # ===========================

  it "returns no errors when all job-level needs exist (missing_job_errors)"
  JSON='{"pipelines":[{"name":"P","jobs":[{"name":"j1","needs":["j2"]},{"name":"j2"}]}]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       missing_job_errors | sort_by(.pipeline, .job, .missing)'
  )"
  EXPECTED='[]'
  assert_json_eq \
    "$EXPECTED" \
    "$ACTUAL" \
    "missing_job_errors: all targets present"

  it "reports a missing job and ignores empty needs arrays (missing_job_errors)"
  JSON='{"pipelines":[{"name":"P","jobs":[{"name":"a","needs":["b"]},{"name":"c","needs":[],"jobs":[]},{"name":"d","needs":[],"jobs":[]}]}]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       missing_job_errors | sort_by(.pipeline, .job, .missing)'
  )"
  EXPECTED='[{"kind":"missing_job","pipeline":"P","job":"a","missing":"b"}]'
  assert_json_eq \
    "$EXPECTED" \
    "$ACTUAL" \
    "missing_job_errors: single missing"

  it "reports all missing targets within a pipeline (missing_job_errors)"
  JSON='{"pipelines":[{"name":"P","jobs":[{"name":"a","needs":["b","c","x"]},{"name":"b"}]},{"name":"x","jobs":[]}]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       missing_job_errors | sort_by(.pipeline, .job, .missing)'
  )"
  EXPECTED='[
    {"kind":"missing_job","pipeline":"P","job":"a","missing":"c"},
    {"kind":"missing_job","pipeline":"P","job":"a","missing":"x"}
  ]'
  assert_json_eq \
    "$EXPECTED" \
    "$ACTUAL" \
    "missing_job_errors: multiple missing in one pipeline"

  it "does not allow cross-pipeline job references (missing_job_errors)"
  JSON='{"pipelines":[{"name":"P1","jobs":[{"name":"a","needs":["b"]}]},{"name":"P2","jobs":[{"name":"b"}]}]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       missing_job_errors | sort_by(.pipeline, .job, .missing)'
  )"
  EXPECTED='[{"kind":"missing_job","pipeline":"P1","job":"a","missing":"b"}]'
  assert_json_eq \
    "$EXPECTED" \
    "$ACTUAL" \
    "missing_job_errors: cross-pipeline job reference is missing"

  it "reports missing jobs across multiple pipelines (missing_job_errors)"
  JSON='{"pipelines":[
    {"name":"P1","jobs":[{"name":"a","needs":["b","c"]},{"name":"b"}]},
    {"name":"P2","jobs":[{"name":"x","needs":["y"]}]}
  ]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       missing_job_errors | sort_by(.pipeline, .job, .missing)'
  )"
  EXPECTED='[
    {"kind":"missing_job","pipeline":"P1","job":"a","missing":"c"},
    {"kind":"missing_job","pipeline":"P2","job":"x","missing":"y"}
  ]'
  assert_json_eq \
    "$EXPECTED" \
    "$ACTUAL" \
    "missing_job_errors: multiple pipelines and missing jobs"

  # ===========================
  # 5) cycle_pipeline_errors
  # ===========================

  it "returns no cycles for an empty pipelines array (cycle_pipeline_errors)"
  JSON='{"pipelines":[]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       cycle_pipeline_errors
       | sort_by(.cycle | map(@base64) | join("|"))'
  )"
  EXPECTED='[]'
  assert_json_eq \
    "$EXPECTED" \
    "$ACTUAL" \
    "cycle_pipeline_errors: empty"

  it "detects a self-loop as a cycle (cycle_pipeline_errors)"
  JSON='{"pipelines":[{"name":"D","needs":["D"]}]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       cycle_pipeline_errors
       | sort_by(.cycle | map(@base64) | join("|"))'
  )"
  EXPECTED='[{"kind":"pipeline_cycle","cycle":["D"]}]'
  assert_json_eq \
    "$EXPECTED" \
    "$ACTUAL" \
    "cycle_pipeline_errors: self-loop"

  it "finds disjoint cycles of sizes 3 and 2 (cycle_pipeline_errors)"
  JSON='{"pipelines":[
    {"name":"A","needs":["B"]},
    {"name":"B","needs":["C"]},
    {"name":"C","needs":["A"]},
    {"name":"X","needs":["Y"]},
    {"name":"Y","needs":["X"]},
    {"name":"Z","needs":[]}
  ]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       cycle_pipeline_errors
       | sort_by(.cycle | map(@base64) | join("|"))'
  )"
  EXPECTED='[
    {"kind":"pipeline_cycle","cycle":["A","B","C"]},
    {"kind":"pipeline_cycle","cycle":["X","Y"]}
  ]'
  assert_json_eq \
    "$(printf '%s' "$EXPECTED" | jqw -c 'sort_by(.cycle | map(@base64) | join("|"))')" \
    "$ACTUAL" \
    "cycle_pipeline_errors: multiple disjoint cycles"

  it "returns no cycles for an acyclic graph (cycle_pipeline_errors)"
  JSON='{"pipelines":[{"name":"A","needs":["B"]},{"name":"B","needs":[]},{"name":"C"}]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       cycle_pipeline_errors
       | sort_by(.cycle | map(@base64) | join("|"))'
  )"
  EXPECTED='[]'
  assert_json_eq \
    "$EXPECTED" \
    "$ACTUAL" \
    "cycle_pipeline_errors: none"

  it "detects a two-node cycle (cycle_pipeline_errors)"
  JSON='{"pipelines":[{"name":"A","needs":["B"]},{"name":"B","needs":["A"]}]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       cycle_pipeline_errors
       | sort_by(.cycle | map(@base64) | join("|"))'
  )"
  EXPECTED='[{"kind":"pipeline_cycle","cycle":["A","B"]}]'
  assert_json_eq \
    "$EXPECTED" \
    "$ACTUAL" \
    "cycle_pipeline_errors: two-node cycle"

  it "detects a four-node cycle (cycle_pipeline_errors)"
  JSON='{"pipelines":[
    {"name":"A","needs":["B"]},
    {"name":"B","needs":["C"]},
    {"name":"C","needs":["D"]},
    {"name":"D","needs":["A"]}
  ]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       cycle_pipeline_errors
       | sort_by(.cycle | map(@base64) | join("|"))'
  )"
  EXPECTED='[{"kind":"pipeline_cycle","cycle":["A","B","C","D"]}]'
  assert_json_eq \
    "$EXPECTED" \
    "$ACTUAL" \
    "cycle_pipeline_errors: four-node cycle"

  it "ignores tails and reports only the cycle core (cycle_pipeline_errors)"
  JSON='{"pipelines":[
    {"name":"T1","needs":["A"]},
    {"name":"A","needs":["B"]},
    {"name":"B","needs":["C"]},
    {"name":"C","needs":["A"]},
    {"name":"T2","needs":["B"]}
  ]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       cycle_pipeline_errors
       | sort_by(.cycle | map(@base64) | join("|"))'
  )"
  EXPECTED='[{"kind":"pipeline_cycle","cycle":["A","B","C"]}]'
  assert_json_eq \
    "$EXPECTED" \
    "$ACTUAL" \
    "cycle_pipeline_errors: tail into cycle"

  it "finds overlapping cycles that share a node (cycle_pipeline_errors)"
  JSON='{"pipelines":[
    {"name":"A","needs":["B","D"]},
    {"name":"B","needs":["C"]},
    {"name":"C","needs":["A"]},
    {"name":"D","needs":["E"]},
    {"name":"E","needs":["A"]}
  ]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       cycle_pipeline_errors
       | sort_by(.cycle | map(@base64) | join("|"))'
  )"
  EXPECTED='[
    {"kind":"pipeline_cycle","cycle":["A","B","C"]},
    {"kind":"pipeline_cycle","cycle":["A","D","E"]}
  ]'
  assert_json_eq \
    "$(printf '%s' "$EXPECTED" | jqw -c 'sort_by(.cycle | map(@base64) | join("|"))')" \
    "$ACTUAL" \
    "cycle_pipeline_errors: overlapping cycles sharing a node"

  it "does not double-count cycles from duplicate edges (cycle_pipeline_errors)"
  JSON='{"pipelines":[
    {"name":"A","needs":["B","B"]},
    {"name":"B","needs":["A","A"]}
  ]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       cycle_pipeline_errors
       | sort_by(.cycle | map(@base64) | join("|"))'
  )"
  EXPECTED='[{"kind":"pipeline_cycle","cycle":["A","B"]}]'
  assert_json_eq \
    "$EXPECTED" \
    "$ACTUAL" \
    "cycle_pipeline_errors: duplicate edges do not duplicate errors"

  it "finds multiple disjunct cycles in a mixed graph (cycle_pipeline_errors)"
  JSON='{"pipelines":[
    {"name":"M1","needs":["M2"]},
    {"name":"M2","needs":["M3","M3"]},
    {"name":"M3","needs":["M1"]},
    {"name":"N1","needs":["N2"]},
    {"name":"N2","needs":["N1"]},
    {"name":"T","needs":["M1"]}
  ]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       cycle_pipeline_errors
       | sort_by(.cycle | map(@base64) | join("|"))'
  )"
  EXPECTED='[
    {"kind":"pipeline_cycle","cycle":["M1","M2","M3"]},
    {"kind":"pipeline_cycle","cycle":["N1","N2"]}
  ]'
  assert_json_eq \
    "$(printf '%s' "$EXPECTED" | jqw -c 'sort_by(.cycle | map(@base64) | join("|"))')" \
    "$ACTUAL" \
    "cycle_pipeline_errors: mixed complex"

  # =======================
  # 6) cycle_job_errors
  # =======================

  it "returns no cycles for an empty pipelines array (cycle_job_errors)"
  JSON='{"pipelines":[]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       cycle_job_errors
       | sort_by(.pipeline, (.cycle | map(@base64) | join("|")))'
  )"
  EXPECTED='[]'
  assert_json_eq \
    "$EXPECTED" \
    "$ACTUAL" \
    "cycle_job_errors: empty"

  it "detects a two-job cycle within one pipeline (cycle_job_errors)"
  JSON='{"pipelines":[{"name":"P","jobs":[{"name":"j1","needs":["j2"]},{"name":"j2","needs":["j1"]}]}]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       cycle_job_errors
       | sort_by(.pipeline, (.cycle | map(@base64) | join("|")))'
  )"
  EXPECTED='[{"kind":"job_cycle","pipeline":"P","cycle":["j1","j2"]}]'
  assert_json_eq \
    "$EXPECTED" \
    "$ACTUAL" \
    "cycle_job_errors: pair"

  it "detects a self-loop and ignores pipelines without jobs (cycle_job_errors)"
  JSON='{"pipelines":[{"name":"P","jobs":[{"name":"x","needs":["x"]}]},{"name":"Q","jobs":[]}]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       cycle_job_errors
       | sort_by(.pipeline, (.cycle | map(@base64) | join("|")))'
  )"
  EXPECTED='[{"kind":"job_cycle","pipeline":"P","cycle":["x"]}]'
  assert_json_eq \
    "$EXPECTED" \
    "$ACTUAL" \
    "cycle_job_errors: self-loop & empty pipeline"

  it "handles multiple pipelines with mixed cycles and acyclic jobs (cycle_job_errors)"
  JSON='{"pipelines":[
    {"name":"A","jobs":[{"name":"a1","needs":["a2"]},{"name":"a2"}]},
    {"name":"B","jobs":[{"name":"b1","needs":["b2"]},{"name":"b2","needs":["b1"]}]},
    {"name":"C","jobs":[{"name":"c1","needs":["c1"]}]}
  ]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       cycle_job_errors
       | sort_by(.pipeline, (.cycle | map(@base64) | join("|")))'
  )"
  EXPECTED='[
    {"kind":"job_cycle","pipeline":"B","cycle":["b1","b2"]},
    {"kind":"job_cycle","pipeline":"C","cycle":["c1"]}
  ]'
  assert_json_eq \
    "$(printf '%s' "$EXPECTED" | jqw -c 'sort_by(.pipeline, (.cycle | map(@base64) | join("|")))')" \
    "$ACTUAL" \
    "cycle_job_errors: multi pipelines with mixed cycles"

  it "detects a three-job cycle (cycle_job_errors)"
  JSON='{"pipelines":[{"name":"P","jobs":[
    {"name":"a","needs":["b"]},
    {"name":"b","needs":["c"]},
    {"name":"c","needs":["a"]}
  ]}]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       cycle_job_errors
       | sort_by(.pipeline, (.cycle | map(@base64) | join("|")))'
  )"
  EXPECTED='[{"kind":"job_cycle","pipeline":"P","cycle":["a","b","c"]}]'
  assert_json_eq \
    "$EXPECTED" \
    "$ACTUAL" \
    "cycle_job_errors: three-node cycle"

  it "ignores tails and reports only the job cycle core (cycle_job_errors)"
  JSON='{"pipelines":[{"name":"P","jobs":[
    {"name":"t","needs":["a"]},
    {"name":"a","needs":["b"]},
    {"name":"b","needs":["a"]}
  ]}]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       cycle_job_errors
       | sort_by(.pipeline, (.cycle | map(@base64) | join("|")))'
  )"
  EXPECTED='[{"kind":"job_cycle","pipeline":"P","cycle":["a","b"]}]'
  assert_json_eq \
    "$EXPECTED" \
    "$ACTUAL" \
    "cycle_job_errors: tail into cycle"

  it "finds overlapping job cycles that share a job (cycle_job_errors)"
  JSON='{"pipelines":[{"name":"P","jobs":[
    {"name":"a","needs":["b","d"]},
    {"name":"b","needs":["c"]},
    {"name":"c","needs":["a"]},
    {"name":"d","needs":["e"]},
    {"name":"e","needs":["a"]}
  ]}]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       cycle_job_errors
       | sort_by(.pipeline, (.cycle | map(@base64) | join("|")))'
  )"
  EXPECTED='[
    {"kind":"job_cycle","pipeline":"P","cycle":["a","b","c"]},
    {"kind":"job_cycle","pipeline":"P","cycle":["a","d","e"]}
  ]'
  assert_json_eq \
    "$(printf '%s' "$EXPECTED" | jqw -c 'sort_by(.pipeline, (.cycle | map(@base64) | join("|")))')" \
    "$ACTUAL" \
    "cycle_job_errors: overlapping cycles sharing a job"

  it "handles multiple pipelines each with its own job cycle (cycle_job_errors)"
  JSON='{"pipelines":[
    {"name":"P1","jobs":[{"name":"a","needs":["b"]},{"name":"b","needs":["a"]}]},
    {"name":"P2","jobs":[{"name":"x","needs":["y"]},{"name":"y","needs":["x"]}]}
  ]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       cycle_job_errors
       | sort_by(.pipeline, (.cycle | map(@base64) | join("|")))'
  )"
  EXPECTED='[
    {"kind":"job_cycle","pipeline":"P1","cycle":["a","b"]},
    {"kind":"job_cycle","pipeline":"P2","cycle":["x","y"]}
  ]'
  assert_json_eq \
    "$(printf '%s' "$EXPECTED" | jqw -c 'sort_by(.pipeline, (.cycle | map(@base64) | join("|")))')" \
    "$ACTUAL" \
    "cycle_job_errors: multiple pipelines each with a cycle"

  it "returns no cycles for pipelines that have no jobs (cycle_job_errors)"
  JSON='{"pipelines":[{"name":"P","jobs":[]},{"name":"Q","jobs":[]}]}'
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       cycle_job_errors
       | sort_by(.pipeline, (.cycle | map(@base64) | join("|")))'
  )"
  EXPECTED='[]'
  assert_json_eq \
    "$EXPECTED" \
    "$ACTUAL" \
    "cycle_job_errors: pipelines without jobs"

  # ===============================================
  # 7) Complex overall graph to stress the code
  # ===============================================

  JSON='{
    "pipelines": [
      {
        "name":"Build",
        "needs":["Test","Deploy","Docs","CDN"],
        "jobs":[
          { "name":"compile", "needs":["lint","compile"] },
          { "name":"package", "needs":[] },
          { "name":"publish", "needs":["package"] },
          { "name":"e2e",     "needs":["unit"] }
        ]
      },
      {
        "name":"Test",
        "needs":["Analytics"],
        "jobs":[
          { "name":"unit",        "needs":[] },
          { "name":"integration", "needs":["unit"] },
          { "name":"alpha",       "needs":["beta"] },
          { "name":"beta",        "needs":["alpha"] },
          { "name":"flaky",       "needs":["unknown"] }
        ]
      },
      {
        "name":"Deploy",
        "jobs":[
          { "name":"package", "needs":[] },
          { "name":"package", "needs":[] },
          { "name":"stage",   "needs":["approve"] },
          { "name":"approve", "needs":["stage"] },
          { "name":"rollout", "needs":["stage"] }
        ]
      },
      {
        "name":"Docs",
        "jobs":[
          { "name":"build", "needs":["lint"] },
          { "name":"lint",  "needs":[] }
        ]
      },
      { "name":"A", "needs":["B"], "jobs":[] },
      { "name":"B", "needs":["C"], "jobs":[] },
      { "name":"C", "needs":["A"], "jobs":[] },
      { "name":"Loop", "needs":["Loop"], "jobs":[] },

      { "name":"Build", "jobs":[] },

      { "name":"Ops", "needs":["Monitor","Security"], "jobs":[
        { "name":"audit",     "needs":[] },
        { "name":"hardening", "needs":["audit"] }
      ]},

      { "name":"Monitor", "jobs":[
        { "name":"heartbeat", "needs":[] },
        { "name":"alert",     "needs":["heartbeat"] }
      ]},

      { "name":"E", "needs":["F"], "jobs":[] },
      { "name":"F", "needs":["E"], "jobs":[] },

      { "name":"QA", "jobs":[
        { "name":"run",    "needs":[] },
        { "name":"run",    "needs":[] },
        { "name":"s1",     "needs":["s2"] },
        { "name":"s2",     "needs":["s3"] },
        { "name":"s3",     "needs":["s1"] },
        { "name":"report", "needs":["aggregate"] }
      ]},

      { "name":"Data", "needs":["Warehouse"], "jobs":[] },

      { "name":"Docs", "jobs":[] }
    ]
  }'

  it "in a complex graph, flags duplicated pipeline names (duplicate_pipeline_errors)"
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       duplicate_pipeline_errors | sort_by(.pipeline)'
  )"
  EXPECTED='[
    {"kind":"duplicate_pipeline","pipeline":"Build"},
    {"kind":"duplicate_pipeline","pipeline":"Docs"}
  ]'
  assert_json_eq \
    "$(printf '%s' "$EXPECTED" | jqw -c 'sort_by(.pipeline)')" \
    "$ACTUAL" \
    "complex scenario: duplicate_pipeline_errors"

  it "in a complex graph, flags duplicated job names per pipeline (duplicate_job_errors)"
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       duplicate_job_errors | sort_by(.pipeline, .job)'
  )"
  EXPECTED='[
    {"kind":"duplicate_job","pipeline":"Deploy","job":"package"},
    {"kind":"duplicate_job","pipeline":"QA","job":"run"}
  ]'
  assert_json_eq \
    "$(printf '%s' "$EXPECTED" | jqw -c 'sort_by(.pipeline,.job)')" \
    "$ACTUAL" \
    "complex scenario: duplicate_job_errors"

  it "in a complex graph, reports all missing pipeline refs (missing_pipeline_errors)"
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       missing_pipeline_errors | sort_by(.pipeline, .missing)'
  )"
  EXPECTED='[
    {"kind":"missing_pipeline","pipeline":"Build","missing":"CDN"},
    {"kind":"missing_pipeline","pipeline":"Data","missing":"Warehouse"},
    {"kind":"missing_pipeline","pipeline":"Ops","missing":"Security"},
    {"kind":"missing_pipeline","pipeline":"Test","missing":"Analytics"}
  ]'
  assert_json_eq \
    "$(printf '%s' "$EXPECTED" | jqw -c 'sort_by(.pipeline,.missing)')" \
    "$ACTUAL" \
    "complex scenario: missing_pipeline_errors"

  it "in a complex graph, reports all missing job refs (missing_job_errors)"
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       missing_job_errors | sort_by(.pipeline, .job, .missing)'
  )"
  EXPECTED='[
    {"kind":"missing_job","pipeline":"Build","job":"compile","missing":"lint"},
    {"kind":"missing_job","pipeline":"Build","job":"e2e","missing":"unit"},
    {"kind":"missing_job","pipeline":"QA","job":"report","missing":"aggregate"},
    {"kind":"missing_job","pipeline":"Test","job":"flaky","missing":"unknown"}
  ]'
  assert_json_eq \
    "$(printf '%s' "$EXPECTED" | jqw -c 'sort_by(.pipeline,.job,.missing)')" \
    "$ACTUAL" \
    "complex scenario: missing_job_errors"

  it "in a complex graph, detects all pipeline cycles (cycle_pipeline_errors)"
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       cycle_pipeline_errors
       | sort_by(.cycle | map(@base64) | join("|"))'
  )"
  EXPECTED='[
    {"kind":"pipeline_cycle","cycle":["A","B","C"]},
    {"kind":"pipeline_cycle","cycle":["E","F"]},
    {"kind":"pipeline_cycle","cycle":["Loop"]}
  ]'
  assert_json_eq \
    "$(printf '%s' "$EXPECTED" | jqw -c 'sort_by(.cycle | map(@base64) | join("|"))')" \
    "$ACTUAL" \
    "complex scenario: cycle_pipeline_errors"

  it "in a complex graph, detects all job cycles (cycle_job_errors)"
  ACTUAL="$(
    jqw -nc \
      --argjson "config" "$JSON" \
      'include "lib/identifier_validation";
       cycle_job_errors
       | sort_by(.pipeline, (.cycle | map(@base64) | join("|")))'
  )"
  EXPECTED='[
    {"kind":"job_cycle","pipeline":"Build","cycle":["compile"]},
    {"kind":"job_cycle","pipeline":"Deploy","cycle":["approve","stage"]},
    {"kind":"job_cycle","pipeline":"QA","cycle":["s1","s2","s3"]},
    {"kind":"job_cycle","pipeline":"Test","cycle":["alpha","beta"]}
  ]'
  assert_json_eq \
    "$(printf '%s' "$EXPECTED" | jqw -c 'sort_by(.pipeline, (.cycle | map(@base64) | join("|")))')" \
    "$ACTUAL" \
    "complex scenario: cycle_job_errors"

  return $(( TEST_PARTS_FAILED > 0 ? 1 : 0 ))
}
