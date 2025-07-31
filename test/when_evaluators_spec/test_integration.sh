#!/usr/bin/env bash

function test_spec {

  export TEST_DIR="$1"
  export TEST_NAME="$(basename "$TEST_DIR")"
  TEST_PARTS_FAILED=0

  setup_signal_handling
  set_env_defaults
  create_temp_dir

  # —————————————————————————
  # calendar_cron.py
  # —————————————————————————

  # C1) TZ matrix: UTC-aware base, evaluated in America/Los_Angeles (inclusive) → core 10:00 PDT same Monday → 17:00Z
  it "should process cron; (TZ matrix: UTC base evaluated in America/Los_Angeles) tz=America/Los_Angeles, base_tz=UTC, jitter=0"
  call 'calendar.cron' '*/15 10 * * MON-FRI 0' '2025-03-31T08:07:00Z' 'America/Los_Angeles' '0s'
  EXPECTED="$(date -u -d '2025-03-31T17:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # C2) TZ matrix: UTC-aware base, evaluated in Europe/Berlin; base 10:07 CEST → next */15 tick 10:15 CEST → 08:15Z
  it "should process cron; (TZ matrix: UTC base evaluated in Europe/Berlin) tz=Europe/Berlin, base_tz=UTC, jitter=0"
  call 'calendar.cron' '*/15 10 * * MON-FRI 0' '2025-03-31T08:07:00Z' 'Europe/Berlin' '0s'
  EXPECTED="$(date -u -d '2025-03-31T08:15:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # C3) TZ matrix: naive base interpreted in Europe/Berlin; base 08:07 local → first 10:00 CEST → 08:00Z
  it "should process cron; (TZ matrix: naive base interpreted in Europe/Berlin) tz=Europe/Berlin, base_tz=null, jitter=0"
  call 'calendar.cron' '*/15 10 * * MON-FRI 0' '2025-03-31T08:07:00' 'Europe/Berlin' '0s'
  EXPECTED="$(date -u -d '2025-03-31T08:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # C4) TZ matrix: tz=null means UTC; UTC-aware base → next */15 at 10:00Z
  it "should process cron; (tz=null means UTC; aware base) tz=null (UTC), base_tz=UTC, jitter=0"
  call 'calendar.cron' '*/15 10 * * MON-FRI 0' '2025-03-31T08:07:00Z' 'null' '0s'
  EXPECTED="$(date -u -d '2025-03-31T10:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # C5) TZ matrix: tz=null (UTC) with naive base (interpreted as UTC) → next */15 at 10:00Z
  it "should process cron; (tz=null means UTC; naive base interpreted as UTC) tz=null (UTC), base_tz=null, jitter=0"
  call 'calendar.cron' '*/15 10 * * MON-FRI 0' '2025-03-31T08:07:00' 'null' '0s'
  EXPECTED="$(date -u -d '2025-03-31T10:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # C6) TZ matrix: aware base +02:00, evaluated in America/Los_Angeles; next 10:00 PDT → 17:00Z
  it "should process cron; (TZ matrix: aware base +02:00 evaluated in America/Los_Angeles) tz=America/Los_Angeles, base_offset=+02:00, jitter=0"
  call 'calendar.cron' '*/15 10 * * MON-FRI 0' '2025-03-31T10:07:00+02:00' 'America/Los_Angeles' '0s'
  EXPECTED="$(date -u -d '2025-03-31T17:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # C7) TZ matrix: aware base −05:00, evaluated in Europe/Berlin; next business day 10:00 CEST → 08:00Z (2025-04-01)
  it "should process cron; (TZ matrix: aware base −05:00 evaluated in Europe/Berlin) tz=Europe/Berlin, base_offset=-05:00, jitter=0"
  call 'calendar.cron' '*/15 10 * * MON-FRI 0' '2025-03-31T10:07:00-05:00' 'Europe/Berlin' '0s'
  EXPECTED="$(date -u -d '2025-04-01T08:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # C8) Leap day in Europe/Berlin; next 2028-02-29 00:00 CET → 2028-02-28 23:00Z
  it "should process cron; (leap day) tz=Europe/Berlin, base_tz=UTC, jitter=0"
  call 'calendar.cron' '0 0 29 2 * 0' '2025-03-01T00:00:00Z' 'Europe/Berlin' '0s'
  EXPECTED="$(date -u -d '2028-02-28T23:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # C9) Jitter window in UTC with */5 rule; base 08:07Z → core 08:10Z
  it "should process cron; (jitter window with */5) tz=null (UTC), base_tz=UTC, jitter=1h"
  call 'calendar.cron' '*/5 * * * * 0' '2025-03-31T08:07:00Z' 'null' '1h'
  EXPECTED="$(date -u -d '2025-03-31T08:10:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # C10) Cron edge: base exactly on slot (inclusive wrapper advances) → next 10:15:00Z
  it "should process cron; (cron edge: base exactly on slot → next slot) tz=UTC, base_tz=UTC, jitter=0"
  call 'calendar.cron' '*/15 10 * * MON-FRI 0' '2025-03-31T10:00:00Z' 'UTC' '0s'
  EXPECTED="$(date -u -d '2025-03-31T10:15:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # C11) Cron edge: after last 10h slot on Friday → roll to Monday 10:00:00 UTC
  it "should process cron; (cron edge: Friday after 10:45 rolls to Monday 10:00) tz=UTC, base_tz=UTC, jitter=0"
  call 'calendar.cron' '*/15 10 * * MON-FRI 0' '2025-04-04T10:46:00Z' 'UTC' '0s'
  EXPECTED="$(date -u -d '2025-04-07T10:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # C12) Cron OR semantics (DOM vs DOW); after 10:01 on the 1st → next Monday 10:00:00Z
  it "should process cron; (cron OR: DOM vs DOW) tz=UTC, base_tz=UTC, jitter=0"
  call 'calendar.cron' '0 10 1 * MON 0' '2025-04-01T10:01:00Z' 'UTC' '0s'
  EXPECTED="$(date -u -d '2025-04-07T10:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # —————————————————————————
  # calendar_rrule.py
  # —————————————————————————

  # R1) Base exactly on an occurrence in UTC (inclusive) — returns the same instant
  it "should process rrule; (inclusive: base equals occurrence) tz=UTC, base_tz=UTC, jitter=0"
  call 'calendar.rrule' 'FREQ=WEEKLY;BYDAY=MO,WE,FR' '2025-03-31T08:00:00Z' 'UTC' '0s'
  EXPECTED="$(date -u -d '2025-03-31T08:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # R2) Same as (R1), evaluated in Europe/Berlin with jitter; base 08:00Z == 10:00 Berlin
  it "should process rrule; (inclusive at Berlin wall time) tz=Europe/Berlin, base_tz=UTC, jitter=30s"
  call 'calendar.rrule' 'FREQ=WEEKLY;BYDAY=MO,WE,FR' '2025-03-31T08:00:00Z' 'Europe/Berlin' '30s'
  EXPECTED="$(date -u -d '2025-03-31T08:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # R3) Naive base interpreted in Europe/Berlin; 10:00 CEST corresponds to 08:00Z
  it "should process rrule; (inclusive with naive base) tz=Europe/Berlin, base_tz=null, jitter=0"
  call 'calendar.rrule' 'FREQ=WEEKLY;BYDAY=MO,WE,FR' '2025-03-31T10:00:00' 'Europe/Berlin' '0s'
  EXPECTED="$(date -u -d '2025-03-31T08:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # R4) UTC base equals 09:30 Berlin; next fixed slot is 10:00 Berlin → 08:00Z
  it "should process rrule; (fixed 10:00 local next) tz=Europe/Berlin, base_tz=UTC, jitter=0"
  call 'calendar.rrule' 'FREQ=WEEKLY;BYDAY=MO,WE,FR;BYHOUR=10;BYMINUTE=0;BYSECOND=0' '2025-03-31T07:30:00Z' 'Europe/Berlin' '0s'
  EXPECTED="$(date -u -d '2025-03-31T08:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # R5) tz=null means UTC; base is already UTC at 08:00Z (Monday)
  it "should process rrule; (inclusive in UTC) tz=null (UTC), base_tz=UTC, jitter=0"
  call 'calendar.rrule' 'FREQ=WEEKLY;BYDAY=MO' '2025-03-31T08:00:00Z' 'null' '0s'
  EXPECTED="$(date -u -d '2025-03-31T08:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # R6) tz=null (UTC); aware base with +02:00 — evaluate in UTC at 08:00Z
  it "should process rrule; (aware base +02:00, inclusive) tz=null (UTC), base_tz=UTC, jitter=0"
  call 'calendar.rrule' 'FREQ=WEEKLY;BYDAY=MO' '2025-03-31T10:00:00+02:00' 'null' '0s'
  EXPECTED="$(date -u -d '2025-03-31T08:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # R7) Daily at fixed local time across EU DST; base +1s ⇒ inclusive: same day 10:00:01 Berlin → 09:00:01Z
  it "should process rrule; (daily across DST, inclusive same day) tz=Europe/Berlin, base_tz=null, jitter=0"
  call 'calendar.rrule' 'FREQ=DAILY' '2025-03-29T10:00:01' 'Europe/Berlin' '0s'
  EXPECTED="$(date -u -d '2025-03-29T09:00:01Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # R8) First business day of month via BYSETPOS; expect Mon 2025-02-03 10:00 Berlin → 09:00Z
  it "should process rrule; (first business day via BYSETPOS) tz=Europe/Berlin, base_tz=UTC, jitter=0"
  call 'calendar.rrule' 'FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=1' '2025-01-10T09:00:00Z' 'Europe/Berlin' '0s'
  EXPECTED="$(date -u -d '2025-02-03T09:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # R9) Monthly BYMONTHDAY=15,31; base on 31st at 12:00Z (inclusive) — returns the same instant
  it "should process rrule; (inclusive on BYMONTHDAY match) tz=UTC, base_tz=UTC, jitter=0"
  call 'calendar.rrule' 'FREQ=MONTHLY;BYMONTHDAY=15,31' '2025-01-31T12:00:00Z' 'UTC' '0s'
  EXPECTED="$(date -u -d '2025-01-31T12:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # R10) Aware base +02:00 evaluated in America/New_York; fixed 10:00 local → 14:00Z
  it "should process rrule; (fixed 10:00 New_York) tz=America/New_York, base_tz=UTC, jitter=0"
  call 'calendar.rrule' 'FREQ=WEEKLY;BYDAY=MO;BYHOUR=10;BYMINUTE=0;BYSECOND=0' '2025-03-31T10:07:00+02:00' 'America/New_York' '0s'
  EXPECTED="$(date -u -d '2025-03-31T14:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # R11) Aware base −05:00 evaluated in Europe/Berlin; next day 10:00 Berlin → 08:00Z
  it "should process rrule; (aware −05:00 → next Berlin 10:00) tz=Europe/Berlin, base_tz=UTC, jitter=0"
  call 'calendar.rrule' 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=10;BYMINUTE=0;BYSECOND=0' '2025-03-31T10:07:00-05:00' 'Europe/Berlin' '0s'
  EXPECTED="$(date -u -d '2025-04-01T08:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # R12) Monthly last Friday; aware base Z — next is Fri May 30 14:00 Berlin → 12:00Z
  it "should process rrule; (last Friday of month) tz=Europe/Berlin, base_tz=UTC, jitter=0"
  call 'calendar.rrule' 'FREQ=MONTHLY;BYDAY=-1FR' '2025-04-26T12:00:00Z' 'Europe/Berlin' '0s'
  EXPECTED="$(date -u -d '2025-05-30T12:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # R13) Monthly last Friday; base exactly on occurrence at 14:00 Berlin (inclusive) → 12:00Z
  it "should process rrule; (inclusive on last Friday) tz=Europe/Berlin, base_tz=null, jitter=0"
  call 'calendar.rrule' 'FREQ=MONTHLY;BYDAY=-1FR' '2025-05-30T14:00:00' 'Europe/Berlin' '0s'
  EXPECTED="$(date -u -d '2025-05-30T12:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # R14) Leap day yearly in UTC; next is 2028-02-29 00:00Z
  it "should process rrule; (leap day in UTC) tz=null (UTC), base_tz=UTC, jitter=0"
  call 'calendar.rrule' 'FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=29' '2025-03-01T00:00:00Z' 'null' '0s'
  EXPECTED="$(date -u -d '2028-02-29T00:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # R15) Weekly MO/WE/FR in Europe/Berlin; base 08:00Z == Mon 10:00 Berlin (inclusive)
  it "should process rrule; (inclusive at Berlin wall time) tz=Europe/Berlin, base_tz=UTC, jitter=0"
  call 'calendar.rrule' 'FREQ=WEEKLY;BYDAY=MO,WE,FR' '2025-03-31T08:00:00Z' 'Europe/Berlin' '0s'
  EXPECTED="$(date -u -d '2025-03-31T08:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # R16) DTSTART inside expression is ignored; base 08:00Z == 10:00 Berlin (inclusive)
  it "should process rrule; (ignore DTSTART in expression) tz=Europe/Berlin, base_tz=UTC, jitter=0"
  call 'calendar.rrule' $'DTSTART:20250331T090000Z\nFREQ=WEEKLY;BYDAY=MO,WE,FR' '2025-03-31T08:00:00Z' 'Europe/Berlin' '0s'
  EXPECTED="$(date -u -d '2025-03-31T08:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # R17) Daily across EU DST (spring forward); fixed 10:00 local — base 10:01 forces next day 10:00 CEST → 08:00Z
  it "should process rrule; (daily across DST, next day) tz=Europe/Berlin, base_tz=null, jitter=0"
  call 'calendar.rrule' 'FREQ=DAILY;BYHOUR=10;BYMINUTE=0;BYSECOND=0' '2025-03-29T10:01:00' 'Europe/Berlin' '0s'
  EXPECTED="$(date -u -d '2025-03-30T08:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # R18) No next: UNTIL strictly before base (returns next=null, delta=null)
  it "should process rrule; (no next: UNTIL before base) tz=Europe/Berlin, base_tz=UTC, jitter=0"
  call 'calendar.rrule' 'RRULE:FREQ=DAILY;UNTIL=20250101T000000Z' '2025-02-01T00:00:00Z' 'Europe/Berlin' '0s'
  assert_next_is_unavailable
  assert_jitter_bounds

  # R19) No next: impossible rule (Feb 30) — no occurrences at all
  it "should process rrule; (no next: impossible Feb 30) tz=null (UTC), base_tz=UTC, jitter=0"
  call 'calendar.rrule' 'FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30' '2025-02-01T00:00:00Z' 'null' '0s'
  assert_next_is_unavailable
  assert_jitter_bounds

  # R20) No next: 6th Monday in May within UNTIL window does not exist
  it "should process rrule; (no next: BYSETPOS=6 in May within UNTIL) tz=Europe/Berlin, base_tz=UTC, jitter=0"
  call 'calendar.rrule' 'FREQ=MONTHLY;BYMONTH=5;BYDAY=MO;BYSETPOS=6;UNTIL=20250531T235959Z' '2025-05-01T00:00:00Z' 'Europe/Berlin' '0s'
  assert_next_is_unavailable
  assert_jitter_bounds

  # R21) Control for (R20): BYSETPOS=1 (first Monday of May 2025) — occurrence at 02:00 Berlin → 00:00Z
  it "should process rrule; (first Monday via BYSETPOS=1) tz=Europe/Berlin, base_tz=UTC, jitter=0"
  call 'calendar.rrule' 'FREQ=MONTHLY;BYMONTH=5;BYDAY=MO;BYSETPOS=1' '2025-05-01T00:00:00Z' 'Europe/Berlin' '0s'
  EXPECTED="$(date -u -d '2025-05-05T00:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # R22) Weekly Monday with jitter; next Mon 10:00 Berlin → 08:00Z
  it "should process rrule; (weekly Monday with jitter) tz=Europe/Berlin, base_tz=UTC, jitter=45s"
  call 'calendar.rrule' 'FREQ=WEEKLY;BYDAY=MO' '2025-04-04T08:00:00Z' 'Europe/Berlin' '45s'
  EXPECTED="$(date -u -d '2025-04-07T08:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # R23) UNTIL with Z in UTC; base just before — next equals the UNTIL instant (08:00Z)
  it "should process rrule; (UNTIL inclusive at exact instant) tz=null (UTC), base_tz=UTC, jitter=0"
  call 'calendar.rrule' 'FREQ=HOURLY;BYMINUTE=0;BYSECOND=0;UNTIL=20250401T080000Z' '2025-04-01T07:59:00Z' 'null' '0s'
  EXPECTED="$(date -u -d '2025-04-01T08:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # R24) Invalid UNTIL without Z while DTSTART is timezone-aware — expect exit code 3
  it "should process rrule; (invalid UNTIL without Z when DTSTART is TZ-aware) tz=Europe/Berlin, base_tz=null, jitter=0"
  expect_exit_code 7 -- call 'calendar.rrule' 'FREQ=HOURLY;BYMINUTE=0;BYSECOND=0;UNTIL=20250401T100000' '2025-04-01T09:59:00' 'Europe/Berlin' '0s'

  # R25) COUNT where base is before the first occurrence; weekly MO 10:00 Berlin → 08:00Z
  it "should process rrule; (COUNT with base before first occurrence) tz=Europe/Berlin, base_tz=UTC, jitter=0"
  call 'calendar.rrule' 'FREQ=WEEKLY;BYDAY=MO;COUNT=2' '2025-04-04T08:00:00Z' 'Europe/Berlin' '0s'
  EXPECTED="$(date -u -d '2025-04-07T08:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # R26) Daily across EU DST; keep local wall time 01:30 Berlin — base is on the occurrence → inclusive = same instant
  it "should process rrule; (daily across DST, inclusive same day 01:30) tz=Europe/Berlin, base_tz=null, jitter=0"
  call 'calendar.rrule' 'FREQ=DAILY' '2025-03-29T01:30:00' 'Europe/Berlin' '0s'
  EXPECTED="$(date -u -d '2025-03-29T00:30:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # —————————————————————————
  # calendar_systemd.py
  # —————————————————————————

  # S1) Base exactly on a recurring slot in UTC (inclusive) — returns the same instant
  it "should process systemd; (inclusive: base equals recurring slot) tz=UTC, base_tz=UTC, jitter=0"
  call 'calendar.systemd' '*-*-* 08:00:00' '2025-03-31T08:00:00Z' 'UTC' '0s'
  EXPECTED="$(date -u -d '2025-03-31T08:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # S2) Same as (S1), evaluated at Berlin wall time; base 08:00Z == 10:00 Europe/Berlin (inclusive)
  it "should process systemd; (inclusive at Berlin wall time) tz=Europe/Berlin, base_tz=UTC, jitter=0"
  call 'calendar.systemd' 'Mon..Fri *-*-* 10:00:00' '2025-03-31T08:00:00Z' 'Europe/Berlin' '0s'
  EXPECTED="$(date -u -d '2025-03-31T08:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # S3) Naive base interpreted in Europe/Berlin; 10:00 CEST corresponds to 08:00Z (inclusive)
  it "should process systemd; (inclusive with naive base) tz=Europe/Berlin, base_tz=null, jitter=0"
  call 'calendar.systemd' 'Mon..Fri *-*-* 10:00' '2025-03-31T10:00:00' 'Europe/Berlin' '0s'
  EXPECTED="$(date -u -d '2025-03-31T08:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # S4) Fixed 10:00 Europe/Berlin; base earlier than slot ⇒ same-day 10:00 Berlin → 08:00Z
  it "should process systemd; (fixed 10:00 local next) tz=Europe/Berlin, base_tz=UTC, jitter=0"
  call 'calendar.systemd' 'Mon..Fri *-*-* 10:00' '2025-03-31T07:30:00Z' 'Europe/Berlin' '0s'
  EXPECTED="$(date -u -d '2025-03-31T08:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # S5) tz=null means UTC; naive base is interpreted as UTC
  it "should process systemd; (tz=null interpreted as UTC) tz=null (UTC), base_tz=null, jitter=0"
  call 'calendar.systemd' '*-*-* 10:00' '2025-03-31T09:59:30' 'null' '0s'
  EXPECTED="$(date -u -d '2025-03-31T10:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # S6) Aware base +02:00 evaluated in America/New_York; next fixed 10:00 EDT → 14:00Z
  it "should process systemd; (fixed 10:00 New_York) tz=America/New_York, base_tz=UTC, jitter=0"
  call 'calendar.systemd' 'Mon..Fri *-*-* 10:00' '2025-03-31T10:07:00+02:00' 'America/New_York' '0s'
  EXPECTED="$(date -u -d '2025-03-31T14:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # S7) Aware base −05:00 evaluated in Europe/Berlin; next day 10:00 Berlin → 08:00Z
  it "should process systemd; (aware −05:00 → next Berlin 10:00) tz=Europe/Berlin, base_tz=UTC, jitter=0"
  call 'calendar.systemd' 'Mon..Fri *-*-* 10:00' '2025-03-31T10:07:00-05:00' 'Europe/Berlin' '0s'
  EXPECTED="$(date -u -d '2025-04-01T08:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # S8) Daily across EU DST (spring forward); base 10:01 local ⇒ next day 10:00 CEST → 08:00Z
  it "should process systemd; (DST spring forward, next day) tz=Europe/Berlin, base_tz=null, jitter=0"
  call 'calendar.systemd' '*-*-* 10:00' '2025-03-29T10:01:00' 'Europe/Berlin' '0s'
  EXPECTED="$(date -u -d '2025-03-30T08:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # S9) Daily across EU DST; keep local wall time 01:30 Berlin — base on occurrence (inclusive)
  it "should process systemd; (daily across DST, inclusive 01:30) tz=Europe/Berlin, base_tz=null, jitter=0"
  call 'calendar.systemd' '*-*-* 01:30:00' '2025-03-29T01:30:00' 'Europe/Berlin' '0s'
  EXPECTED="$(date -u -d '2025-03-29T00:30:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # S10) Monthly “last Friday” at 14:00 Berlin via DOM range 24..31 → Fri 2025-05-30 14:00 Berlin → 12:00Z
  it "should process systemd; (last Friday via DOM 24..31) tz=Europe/Berlin, base_tz=UTC, jitter=0"
  call 'calendar.systemd' 'Fri *-*-24..31 14:00' '2025-04-26T12:00:00Z' 'Europe/Berlin' '0s'
  EXPECTED="$(date -u -d '2025-05-30T12:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # S11) No next: single absolute date-time is already in the past (returns next=null, delta=null)
  it "should process systemd; (no next: single absolute past) tz=UTC, base_tz=UTC, jitter=0"
  call 'calendar.systemd' '2025-01-01 00:00:00' '2025-01-02T00:00:00Z' 'UTC' '0s'
  assert_next_is_unavailable
  assert_jitter_bounds

  # S12) No next: impossible absolute date (Feb 30) — no occurrence at all
  it "should process systemd; (no next: impossible Feb 30) tz=UTC, base_tz=UTC, jitter=0"
  call 'calendar.systemd' '2025-02-30 00:00:00' '2025-02-01T00:00:00Z' 'UTC' '0s'
  assert_next_is_unavailable
  assert_jitter_bounds

  # S13) No next: year range already elapsed (expression restricted to past year)
  it "should process systemd; (no next: elapsed year range) tz=UTC, base_tz=UTC, jitter=0"
  call 'calendar.systemd' '2024-*-* 10:00:00' '2025-01-01T00:00:00Z' 'UTC' '0s'
  assert_next_is_unavailable
  assert_jitter_bounds

  # S14) Jitter window check and back-out against jitter=0 baseline (Europe/Berlin)
  it "should process systemd; (jitter window vs baseline) tz=Europe/Berlin, base_tz=UTC, jitter=30s"
  call 'calendar.systemd' '*-*-* 09:00:00' '2025-03-29T12:00:00Z' 'Europe/Berlin' '0s'
  EXPECTED="$(date -u -d '2025-03-30T07:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  call 'calendar.systemd' '*-*-* 09:00:00' '2025-03-29T12:00:00Z' 'Europe/Berlin' '30s'
  assert_jitter_bounds
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent

  # S15) Inclusive boundary at an exact absolute timestamp — returns the same instant
  it "should process systemd; (inclusive at exact absolute timestamp) tz=null (UTC), base_tz=UTC, jitter=0"
  call 'calendar.systemd' '2025-04-01 08:00:00' '2025-04-01T08:00:00Z' 'null' '0s'
  EXPECTED="$(date -u -d '2025-04-01T08:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # S16) TZ in expression overrides evaluator TZ; expression UTC wins — next is 10:00Z
  it "should process systemd; (TZ in expression: UTC wins) tz=Europe/Berlin, base_tz=UTC, jitter=0"
  call 'calendar.systemd' '*-*-* 10:00:00 UTC' '2025-03-31T08:07:00Z' 'Europe/Berlin' '0s'
  EXPECTED="$(date -u -d '2025-03-31T10:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # S17) TZ in expression: Europe/Berlin overrides evaluator TZ; next day 10:00 Berlin → 08:00Z
  it "should process systemd; (TZ in expression: Berlin wins) tz=America/New_York, base_tz=UTC, jitter=0"
  call 'calendar.systemd' 'Mon..Fri *-*-* 10:00:00 Europe/Berlin' '2025-03-31T08:07:00Z' 'America/New_York' '0s'
  EXPECTED="$(date -u -d '2025-04-01T08:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # S18) Both specify UTC (expression and evaluator) — idempotent result
  it "should process systemd; (UTC in expression and evaluator) tz=null (UTC), base_tz=UTC, jitter=0"
  call 'calendar.systemd' '*-*-* 10:00:00 UTC' '2025-03-31T09:59:30Z' 'null' '0s'
  EXPECTED="$(date -u -d '2025-03-31T10:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # S19) Absolute timestamp with TZ in expression (inclusive) — returns the same instant
  it "should process systemd; (absolute with UTC in expression, inclusive) tz=Europe/Berlin, base_tz=UTC, jitter=0"
  call 'calendar.systemd' '2025-04-01 08:00:00 UTC' '2025-04-01T08:00:00Z' 'Europe/Berlin' '0s'
  EXPECTED="$(date -u -d '2025-04-01T08:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # S20) No next with TZ in expression: absolute instant already in the past (UTC)
  it "should process systemd; (no next: past absolute with UTC in expression) tz=Europe/Berlin, base_tz=UTC, jitter=0"
  call 'calendar.systemd' '2025-01-01 00:00:00 UTC' '2025-01-02T00:00:00Z' 'Europe/Berlin' '0s'
  assert_next_is_unavailable
  assert_jitter_bounds

  # S21) DST EU with TZ in expression: base 10:01 local ⇒ next day 10:00 CEST → 08:00Z
  it "should process systemd; (DST spring forward with TZ in expression) tz=UTC, base_tz=UTC, jitter=0"
  call 'calendar.systemd' '*-*-* 10:00:00 Europe/Berlin' '2025-03-29T10:01:00' 'UTC' '0s'
  EXPECTED="$(date -u -d '2025-03-30T08:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # S22) Conflict: expression=UTC vs evaluator=Europe/Berlin — expression wins; next is 10:00Z
  it "should process systemd; (conflict: expression UTC wins over evaluator TZ) tz=Europe/Berlin, base_tz=UTC, jitter=0"
  call 'calendar.systemd' '*-*-* 10:00:00 UTC' '2025-03-31T10:07:00+02:00' 'Europe/Berlin' '0s'
  EXPECTED="$(date -u -d '2025-03-31T10:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # S23) Monthly “last Friday” with TZ in expression (Berlin) via DOM range 24..31 → 2025-05-30 14:00 Berlin
  it "should process systemd; (last Friday via DOM 24..31 with TZ in expression) tz=UTC, base_tz=UTC, jitter=0"
  call 'calendar.systemd' 'Fri *-*-24..31 14:00 Europe/Berlin' '2025-04-26T12:00:00Z' 'UTC' '0s'
  EXPECTED="$(date -u -d '2025-05-30T12:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # S24) tz=null with TZ in expression: tz=null means UTC process TZ; expression TZ still wins
  it "should process systemd; (tz=null with TZ in expression) tz=null (UTC), base_tz=UTC, jitter=0"
  call 'calendar.systemd' 'Mon..Fri *-*-* 10:00 Europe/Berlin' '2025-03-31T08:07:00Z' 'null' '0s'
  EXPECTED="$(date -u -d '2025-04-01T08:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # S25) No next with TZ in expression: year range already elapsed (UTC)
  it "should process systemd; (no next: elapsed year range with TZ in expression) tz=Europe/Berlin, base_tz=UTC, jitter=0"
  call 'calendar.systemd' '2024-*-* 10:00:00 UTC' '2025-01-01T00:00:00Z' 'Europe/Berlin' '0s'
  assert_next_is_unavailable
  assert_jitter_bounds

  # S26) Inclusive (recurring): base exactly on 08:00:00Z — returns the same instant
  it "should process systemd; (inclusive equality at exact recurring slot) tz=UTC, base_tz=UTC, jitter=0"
  call 'calendar.systemd' '*-*-* 08:00:00 UTC' '2025-03-31T08:00:00Z' 'UTC' '0 seconds'
  EXPECTED="$(date -u -d '2025-03-31T08:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # S27) Inclusive (absolute): base exactly on absolute timestamp — returns the same instant
  it "should process systemd; (inclusive equality at exact absolute timestamp) tz=UTC, base_tz=UTC, jitter=0"
  call 'calendar.systemd' '2025-04-01 08:00:00 UTC' '2025-04-01T08:00:00Z' 'UTC' '0 seconds'
  EXPECTED="$(date -u -d '2025-04-01T08:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # S28) Inclusive boundary: 1 ms before slot (07:59:59.999Z) is not 08:00:00Z — next equals 08:00:00Z
  it "should process systemd; (inclusive boundary at 1ms before slot) tz=UTC, base_tz=UTC, jitter=0"
  call 'calendar.systemd' '*-*-* 08:00:00 UTC' '2025-03-31T07:59:59.999Z' 'UTC' '0 seconds'
  EXPECTED="$(date -u -d '2025-03-31T08:00:00Z' '+%s')"
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # —————————————————————————
  # interval_fixed_rate.py
  # —————————————————————————

  # F1) Decimal rounding up: 1.2s → 2s; next = base + 2
  it "should process fixed-rate; (rounds 1.2s up to 2s) tz=null (UTC), base_tz=UTC, jitter=0"
  call 'interval.fixed_rate' '1.2s' '2025-01-01T00:00:00Z' 'null' '0s'
  EXPECTED=$(( OUT_BASE + 2 ))
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # F2) Multi-units with decimal seconds: 1h 30m 0.4s → 3600 + 1800 + 1 = 5401s; next = base + 5401
  it "should process fixed-rate; (multi-units with decimal seconds) tz=null (UTC), base_tz=UTC, jitter=0"
  call 'interval.fixed_rate' '1h 30m 0.4s' '2025-01-01T00:00:00Z' 'null' '0s'
  EXPECTED=$(( OUT_BASE + 5401 ))
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # F3) Same as F2 with jitter; verify window and back-out against jitter=0 baseline
  it "should process fixed-rate; (jitter window vs baseline) tz=null (UTC), base_tz=UTC, jitter=30s"
  call 'interval.fixed_rate' '1h 30m 0.4s' '2025-01-01T00:00:00Z' 'null' '30s'
  # EXPECTED same as before
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # F4) Weeks unit: 1w == 604800s; next = base + 604800
  it "should process fixed-rate; (weeks unit 1w = 604800s) tz=UTC, base_tz=UTC, jitter=0"
  call 'interval.fixed_rate' '1w' '2025-02-01T00:00:00Z' 'UTC' '0s'
  EXPECTED=$(( OUT_BASE + 604800 ))
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # F5) Words vs short units: 2 hours == 2h == 7200s
  it "should process fixed-rate; (2 hours equals 2h) tz=UTC, base_tz=UTC, jitter=0"
  call 'interval.fixed_rate' '2 hours' '2025-02-01T00:00:00Z' 'UTC' '0s'
  EXPECTED=$(( OUT_BASE + 7200 ))
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds
  call 'interval.fixed_rate' '2h' '2025-02-01T00:00:00Z' 'UTC' '0s'
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # F6) Whitespace variants allowed by regex: "2  h", "2\tmins" etc. → still correct duration
  it "should process fixed-rate; (whitespace variations accepted) tz=UTC, base_tz=UTC, jitter=0"
  call 'interval.fixed_rate' $'2  h' '2025-02-01T00:00:00Z' 'UTC' '0s'
  EXPECTED=$(( OUT_BASE + 7200 ))
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds
  call 'interval.fixed_rate' $'2\tmins' '2025-02-01T00:00:00Z' 'UTC' '0s'
  EXPECTED=$(( OUT_BASE + 120 ))
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # F7) Zero duration: 0s → next == base (delta=0)
  it "should process fixed-rate; (zero duration returns base) tz=UTC, base_tz=UTC, jitter=0"
  call 'interval.fixed_rate' '0s' '2025-02-01T12:34:56Z' 'UTC' '0s'
  EXPECTED=$(( OUT_BASE ))
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # F8) Large mixed spec: 3d 4h 5m 6s → 3*86400 + 4*3600 + 5*60 + 6 = 277,506s
  it "should process fixed-rate; (large mixed spec) tz=UTC, base_tz=UTC, jitter=0"
  call 'interval.fixed_rate' '3d 4h 5m 6s' '2025-02-01T00:00:00Z' 'UTC' '0s'
  EXPECTED=$(( OUT_BASE + 273906 ))
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # F9) DST gap (EU spring forward): base in Berlin 2025-03-30 01:30, +30m is absolute seconds across DST
  it "should process fixed-rate; (DST gap adds absolute seconds) tz=Europe/Berlin, base_tz=null, jitter=0"
  call 'interval.fixed_rate' '30m' '2025-03-30T01:30:00' 'Europe/Berlin' '0s'
  EXPECTED=$(( OUT_BASE + 1800 ))
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # F10) Naive base with tz=null means UTC; +90m → base + 5400s
  it "should process fixed-rate; (naive base interpreted as UTC when tz=null) tz=null (UTC), base_tz=null, jitter=0"
  call 'interval.fixed_rate' '90m' '2025-03-01T12:00:00' 'null' '0s'
  EXPECTED=$(( OUT_BASE + 5400 ))
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # F11) Valid pluralization synonyms: secs/mins/hrs/days/weeks
  it "should process fixed-rate; (pluralization synonyms accepted) tz=UTC, base_tz=UTC, jitter=0"
  call 'interval.fixed_rate' '5 secs' '2025-02-01T00:00:00Z' 'UTC' '0s'
  EXPECTED=$(( OUT_BASE + 5 ))
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds
  call 'interval.fixed_rate' '2 hrs 3 mins' '2025-02-01T00:00:00Z' 'UTC' '0s'
  EXPECTED=$(( OUT_BASE + 7380 ))
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # F12) Invalid spec: malformed decimal (.5s without leading zero) → expect exit code 3
  it "should process fixed-rate; (invalid: malformed expression 1h30m) tz=UTC, base_tz=UTC, jitter=0"
  expect_exit_code 7 -- call 'interval.fixed_rate' '1h30m' '2025-02-01T00:00:00Z' 'UTC' '0s'

  # —————————————————————————
  # interval_fixed_delay.py
  # —————————————————————————

  # D1) Next equals (finish + delay): base + 2500 ms finish; interval=10s → next = OUT_BASE + 10
  it "should process fixed-delay; (next = finish + delay) tz=UTC, base_tz=UTC, jitter=0"
  call 'interval.fixed_delay' '10s' '2025-01-01T00:00:00Z' 'UTC' '0s' '2500'
  EXPECTED=$(( OUT_BASE + 10 ))
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # D2) Multi-units with decimal seconds: 1h 30m 0.4s → 5401s; duration=0 ms; next = OUT_BASE + 5401
  it "should process fixed-delay; (multi-units with decimal seconds) tz=null (UTC), base_tz=UTC, jitter=0"
  call 'interval.fixed_delay' '1h 30m 0.4s' '2025-01-01T00:00:00Z' 'null' '0s' '0'
  EXPECTED=$(( OUT_BASE + 5401 ))
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # D3) Jitter window vs jitter=0 baseline; verify window and back-out
  it "should process fixed-delay; (jitter window vs baseline) tz=null (UTC), base_tz=UTC, jitter=30s"
  call 'interval.fixed_delay' '2m 2.5s' '2025-01-01T00:00:00Z' 'null' '0s' '0'
  EXPECTED="$OUT_NEXT"
  call 'interval.fixed_delay' '2m 2.5s' '2025-01-01T00:00:00Z' 'null' '30s' '0'
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # D4) Weeks unit: 1w == 604800s; duration=1000 ms; next = OUT_BASE + 604800
  it "should process fixed-delay; (weeks unit 1w = 604800s) tz=UTC, base_tz=UTC, jitter=0"
  call 'interval.fixed_delay' '1w' '2025-02-01T00:00:00Z' 'UTC' '0s' '1000'
  EXPECTED=$(( OUT_BASE + 604800 ))
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # D5) Words vs short units: 2 hours == 2h == 7200s; duration=0 ms
  it "should process fixed-delay; (2 hours equals 2h) tz=UTC, base_tz=UTC, jitter=0"
  call 'interval.fixed_delay' '2 hours' '2025-02-01T00:00:00Z' 'UTC' '0s' '0'
  EXPECTED=$(( OUT_BASE + 7200 ))
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds
  call 'interval.fixed_delay' '2h' '2025-02-01T00:00:00Z' 'UTC' '0s' '0'
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # D6) Whitespace variations accepted by regex: "2  h", "2\tmins" → correct durations; duration=0 ms
  it "should process fixed-delay; (whitespace variations accepted) tz=UTC, base_tz=UTC, jitter=0"
  call 'interval.fixed_delay' $'2  h' '2025-02-01T00:00:00Z' 'UTC' '0s' '0'
  EXPECTED=$(( OUT_BASE + 7200 ))
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds
  call 'interval.fixed_delay' $'2\tmins' '2025-02-01T00:00:00Z' 'UTC' '0s' '0'
  EXPECTED=$(( OUT_BASE + 120 ))
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # D7) Zero interval: 0s; duration=5000 ms → finish==base+5s; next==finish (delta=0)
  it "should process fixed-delay; (zero interval returns finish) tz=UTC, base_tz=UTC, jitter=0"
  call 'interval.fixed_delay' '0s' '2025-02-01T12:34:56Z' 'UTC' '0s' '5000'
  EXPECTED=$(( OUT_BASE ))
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # D8) Large mixed spec: 3d 4h 5m 6s → 277,506s; duration=250 ms; next = OUT_BASE + 277506
  it "should process fixed-delay; (large mixed spec) tz=UTC, base_tz=UTC, jitter=0"
  call 'interval.fixed_delay' '3d 4h 5m 6s' '2025-02-01T00:00:00Z' 'UTC' '0s' '250'
  EXPECTED=$(( OUT_BASE + 273906 ))
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # D9) DST gap (EU spring forward): base=Berlin 2025-03-30 01:30, +15m work; +30m fixed delay is absolute seconds
  it "should process fixed-delay; (DST gap adds absolute seconds) tz=Europe/Berlin, base_tz=null, jitter=0"
  call 'interval.fixed_delay' '30m' '2025-03-30T01:30:00' 'Europe/Berlin' '0s' '900000'
  EXPECTED=$(( OUT_BASE + 30*60 ))
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # D10) tz=null with naive base means UTC; duration=250 ms; +90m → next = OUT_BASE + 5400
  it "should process fixed-delay; (naive base interpreted as UTC when tz=null) tz=null (UTC), base_tz=null, jitter=0"
  call 'interval.fixed_delay' '90m' '2025-03-01T12:00:00' 'null' '0s' '250'
  EXPECTED=$(( OUT_BASE + 5400 ))
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # D11) Pluralization synonyms: secs/mins/hrs/days/weeks accepted; duration=0 ms
  it "should process fixed-delay; (pluralization synonyms accepted) tz=UTC, base_tz=UTC, jitter=0"
  call 'interval.fixed_delay' '5 secs' '2025-02-01T00:00:00Z' 'UTC' '0s' '0'
  EXPECTED=$(( OUT_BASE + 5 ))
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds
  call 'interval.fixed_delay' '2 hrs 3 mins' '2025-02-01T00:00:00Z' 'UTC' '0s' '0'
  EXPECTED=$(( OUT_BASE + 2*3600 + 3*60 ))
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # D12) Invalid spec: malformed decimal (.5s without leading zero) → expect exit code 3
  it "should process fixed-delay; (invalid: malformed decimal .5s) tz=UTC, base_tz=UTC, jitter=0"
  expect_exit_code 7 -- call 'interval.fixed_delay' '.5s' '2025-02-01T00:00:00Z' 'UTC' '0s' '0'

  # D13) Millisecond boundary: base 07:59:59.900Z + 150 ms → finish ~08:00:00.050Z; +1s → next = OUT_BASE + 1
  it "should process fixed-delay; (millisecond boundary carry to next second) tz=UTC, base_tz=UTC, jitter=0"
  call 'interval.fixed_delay' '1s' '2025-03-31T07:59:59.900Z' 'UTC' '0s' '150'
  EXPECTED=$(( OUT_BASE + 1 ))
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # D14) Negative duration_ms (allowed by code): finish before base; still next = OUT_BASE + interval
  it "should process fixed-delay; (negative duration_ms handled) tz=UTC, base_tz=UTC, jitter=0"
  call 'interval.fixed_delay' '10s' '2025-01-01T00:00:10Z' 'UTC' '0s' '-5000'
  EXPECTED=$(( OUT_BASE + 10 ))
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # D15) Jitter window with long jitter: compare against baseline next (0s jitter) for same inputs
  it "should process fixed-delay; (jitter window with 1h) tz=UTC, base_tz=UTC, jitter=1h"
  call 'interval.fixed_delay' '5m' '2025-01-01T00:00:00Z' 'UTC' '0s' '1234'
  EXPECTED="$OUT_NEXT"
  call 'interval.fixed_delay' '5m' '2025-01-01T00:00:00Z' 'UTC' '1h' '1234'
  assert_next_epoch_secs_equals "$EXPECTED"
  assert_next_epoch_secs_in_window "$EXPECTED"
  assert_diff_consistent
  assert_jitter_bounds

  # —————————————————————————
  # check_is_pipeline_due
  # —————————————————————————

  read -r -d '' CI_CONFIG <<'EOF' || true
{
  "pipelines": [
    { "name": "p1" },
    { "name": "p2", "schedule": { "format": "calendar.systemd", "when": "*-*-* 10:00:00 UTC" } },
    { "name": "p3", "schedule": { "format": "calendar.systemd", "when": "*-*-* 08:00:00 UTC" } },
    { "name": "p4", "schedule": { "format": "calendar.systemd", "when": "2025-01-01 00:00:00 UTC" } }
  ]
}
EOF

  STATE_FILE="$TEMP_DIR/state.json"
  cat > "$STATE_FILE" <<'EOF'
{
  "pipelines": [
    { "name": "p1", "latest_execution": { "timestamp": "2025-04-01T08:00:00Z", "duration_ms": 0 } },
    { "name": "p2", "latest_execution": { "timestamp": "2025-04-01T09:59:00Z", "duration_ms": 0 } },
    { "name": "p3", "latest_execution": { "timestamp": "2025-03-31T08:00:00Z", "duration_ms": 0 } },
    { "name": "p4", "latest_execution": { "timestamp": "2025-01-02T00:00:00Z", "duration_ms": 0 } }
  ]
}
EOF

  # X1) No schedule configured — pipeline is due by default
  it "should decide due; (no schedule configured → due by default)"
  check_is_pipeline_due "p1"
  assert_equals "true" "${IS_PIPELINE_DUE:-}" "pipeline should be due when no schedule is present"

  # X2) Scheduled in the future — next occurrence is after base (delta<0) → not due
  it "should decide not due; (next occurrence in the future)"
  check_is_pipeline_due "p2"
  assert_equals "false" "${IS_PIPELINE_DUE:-}" "pipeline should NOT be due when next is in the future"

  # X3) Scheduled and inclusive now — base equals slot (delta≥0) → due
  it "should decide due; (inclusive when base equals slot)"
  check_is_pipeline_due "p3"
  assert_equals "true" "${IS_PIPELINE_DUE:-}" "pipeline should be due when base equals the slot (inclusive wrapper)"

  # X4) Scheduled but no next — absolute past instant → next=null → not due
  it "should decide not due; (no next: absolute past instant)"
  check_is_pipeline_due "p4"
  assert_equals "false" "${IS_PIPELINE_DUE:-}" "pipeline should NOT be due when there is no next occurrence"

  # —————————————————————————

  teardown

  return $(( TEST_PARTS_FAILED > 0 ? 1 : 0 ))
}

function call {

  local FORMAT
  local EXTENSION_RESULT
  local -a ENV_VARS_ARR

  FORMAT="$1"
  EXPRESSION="$2"
  BASE_TIMESTAMP="$3"
  TIMEZONE="$4"
  JITTER="$5"
  DURATION_MS="${6:-0}"

  ENV_VARS_ARR=()

  apply_extension "$INSTALL_DIR/extensions/when_evaluators" "evaluator" "schedule format" "$FORMAT" ENV_VARS_ARR false \
    "EXPRESSION=$EXPRESSION" \
    "BASE_TIMESTAMP=$BASE_TIMESTAMP" \
    "TIMEZONE=$TIMEZONE" \
    "JITTER=$JITTER" \
    "DURATION_MS=$DURATION_MS"

  OUT_BASE="$(jqw -r 'fromjson | .base_epoch_s' <<< "$EXTENSION_RESULT")"
  OUT_NEXT="$(jqw -r 'fromjson | .next_epoch_s' <<< "$EXTENSION_RESULT")"
  OUT_JVAL="$(jqw -r 'fromjson | .jitter_s' <<< "$EXTENSION_RESULT")"
  OUT_JOFF="$(jqw -r 'fromjson | .jitter_offset_s' <<< "$EXTENSION_RESULT")"
  OUT_DIFF="$(jqw -r 'fromjson | .delta_s' <<< "$EXTENSION_RESULT")"
}

function assert_diff_consistent() {

  assert_equals "$(( OUT_BASE - OUT_NEXT ))" "$OUT_DIFF" "compare_result equals (base_epoch - next_epoch)"
}

function assert_jitter_bounds {

  assert_equals "$(( OUT_JOFF >= 0 && OUT_JOFF <= OUT_JVAL ))" "1" "jitter_offset within [0, jitter]"
}

function assert_next_epoch_secs_equals {

  local EXPECTED_EPOCH_S
  local ACTUAL_EPOCH_S

  EXPECTED_EPOCH_S="$1"
  ACTUAL_EPOCH_S=$(( OUT_NEXT - OUT_JOFF ))

  assert_equals "$EXPECTED_EPOCH_S" "$ACTUAL_EPOCH_S" "next_epoch minus jitter_offset equals expected core next"
}

function assert_next_epoch_secs_in_window {

  local EXPECTED_EPOCH_S

  EXPECTED_EPOCH_S="$1"

  assert_equals "$(( OUT_NEXT >= EXPECTED_EPOCH_S && OUT_NEXT <= EXPECTED_EPOCH_S + OUT_JVAL ))" "1" \
    "next_epoch outside jitter window [core, core + jitter]"
}

function assert_next_is_unavailable {

  assert_equals "null" "$OUT_NEXT" "next_epoch_s should be null when no future occurrence"
  assert_equals "null" "$OUT_DIFF" "delta_s should be null when no future occurrence"
}
