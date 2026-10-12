# Receipt identities are authoritative. Without a receipt, recognize only an
# unambiguous historical executable plus one complete relay operation.
def relay_commands($command): [$command+" hook guard",$command+" hook stop-failure",$command+" statusline"];
def is_relay($commands):
  (.command? // "") as $c |
  if $commands!=null then ($commands|index($c))!=null
  else ($c|test("^(?:(?:[^\\s;|&<>`$\\\\]|\\\\.)+/)?claude-relay (hook (guard|stop-failure)|statusline)$")) end;
def is_relay: is_relay(null);
def clean_groups($commands):
  map(if (.hooks?|type)=="array" then
    . as $group | [.hooks[] | select(is_relay($commands)|not)] as $kept |
    if ($kept|length)==0 and ($group.hooks|length)>0 then empty else .hooks=$kept end
  else . end);
def clean($commands):
  if (.hooks?|type)=="object" then .hooks |= with_entries(if (.value|type)=="array" then .value |= clean_groups($commands) else . end) else . end;
def install($command; $commands):
  clean($commands) |
  .hooks.UserPromptSubmit += [{hooks:[{type:"command",command:($command+" hook guard")}]}] |
  .hooks.PostToolUse += [{hooks:[{type:"command",command:($command+" hook guard")}]}] |
  .hooks.StopFailure += [{hooks:[{type:"command",command:($command+" hook stop-failure")}]}] |
  .statusLine=((.statusLine // {}) + {type:"command",command:($command+" statusline")} | del(.refreshInterval));
def install($command): install($command;null);
def receipt:
  {hadStatusLine:has("statusLine"),statusLine:.statusLine,hadHooks:has("hooks"),
   hookEvents:((.hooks // {})|keys)};
def uninstall($receipt; $wrapped):
  . as $before |
  clean($receipt.commands) |
  if (.statusLine? | is_relay($receipt.commands)) then
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
