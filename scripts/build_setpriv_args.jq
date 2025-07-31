# SPDX-FileCopyrightText: 2025 Eric Löffler <eric.loeffler@opalia.systems>
# SPDX-License-Identifier: GPL-3.0-or-later

include "lib/common";

def parse_passwd: (
  $passwd
  | split("\n")
  | map(
      .
      | trim
      | select(length > 0 and .[0:1] != "#")
      | split(":")
      | {
          name: .[0],
          uid: (.[2] | tonumber),
          gid: (.[3] | tonumber)
        }
    )
);

def parse_group: (
  $group
  | split("\n")
  | map(
      .
      | trim
      | select(length > 0 and .[0:1] != "#")
      | split(":")
      | {
          name: .[0],
          gid: (.[2] | tonumber)
        }
    )
);

def find_by_passwd($list; $name_or_uid): (
  $list
  | map(select(
      if ($name_or_uid | type) == "number" then
        .uid == $name_or_uid
      else
        .name == $name_or_uid
      end
    ))
  | first // error("Error: User not found: " + ($name_or_uid | tostring))
);

def find_by_group($list; $name_or_gid): (
  $list
  | map(select(
      if ($name_or_gid | type) == "number" then
        .gid == $name_or_gid
      else
        .name == $name_or_gid
      end
    ))
  | first // error("Error: Group not found: " + ($name_or_gid | tostring))
);

def user_default: $schema.definitions.runAsRule.properties.user.default;
def group_default: $schema.definitions.runAsRule.properties.group.default;
def supplementary_groups_default: $schema.definitions.runAsRule.properties.supplementary_groups.default;
def allow_privilege_escalation_default: $schema.definitions.runAsRule.properties.allow_privilege_escalation.default;

$config
.pipelines[]
| select(.name == $pipeline_name)
| .jobs[]
| select(.name == $job_name)
| .restrictions.run_as // {}
| {
    user: default("user"; user_default),
    group: default("group"; group_default),
    supplementary_groups: default("supplementary_groups"; supplementary_groups_default),
    allow_privilege_escalation: default("allow_privilege_escalation"; allow_privilege_escalation_default)
  }
| parse_passwd as $passwd_list
| parse_group as $group_list
| . + {
    gid: (
      if .group == null and .user != null then
        find_by_passwd($passwd_list; .user).gid
      elif .group == null then
        $default_gid | tonumber
      else
        find_by_group($group_list; .group).gid
      end)
  }
| . + {
    uid: (
      if .user == null then
        $default_uid | tonumber
      else
        find_by_passwd($passwd_list; .user).uid
      end
    )
  }
| . + {
    supplementary_groups: (
      if .supplementary_groups == null then
        .supplementary_groups
      else
        .supplementary_groups | map(find_by_group($group_list; .).gid)
      end
    )
  }
| . as $run_as
| (
    [ "--reuid", (.uid | tostring), "--regid", (.gid | tostring) ]
  ) + (
    if $run_as.supplementary_groups == null then
      [ "--init-groups" ]
    elif ($run_as.supplementary_groups | length) > 0 then
      [ "--groups", ($run_as.supplementary_groups | map(tostring) | join(",")) ]
    else
      []
    end
  ) + (
    if ($run_as.allow_privilege_escalation | not) then
      [ "--no-new-privs" ]
    else
      []
    end
  )
