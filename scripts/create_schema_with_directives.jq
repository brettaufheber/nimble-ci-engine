# SPDX-FileCopyrightText: 2025 Eric Löffler <eric.loeffler@opalia.systems>
# SPDX-License-Identifier: GPL-3.0-or-later

def directive_ref: { "$ref": $directive_ref };

def has_primitive_type: (
  has("type") and (
    .type
    | if type == "string" then
        IN("string", "integer", "number", "boolean", "null")
      elif type == "array" then
        (all(.[]; IN("string", "integer", "number", "boolean", "null")))
      else
        false
      end
  )
);

def is_atomic_schema: (
  has_primitive_type
  or (has("oneOf") and all(.oneOf[]; is_atomic_schema))
  or (has("anyOf") and all(.anyOf[]; is_atomic_schema))
  or (has("allOf") and any(.allOf[]; is_atomic_schema))
  or (has("type") and .type == "array" and (
    (.items? | type) as $t
    | ($t == "null")
        or ($t == "object" and (.items | is_atomic_schema))
        or ($t == "array" and all(.items[]; is_atomic_schema))
  ))
);

def transform($suppress): (
  if type != "object" then
    .
  else
    . as $o
    | if has("const") then
        $o
      elif has("oneOf") then
        if ($o | is_atomic_schema) and ($suppress | not) then
          ($o | .oneOf += [ directive_ref ]) | .oneOf |= map(transform(true))
        else
          $o | .oneOf |= map(transform(false))
        end
        | with_entries( if .key == "oneOf" then . else .value |= transform(false) end )
      elif has("anyOf") then
        if ($o | is_atomic_schema) and ($suppress | not) then
          ($o | .anyOf += [ directive_ref ]) | .anyOf |= map(transform(true))
        else
          $o | .anyOf |= map(transform(false))
        end
        | with_entries( if .key == "anyOf" then . else .value |= transform(false) end )
      elif has("allOf") then
        if ($o | is_atomic_schema) then
          if ($suppress | not) then
            { oneOf: [ $o, directive_ref ] }
          else
            $o
          end
        else
          $o
          | .allOf |= map(transform(false))
          | with_entries( if .key == "allOf" then . else .value |= transform(false) end )
        end
      elif has("type") and .type == "array" then
        if ($o | is_atomic_schema) and ($suppress | not) then
          $o
          | .items |= (if type == "array" then map(transform(false)) else transform(false) end)
          | { oneOf: [ ., directive_ref ] }
        else
          $o
          | .items |= (if type == "array" then map(transform(false)) else transform(false) end)
          | with_entries( if (.key == "items" or .key == "type") then . else .value |= transform(false) end )
        end
      elif ($o | is_atomic_schema) and ($suppress | not) then
        { oneOf: [ $o, directive_ref ] }
      else
        $o | with_entries(.value |= transform(false))
      end
  end
);

transform(false)
