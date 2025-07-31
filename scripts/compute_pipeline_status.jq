# SPDX-FileCopyrightText: 2025 Eric Löffler <eric.loeffler@opalia.systems>
# SPDX-License-Identifier: GPL-3.0-or-later

(
  $state.pipelines[]
  | select(.name == $pipeline_name)
  | .latest_execution.jobs
  | map(.latest_attempt.status)
) as $job_status_list
| if ($job_status_list | length) == 0 then
    "Error: Missing jobs in pipeline \($pipeline_name)" | error
  elif $job_status_list | any(.[]; (. == "pending") or (. == "started")) then
    "Error: Invalid final job state detected in pipeline \($pipeline_name)" | error
  elif $job_status_list | any(.[]; . == "failure") then
    "failure"
  elif $job_status_list | any(.[]; . == "timeout") then
    "timeout"
  elif $job_status_list | all(.[]; . == "skipped") then
    "skipped"
  else
    "success"
  end
