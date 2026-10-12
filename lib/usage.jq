# Normalize only complete, numeric plan windows. No data remains distinct from 0.
def window($key; $now):
  .rate_limits[$key] as $w |
  if ($w|type)=="object" and ($w.used_percentage|type)=="number"
     and ($w.resets_at|type)=="number" and $w.used_percentage>=0
     and $w.used_percentage<=100 and $w.resets_at>=0 then
    {used_percentage:$w.used_percentage, resets_at:$w.resets_at,
     expired:($w.resets_at<=$now),
     effective:(if $w.resets_at<=$now then 0 else $w.used_percentage end)}
  else null end;
def measurement($unknown):
  now as $now |
  {five_hour:window("five_hour";$now),seven_day:window("seven_day";$now),
   captured_at:(if (.captured_at|type)=="number" then .captured_at else null end)} |
  . as $m | [.five_hour,.seven_day] | map(select(.!=null)) as $w |
  $m + {known:($w|length>0), score:(if ($w|length)==0 then $unknown else ($w|map(.effective)|max) end),
        trigger_reset:($w | sort_by(.effective) | reverse | .[0].resets_at // 0),
        age_seconds:(if $m.captured_at==null then null else [0,($now-$m.captured_at|floor)]|max end)};
