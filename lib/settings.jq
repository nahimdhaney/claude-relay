def is_relay: (.command? // "" | contains("claude-relay"));
def clean_groups:
  map(if (.hooks?|type)=="array" then
    . as $group | [.hooks[] | select(is_relay|not)] as $kept |
    if ($kept|length)==0 and ($group.hooks|length)>0 then empty else .hooks=$kept end
  else . end);
def clean:
  if (.hooks?|type)=="object" then .hooks |= with_entries(if (.value|type)=="array" then .value |= clean_groups else . end) else . end;
def install($command):
  clean |
  .hooks.UserPromptSubmit += [{hooks:[{type:"command",command:($command+" hook guard")}]}] |
  .hooks.PostToolUse += [{hooks:[{type:"command",command:($command+" hook guard")}]}] |
  .hooks.StopFailure += [{hooks:[{type:"command",command:($command+" hook stop-failure")}]}] |
  .statusLine={type:"command",command:($command+" statusline")};
def receipt:
  {hadStatusLine:has("statusLine"),statusLine:.statusLine,hadHooks:has("hooks"),
   hookEvents:((.hooks // {})|keys)};
def uninstall($receipt; $wrapped):
  . as $before |
  clean |
  if (.statusLine? | is_relay) then
    if $receipt!=null and $receipt.hadStatusLine then .statusLine=$receipt.statusLine
    elif $receipt==null and $wrapped!="" then .statusLine={type:"command",command:$wrapped}
    else del(.statusLine) end
  else . end |
  if (.hooks?|type)=="object" then
    .hooks |= with_entries(select((.value!=[]) or
      (.key as $key | ($receipt.hookEvents // []) | index($key)) != null or
      (.key as $key | $before.hooks[$key]==[])))
  else . end |
  if .hooks=={} and ($receipt.hadHooks // false | not) then del(.hooks) else . end;
