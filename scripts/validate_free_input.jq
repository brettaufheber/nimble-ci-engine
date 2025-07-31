$schema.definitions.freeInput as $freeInput
| if type != "string" then
    "Error: Validation failed for free input: expect string type" | error
  elif length > $freeInput.maxLength then
    "Error: Validation failed for free input: length \(length) > max \($freeInput.maxLength) code points" | error
  elif test($freeInput.pattern; "p") | not then
    "Error: Validation failed for free input: does not match pattern:\n($freeInput.pattern)" | error
  else
    .
  end
