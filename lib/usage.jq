# Normalize only complete, numeric plan windows. No data remains distinct from 0.
def valid_window($key):
  .rate_limits[$key] as $w |
  if ($w|type)=="object" and ($w.used_percentage|type)=="number"
     and ($w.resets_at|type)=="number" and $w.used_percentage>=0
     and $w.used_percentage<=100 and $w.resets_at>=0 then $w
  else null end;
def window($key; $now):
  valid_window($key) as $w |
  if $w!=null and $w.resets_at>$now then
    {used_percentage:$w.used_percentage, resets_at:$w.resets_at,
     expired:false, effective:$w.used_percentage,
     session_id:(.session_id // null), model:(.model // null)}
  else null end;
def selected_window($key; $now):
  map(window($key;$now) | select(.!=null)) |
  max_by([.resets_at,.used_percentage]);
def measurements($unknown; $max_age):
  now as $now |
  ($max_age|tonumber) as $max_age |
  if $max_age>0 and $max_age==($max_age|floor) then . else error("Invalid capture_max_age") end |
  map(select(type=="object" and (.captured_at|type)=="number")) |
  sort_by([.captured_at,.session_id]) as $all |
  [$all[] | select(.captured_at >= $now-$max_age)] as $fresh |
  [$fresh[] | select(window("five_hour";$now)!=null)] as $current |
  (if ($current|length)>0 then $current
   elif ($fresh|length)>0 then $fresh else $all[-1:] end) as $captures |
  {five_hour:($captures|selected_window("five_hour";$now)),
   seven_day:($captures|selected_window("seven_day";$now)),
   capture_count:($captures|length), captured_at:($captures|map(.captured_at)|max)} |
  . as $m | [.five_hour,.seven_day] | map(select(.!=null)) as $w |
  $m + {known:($w|length>0), score:(if ($w|length)==0 then $unknown else ($w|map(.effective)|max) end),
        trigger_reset:($w | sort_by(.effective) | reverse | .[0].resets_at // 0),
        age_seconds:(if $m.captured_at==null then null else [0,($now-$m.captured_at|floor)]|max end)};
def measurement($unknown): [.] | measurements($unknown;21600);
