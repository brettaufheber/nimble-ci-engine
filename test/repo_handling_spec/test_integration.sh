#!/usr/bin/env bash

function setup_test_git_repos {

  export TEST_RESOURCES_DIR="$TEMP_DIR/test-resources"
  mkdir -p "$TEST_RESOURCES_DIR"

  local TEST_REPO_DIR="$TEST_RESOURCES_DIR/git-local-test.git"
  export TEST_REPO_URI="file://$TEST_REPO_DIR"
  local TEST_REPO_WORK_DIR="$TEST_RESOURCES_DIR/git-local-test"

  git init --bare --initial-branch=main "$TEST_REPO_DIR" >/dev/null
  git init --initial-branch=main "$TEST_REPO_WORK_DIR" >/dev/null

  git -C "$TEST_REPO_WORK_DIR" config user.email "test@example.local"
  git -C "$TEST_REPO_WORK_DIR" config user.name  "Test User"

  # commit #1
  echo "= local test repository" > "$TEST_REPO_WORK_DIR/README.adoc"
  git -C "$TEST_REPO_WORK_DIR" add "README.adoc"
  git -C "$TEST_REPO_WORK_DIR" commit -m "Initial commit" >/dev/null

  git -C "$TEST_REPO_WORK_DIR" remote add origin "$TEST_REPO_URI"
  git -C "$TEST_REPO_WORK_DIR" push --set-upstream origin main >/dev/null

  COMMIT1="$(git -C "$TEST_REPO_WORK_DIR" rev-parse HEAD)"

  # commit #2: add docs/ and src/
  mkdir -p "$TEST_REPO_WORK_DIR/docs" "$TEST_REPO_WORK_DIR/src"
  echo "docs content" > "$TEST_REPO_WORK_DIR/docs/info.txt"
  echo "app content"  > "$TEST_REPO_WORK_DIR/src/app.txt"
  git -C "$TEST_REPO_WORK_DIR" add docs/info.txt src/app.txt
  git -C "$TEST_REPO_WORK_DIR" commit -m "Add docs and src" >/dev/null
  git -C "$TEST_REPO_WORK_DIR" push >/dev/null

  COMMIT2="$(git -C "$TEST_REPO_WORK_DIR" rev-parse HEAD)"

  # add tag v1.0 on COMMIT1
  git -C "$TEST_REPO_WORK_DIR" tag -f v1.0 "$COMMIT1"
  git -C "$TEST_REPO_WORK_DIR" push -f --tags >/dev/null
}

function build_ci_config {

  export CI_CONFIG="$(
    jqw -n --arg 'uri' "$TEST_REPO_URI" \
      '
        {
          pipelines: [
            { name: "pipeline_main",
              repository: { uri: $uri, ref: "main" }
            },
            { name: "pipeline_sparse",
              repository: { uri: $uri, ref: "main", fetch_depth: 1, sparse_paths: ["docs"] }
            },
            { name: "pipeline_tag",
              repository: { uri: $uri, ref: "v1.0" }
            },
            { name: "pipeline_depth0",
              repository: { uri: $uri, ref: "main", fetch_depth: 0 }
            },
            { name: "pipeline_invalid_ref",
              repository: { uri: $uri, ref: "does-not-exist" }
            },
            { name: "pipeline_unreachable_with_last",
              repository: { uri: "file::///nonexistent/path/repo.git", ref: "main" }
            },
            { name: "pipeline_unreachable_no_last",
              repository: { uri: "file:///also/does/not/exist.git", ref: "main" }
            }
          ]
        }
      '
  )"
}

function test_spec {

  export TEST_DIR="$1"
  export TEST_NAME="$(basename "$TEST_DIR")"
  TEST_PARTS_FAILED=0

  set_env_defaults
  create_temp_dir

  STATE_FILE="$TEMP_DIR/state.json"

  setup_test_git_repos
  build_ci_config

  # 1) First run: no LAST_COMMIT_HASH → repository is cloned
  it "clones the repository and sets CURRENT_COMMIT_HASH when LAST_COMMIT_HASH is empty"
  PIPELINE_NAME="pipeline_main"
  CLONE_DIR="$(unique_clone_dir)"
  clear_state_hash
  unset_output_variables
  setup_git_repository "$PIPELINE_NAME" "$CLONE_DIR"
  assert_exists "$CLONE_DIR/.git" "repository should be cloned"
  assert_equals "$TEST_REPO_URI" "$BARE_REPO_URI" "BARE_REPO_URI is taken from CI_CONFIG"
  assert_equals "main" "$REPO_REF" "REPO_REF is taken from CI_CONFIG"
  HEAD="$(git -C "$CLONE_DIR" rev-parse HEAD)"
  assert_equals "$COMMIT2" "$HEAD" "HEAD points to latest commit"
  assert_equals "$COMMIT2" "$CURRENT_COMMIT_HASH" "CURRENT_COMMIT_HASH equals latest commit"
  assert_equals "" "$LAST_COMMIT_HASH" "LAST_COMMIT_HASH remains unset"

  # 2) LAST_COMMIT_HASH equals remote → early return, no clone
  it "skips cloning (early return) when LAST_COMMIT_HASH equals the remote HEAD"
  PIPELINE_NAME="pipeline_main"
  CLONE_DIR="$(unique_clone_dir)"
  clear_state_hash
  set_state_hash "$PIPELINE_NAME" "$COMMIT2"
  unset_output_variables
  setup_git_repository "$PIPELINE_NAME" "$CLONE_DIR"
  assert_not_exists "$CLONE_DIR" "no clone directory should be created on early return"
  assert_equals "$TEST_REPO_URI" "$BARE_REPO_URI" "BARE_REPO_URI is set"
  assert_equals "main" "$REPO_REF" "REPO_REF is set"
  assert_equals "$COMMIT2" "$CURRENT_COMMIT_HASH" "CURRENT_COMMIT_HASH updated to latest"
  assert_equals "$COMMIT2" "$LAST_COMMIT_HASH" "LAST_COMMIT_HASH is the latest"
  assert_equals "$LAST_COMMIT_HASH" "$CURRENT_COMMIT_HASH" "LAST and CURRENT hashes must match"

  # 3) LAST_COMMIT_HASH differs → repository is cloned
  it "clones the repository when LAST_COMMIT_HASH differs from the remote HEAD"
  PIPELINE_NAME="pipeline_main"
  CLONE_DIR="$(unique_clone_dir)"
  clear_state_hash
  set_state_hash "$PIPELINE_NAME" "$COMMIT1"
  unset_output_variables
  setup_git_repository "$PIPELINE_NAME" "$CLONE_DIR"
  assert_exists "$CLONE_DIR/.git" "repository should be cloned"
  HEAD="$(git -C "$CLONE_DIR" rev-parse HEAD)"
  assert_equals "$COMMIT2" "$HEAD" "HEAD points to latest commit after clone"
  assert_equals "$COMMIT2" "$CURRENT_COMMIT_HASH" "CURRENT_COMMIT_HASH updated to latest"
  assert_equals "$COMMIT1" "$LAST_COMMIT_HASH" "LAST_COMMIT_HASH reflects previous state"
  assert_not_equals "$LAST_COMMIT_HASH" "$CURRENT_COMMIT_HASH" "LAST and CURRENT hashes should differ"

  # 4) Shallow + sparse: fetch_depth > 0 and sparse_paths set
  it "performs a shallow, sparse clone when fetch_depth>0 and sparse_paths are configured"
  PIPELINE_NAME="pipeline_sparse"
  CLONE_DIR="$(unique_clone_dir)"
  clear_state_hash
  set_state_hash "$PIPELINE_NAME" "$COMMIT1"
  unset_output_variables
  setup_git_repository "$PIPELINE_NAME" "$CLONE_DIR"
  assert_exists "$CLONE_DIR/.git" "repository should be cloned"
  assert_exists "$CLONE_DIR/.git/shallow" "shallow clone indicator exists (.git/shallow)"
  assert_exists "$CLONE_DIR/docs/info.txt" "sparse checkout includes docs/"
  assert_not_exists "$CLONE_DIR/src/app.txt" "sparse checkout excludes src/"
  HEAD="$(git -C "$CLONE_DIR" rev-parse HEAD)"
  assert_equals "$COMMIT2" "$HEAD" "HEAD points to latest commit after clone"
  assert_equals "$COMMIT2" "$CURRENT_COMMIT_HASH" "CURRENT_COMMIT_HASH updated to latest"
  assert_equals "$COMMIT1" "$LAST_COMMIT_HASH" "LAST_COMMIT_HASH reflects previous state"
  assert_not_equals "$LAST_COMMIT_HASH" "$CURRENT_COMMIT_HASH" "LAST and CURRENT hashes should differ"

  # 5) Tag ref with no LAST_COMMIT_HASH → clone succeeds (detached HEAD)
  it "clones successfully when the ref is a tag (detached HEAD)"
  PIPELINE_NAME="pipeline_tag"
  CLONE_DIR="$(unique_clone_dir)"
  clear_state_hash
  unset_output_variables
  setup_git_repository "$PIPELINE_NAME" "$CLONE_DIR"
  assert_exists "$CLONE_DIR/.git" "repository is cloned from tag ref"
  HEAD="$(git -C "$CLONE_DIR" rev-parse HEAD)"
  assert_equals "$COMMIT1" "$HEAD" "HEAD equals the tag's commit"
  assert_equals "$COMMIT1" "$CURRENT_COMMIT_HASH" "CURRENT_COMMIT_HASH equals tag commit"
  assert_equals "" "$LAST_COMMIT_HASH" "LAST_COMMIT_HASH remains unset"

  # 6) fetch_depth == 0 → full clone (no .git/shallow)
  it "does a full (non-shallow) clone when fetch_depth is 0"
  PIPELINE_NAME="pipeline_depth0"
  CLONE_DIR="$(unique_clone_dir)"
  clear_state_hash
  set_state_hash "$PIPELINE_NAME" "$COMMIT1"
  unset_output_variables
  setup_git_repository "$PIPELINE_NAME" "$CLONE_DIR"
  assert_exists "$CLONE_DIR/.git" "repository should be cloned"
  assert_not_exists "$CLONE_DIR/.git/shallow" "no shallow indicator when fetch_depth=0"

  # 7) Invalid ref → clone must fail with exit code 7
  it "exits with code 7 when the ref does not exist during clone"
  PIPELINE_NAME="pipeline_invalid_ref"
  CLONE_DIR="$(unique_clone_dir)"
  clear_state_hash
  set_state_hash "$PIPELINE_NAME" "$COMMIT1"
  unset_output_variables
  expect_exit_code 6 -- setup_git_repository "$PIPELINE_NAME" "$CLONE_DIR"
  assert_not_exists "$CLONE_DIR" "no clone directory should be created on failure"

  # 8) Unreachable repo + LAST_COMMIT_HASH set → ls-remote fails → exit 7
  it "exits with code 7 when ls-remote cannot reach the repository and LAST_COMMIT_HASH is set"
  PIPELINE_NAME="pipeline_unreachable_with_last"
  CLONE_DIR="$(unique_clone_dir)"
  clear_state_hash
  set_state_hash "$PIPELINE_NAME" "$COMMIT1"
  unset_output_variables
  expect_exit_code 6 -- setup_git_repository "$PIPELINE_NAME" "$CLONE_DIR"
  assert_not_exists "$CLONE_DIR" "no clone directory should be created when ls-remote fails"

  # 9) Unreachable repo + LAST_COMMIT_HASH empty → clone fails → exit 7
  it "exits with code 7 when the repository is unreachable and LAST_COMMIT_HASH is empty"
  PIPELINE_NAME="pipeline_unreachable_no_last"
  CLONE_DIR="$(unique_clone_dir)"
  clear_state_hash
  unset_output_variables
  expect_exit_code 6 -- setup_git_repository "$PIPELINE_NAME" "$CLONE_DIR"
  assert_not_exists "$CLONE_DIR" "no clone directory should be created for unreachable repo"

  return $(( TEST_PARTS_FAILED > 0 ? 1 : 0 ))
}

function set_state_hash {

  local PIPELINE_NAME
  local COMMIT_HASH

  PIPELINE_NAME="$1"
  COMMIT_HASH="$2"

  jqw -n --arg 'p' "$PIPELINE_NAME" --arg 'h' "$COMMIT_HASH" \
    '{ pipelines: [{name: $p, latest_execution: { repository: { commit_hash: $h }}}]}' \
    > "$TEMP_DIR/state.json"
}

function clear_state_hash {

  echo '{ "pipelines": [] }' > "$TEMP_DIR/state.json"
}

function unset_output_variables {

  unset BARE_REPO_URI REPO_REF LAST_COMMIT_HASH CURRENT_COMMIT_HASH
}

function unique_clone_dir {

  mktemp --dry-run "$TEMP_DIR/repo-XXXXXXXX"
}
