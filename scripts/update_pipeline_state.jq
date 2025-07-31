# SPDX-FileCopyrightText: 2025 Eric Löffler <eric.loeffler@opalia.systems>
# SPDX-License-Identifier: GPL-3.0-or-later

include "lib/common";

def pipeline_cfg: (
  $config.pipelines[] | select(.name == $pipeline_name)
);

def retries_count($old_status; $old_retries): (
  if $status == "pending" and $old_status != "success" then
    $old_retries + 1
  else
    $old_retries
  end
);

def workspace_dir($id): (
  pipeline_cfg.workspace_dir // ($default_ws_dir + "/" + $pipeline_name + "/" + ($id | tostring))
);

def repository: (
  if (pipeline_cfg | has("repository")) then
    {
      uri: pipeline_cfg.repository.uri,
      commit_hash: $commit_hash
    }
  else
    null
  end
);

$state
| .pipelines |= (
    if any(.[]; .name == $pipeline_name) then
      map(
        if .name == $pipeline_name then
          if $status == "pending" or ($status == "started" and .latest_execution.status != "pending") then
            {
              name: .name,
              latest_execution: {
                execution_id: (.latest_execution.execution_id + 1),
                timestamp: $timestamp,
                duration_ms: 0,
                status: $status,
                retries: retries_count(.latest_execution.status; .latest_execution.retries),
                workspace_dir: workspace_dir(.latest_execution.execution_id + 1),
                repository: repository,
                jobs: []
              },
              previous_executions: (
                if $keep_previous_executions then
                  [ .latest_execution ] + .previous_executions
                else
                  []
                end
              )
            }
          else
            {
              name: .name,
              latest_execution: {
                execution_id: .latest_execution.execution_id,
                timestamp: .latest_execution.timestamp,
                duration_ms: (($timestamp | to_millis) - (.latest_execution.timestamp | to_millis)),
                status: $status,
                retries: .latest_execution.retries,
                workspace_dir: .latest_execution.workspace_dir,
                repository: .latest_execution.repository,
                jobs: .latest_execution.jobs
              },
              previous_executions: (
                if $keep_previous_executions then
                  .previous_executions
                else
                  []
                end
              )
            }
          end
        else
          .
        end
      )
    else
      . + [
        {
          name: $pipeline_name,
          latest_execution: {
            execution_id: 1,
            timestamp: $timestamp,
            duration_ms: 0,
            status: $status,
            retries: 0,
            workspace_dir: workspace_dir(1),
            repository: repository,
            jobs: []
          },
          previous_executions: []
        }
      ]
    end
  )
