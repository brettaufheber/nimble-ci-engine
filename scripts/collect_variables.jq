# SPDX-FileCopyrightText: 2025 Eric Löffler <eric.loeffler@opalia.systems>
# SPDX-License-Identifier: GPL-3.0-or-later

def pn: ($ARGS.named.pipeline_name // null);
def jn: ($ARGS.named.job_name // null);

(
  $config.variables // {}
) + (
  if pn != null then
    $config.pipelines[]
    | select(.name == pn)
    | .variables // {}
  else
    {}
  end
) + (
  if pn != null and jn != null then
    $config.pipelines[]
    | select(.name == pn)
    | .jobs[]
    | select(.name == jn)
    | .variables // {}
  else
    {}
  end
) + (
  if pn != null then
    ($state.pipelines[] | select(.name == pn)) as $pipeline
    | (
        {
          CI_WORKSPACE_DIR: $pipeline.latest_execution.workspace_dir,
          CI_PIPELINE_NAME: $pipeline.name,
          CI_PIPELINE_EXECUTION_ID: $pipeline.latest_execution.execution_id,
          CI_PIPELINE_TIMESTAMP: $pipeline.latest_execution.timestamp,
          CI_PIPELINE_STATUS: $pipeline.latest_execution.status,
          CI_PIPELINE_RETRIES: $pipeline.latest_execution.retries
        }
      ) + (
        if ($pipeline.latest_execution.repository // null) != null then
          {
            CI_REPO_URI: $pipeline.latest_execution.repository.uri,
            CI_REPO_COMMIT_HASH: $pipeline.latest_execution.repository.commit_hash
          }
        else
          {}
        end
      )
  else
    {}
  end
) + (
  if pn != null then
    ($config.pipelines[] | select(.name == pn)) as $pipeline_cfg
    | if ($pipeline_cfg.repository // null) != null then
        {
          CI_REPO_REF: $pipeline_cfg.repository.ref
        }
      else
        {}
      end
  else
    {}
  end
) + (
  if pn != null and jn != null then
    ($state.pipelines[] | select(.name == pn) | .latest_execution.jobs[] | select(.name == jn)) as $job
    | {
        CI_JOB_NAME: $job.name,
        CI_JOB_TIMESTAMP: $job.latest_attempt.timestamp,
        CI_JOB_STATUS: $job.latest_attempt.status
      }
  else
    {}
  end
)
