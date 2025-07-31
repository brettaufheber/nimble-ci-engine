# SPDX-FileCopyrightText: 2025 Eric Löffler <eric.loeffler@opalia.systems>
# SPDX-License-Identifier: GPL-3.0-or-later

def doc: .;

def pipeline_index: (
  ($path | index("pipelines")) as $index
  | if $index == null then
      null
    else
      $path[$index+1]
    end
);

def job_index: (
  ($path | index("jobs")) as $index
  | if $index == null then
      null
    else
      $path[$index+1]
    end
);

def global_vars: (
  doc.variables? // {}
);

def pipeline_vars: (
  if pipeline_index != null then
    doc.pipelines?
    | .[pipeline_index]?
    | .variables? // {}
  else
    {}
  end
);

def job_vars: (
  if pipeline_index != null and job_index != null then
    doc.pipelines?
    | .[pipeline_index]?
    | .jobs?
    | .[job_index]?
    | .variables? // {}
  else
    {}
  end
);

global_vars + pipeline_vars + job_vars
