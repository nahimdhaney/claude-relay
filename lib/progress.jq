# Progress lines for forward: one line per tool call in a stream-json
# assistant event. Only the tool name and one short detail leave the stream,
# never tool results, file contents or assistant text.
# Tabs and line breaks become spaces; other C0/C1 controls and DEL are removed.
def progress_clean:
  gsub("[\t\n\r\u000b\u000c]"; " ") | gsub("[\u0000-\u001f\u007f-\u009f]"; "")
  | gsub(" +"; " ") | sub("^ "; "") | sub(" $"; "");
# Paths under forward's directory (resolved or as typed) become relative.
def progress_relative($cwd; $pwd):
  reduce ($cwd, $pwd) as $d (.;
    if $d == "" or $d == "/" then .
    elif . == $d then "."
    elif startswith($d + "/") then .[($d|length)+1:]
    else . end);
def progress_lines($cwd; $pwd):
  select(type=="object" and .type=="assistant" and (.message|type)=="object"
    and (.message.content|type)=="array")
  | .message.content[]
  | select(type=="object" and .type=="tool_use" and (.name|type)=="string")
  | (.input | if type=="object" then . else {} end) as $in
  | (.name[:200] | progress_clean) as $name
  | select($name != "")
  | ([($in.file_path | strings | progress_relative($cwd; $pwd)),
      ($in.path | strings | progress_relative($cwd; $pwd)),
      ($in.pattern | strings), ($in.url | strings), ($in.description | strings),
      ($in.command | strings | sub("^\\s+"; "") | split("\n")[0])]
     | map(.[:500] | progress_clean | select(. != "")) | .[0] // "") as $detail
  | "  · " + $name + (if $detail == "" then "" else " " + $detail end)
  | if length > 120 then .[:119] + "…" else . end;
