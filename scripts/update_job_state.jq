# SPDX-FileCopyrightText: 2025 Eric Löffler <eric.loeffler@opalia.systems>
# SPDX-License-Identifier: GPL-3.0-or-later

include "lib/common";

def normalized_exit_code: (
  if $exit_code == "" then
    null
  else
    ($exit_code | tonumber)
  end
);

def log_file($id): (
  $log_dir +
    "/" + $pipeline_name +
    "/" + ($id | tostring) +
    "/" + ($job_name + ".log")
);

$state
| .pipelines |= map(
    if .name == $pipeline_name then
      (.latest_execution.execution_id) as $execution_id
      | .latest_execution["jobs"] |= (
        if any(.[]; .name == $job_name) then
          map(
            if .name == $job_name then
              if $status == "pending" or ($status == "started" and .latest_attempt.status != "pending") then
                {
                  name: .name,
                  latest_attempt: {
                    timestamp: $timestamp,
                    duration_ms: 0,
                    status: $status,
                    exit_code: normalized_exit_code
                  },
                  previous_attempts: ([ .latest_attempt ] + .previous_attempts),
                  log_file: .log_file
                }
              else
                {
                  name: .name,
                  latest_attempt: {
                    timestamp: .latest_attempt.timestamp,
                    duration_ms: (($timestamp | to_millis) - (.latest_attempt.timestamp | to_millis)),
                    status: $status,
                    exit_code: normalized_exit_code
                  },
                  previous_attempts: .previous_attempts,
                  log_file: .log_file
                }
              end
            else
              .
            end
          )
        else
          . + [
            {
              name: $job_name,
              latest_attempt: {
                timestamp: $timestamp,
                duration_ms: 0,
                status: $status,
                exit_code: normalized_exit_code
              },
              previous_attempts: [],
              log_file: log_file($execution_id)
            }
          ]
        end
      )
    else
      .
    end
  )
