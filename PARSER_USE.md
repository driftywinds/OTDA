# Quick-add parser: what you can type

OTDA's composer is not a command language. It is a **highlighter**.

You type a normal sentence. The parser highlights the parts it understands — dates, times, `p1`, `#project`, `@label`, repeat rules, reminders — removes those parts from the title, and turns them into task fields. Everything it does not highlight stays in the title as text.

All examples below assume:

- today = **Wednesday 25 November 2026**
- now = **10:00**
- English + US-style dates (`12/25` = 25 December)
- week starts on Monday
- project **Work** = `#work`
- labels **call** and **errand**
- energy, day parts and sectors are enabled

## The whole thing in one line

```text
Call Sam tomorrow 3pm #work @call p1 +45m remind me 30 min before
```

Becomes:

```text
title:      Call Sam
due:        26 Nov 2026, 15:00
project:    Work
labels:     call
priority:   P1
estimate:   45 minutes
reminder:   30 minutes before
```

That is the entire idea: **ordinary sentence + recognised decorations**.

---

## 1. Dates

### Day words

| You type | Result |
|---|---|
| `Call Sam today` | due 25 Nov |
| `Call Sam tomorrow` | due 26 Nov |
| `Call Sam tmrw` | due 26 Nov |
| `Call Sam day after tomorrow` | due 27 Nov |
| `Call Sam tonight` | due today, **evening flag** |

`today`, `tonight`, `tomorrow`, `tmrw`, `day after tomorrow` are the exact English day words.

### Weekdays

| You type | Result |
|---|---|
| `Review Monday` | next Monday, 30 Nov |
| `Review mon` | next Monday, 30 Nov |
| `Review tuesday` | next Tuesday, 1 Dec |
| `Review tues` | next Tuesday |
| `Review wed` | next Wednesday |
| `Review thursday` / `thur` / `thurs` | next Thursday |
| `Review friday` / `fri` | next Friday, 27 Nov |
| `Review saturday` / `sat` | next Saturday |
| `Review sunday` / `sun` | next Sunday |

Weekday names are case-insensitive. A weekday on its own always means the **next upcoming** one, never the past one.

`next Monday`, `this Monday` and plain `Monday` currently all resolve to the same upcoming Monday in this parser. That is a useful gotcha: “this Monday” does **not** mean the Monday earlier in the current week.

### Weekday + full date

```text
lunch Monday, March 3
```

is read as one date: **3 March**, not “Monday plus 3 March”.

### Ordinal weekdays

These mean “the Nth weekday of the month”:

| You type | Result with 25 Nov 2026 |
|---|---|
| `Standup 2nd tuesday` | 8 Dec 2026 |
| `Standup first monday` | 7 Dec 2026 |
| `Standup last friday` | 27 Nov 2026 |
| `Standup last friday of november` | 27 Nov 2026 |
| `Standup last sunday of march` | 28 Mar 2027 |
| `Standup 1st weekday` | first Mon–Fri day of the month |
| `Standup last weekday` | last Mon–Fri day of the month |

Out-of-range ordinals such as `5th Friday` are deliberately **not** parsed; they stay in the title.

### Month and day

| You type | Result |
|---|---|
| `Report 3 March` | 3 Mar 2027 (next 3 March) |
| `Report March 3` | 3 Mar 2027 |
| `Report 3 March 2027` | 3 Mar 2027 |
| `Report March 3 2027` | 3 Mar 2027 |
| `Report March` | 1 Mar 2027 |
| `Report oct 20` | 20 Oct 2027 |
| `Report 20 oct` | 20 Oct 2027 |

Month names and abbreviations work. A bare month means **the 1st of the next such month**.

But a month alone after `from`, `since`, `of` or `for` stays prose:

```text
invoices from September
```

remains the title **“invoices from September”**.

### Numeric dates

| You type | Result |
|---|---|
| `Report 2026-12-31` | 31 Dec 2026 |
| `Report 12/25` | 25 Dec 2026 in US order |
| `Report 25/12` | 25 Dec 2026 — the parser swaps it because 25 cannot be a month |
| `Report 3/4` | 4 March in US order; 3 April in day-month locales |

Numeric order comes from the account's date format / active language.

In a month-first locale, a **dashed** day and month without a year is treated as a
range, not a date: `Buy 3-4 tomatoes` keeps the title. It becomes a date when a
date word introduces it (`on 3-4`, `by 4-15`, `until 12-31`), and `3/4` and
`3-4-2027` are always dates. Day-first locales still read `3-4` as 3 April.

Dotted dates like `25.12.` are only accepted in a **day-month** locale; `3.30` is otherwise treated as a time only when it follows `at`.

### Relative periods

| You type | Result |
|---|---|
| `Plan in 3 days` | 28 Nov |
| `Plan in 2 weeks` | 9 Dec |
| `Plan in a week` | 2 Dec |
| `Plan in 1 month` | 25 Dec |
| `Plan in one year` | 25 Nov 2027 |
| `Plan next week` | Monday 30 Nov |
| `Plan next month` | 1 Dec |
| `Plan this week` | **sector** `2026-W48`, not a due date |
| `Plan this quarter` | **sector** `2026-Q4` |

“This week / this month / this quarter” are **time sectors**, not dates. They only work if the account uses sectors. “Next week / next month” are dates. This is deliberate: `next week` has a concrete start; `this week` is a bucket.

### Someday

```text
Read paper someday
```

sets `start: someday`, with no due date.

But it only applies when there is no date/time/recurrence/deadline:

```text
Buy milk someday tomorrow
```

becomes due tomorrow, and **“someday” stays in the title**.

---

## 2. Times

| You type | Result |
|---|---|
| `Dinner at 7pm` | today, 19:00 |
| `Dinner 7pm` | today, 19:00 |
| `Dinner 7:30pm` | today, 19:30 |
| `Dinner 19:30` | today, 19:30 |
| `Dinner noon` | today, 12:00 |
| `Dinner midday` | today, 12:00 |
| `Dinner midnight` | today, 00:00 |
| `Dinner at 9` | today, 09:00 |
| `Dinner at 3.30` | today, 03:30 |
| `Dinner in 2 hours` | today, 12:00 |
| `Dinner in 90 minutes` | today, 11:30 |

### Bare numbers are not times

```text
Buy milk 9
```

stays the title. To mean a time you need `at 9`, `9pm`, `9:00`, etc.

### Time without a date = today

`at 9` means **today at 09:00**, even if 09:00 has already passed. The parser does not silently roll it to tomorrow. Say `tomorrow at 9` if that is what you mean.

### Times and estimates are different

In English:

| You type | Result |
|---|---|
| `Draft 2h` | estimate 120 minutes |
| `Draft +2h` | estimate 120 minutes |
| `Draft 15h` | estimate 900 minutes |
| `Draft 30m` | stays in the title — could mean metres |
| `Draft +30m` | estimate 30 minutes |

In languages where clock times are written with `15h`, bare `15h`/`2h` can mean a time instead. That is why the `+` form exists.

Only the **first** time wins:

```text
Buy milk tomorrow 3pm 4pm
```

gives due tomorrow 15:00; `4pm` stays in the title.

---

## 3. Repeat rules

Recurrence is introduced by `every`, `each`, or words like `daily`, `weekly`, `monthly`, `yearly`.

### Simple rules

| You type | Rule stored | First due |
|---|---|---|
| `Water plants every day` | `every day` | today |
| `Water plants daily` | `every day` | today |
| `Water plants every 3 days` | `every 3 days` | today |
| `Water plants every week` | `every week` | today |
| `Water plants weekly` | `every week` | today |
| `Water plants every 2 months` | `every 2 months` | today |
| `Water plants every year` | `every year` | today |
| `Water plants every weekday` | `every weekday` | today |
| `Water plants every workday` | `every weekday` | today |

### Weekdays

| You type | Rule stored |
|---|---|
| `Water plants every monday` | `every monday` |
| `Water plants every mon, wed and fri` | `every monday, wednesday, friday` |
| `Water plants every 2 weeks on saturday` | `every 2 weeks on saturday` |
| `Water plants every 2 weeks on mon, fri` | `every 2 weeks on monday, friday` |
| `Water plants every other week` | `every 2 weeks` |
| `Water plants every other friday` | `every 2 weeks` — the Friday is anchored by the due date |

That last one looks odd in the stored rule, but it repeats every Friday because the first occurrence is Friday. The canonical form drops the weekday when the due date already anchors it.

### Monthly / ordinal rules

| You type | Rule stored |
|---|---|
| `Water plants every month` | `every month` |
| `Water plants every 2 months` | `every 2 months` |
| `Water plants every 15th` | `every 15th` |
| `Water plants every last day` | `every last day` |
| `Water plants every 1st weekday` | `every 1st weekday` |
| `Water plants every 2nd tuesday` | `every 2nd tuesday` |
| `Water plants every last friday` | `every last friday` |
| `Water plants every last sunday of march` | `every last sunday of march` |
| `Water plants every 4th thursday of november` | `every 4th thursday of november` |

### End conditions

| You type | Rule stored |
|---|---|
| `Water plants every day until 2026-12-31` | `every day until 2026-12-31` |
| `Water plants every day until 31 Dec` | `every day until 2026-12-31` |
| `Water plants every weekday for 10 times` | `every weekday for 10 times` |
| `Water plants every 3 days after completion` | `every 3 days after completion` |

`after completion` means the next occurrence is counted from when you tick it, not from the calendar date.

### Start phrase

```text
Water plants every day from monday
```

sets the first due to Monday 30 Nov and stores `every day`.

### Connectors

These all introduce a rule:

```text
Water plants and repeat every day
Water plants then every day
Water plants repeating every day
```

### Deliberately left alone

These are **not** accepted as recurrence rules and stay entirely in the title:

```text
Water plants every 3 hours
Meeting every 2 Mondays
```

The stored grammar cannot express “every 3 hours” or “every 2 Mondays”, so the parser refuses to half-parse them.

### Only the first rule counts

```text
Water plants every day every week
```

takes `every day`; the second phrase stays in the title.

---

## 4. Reminders

A reminder needs the words **`remind me`** (or the equivalent in another active language).

### Relative to the due time

| You type | Result |
|---|---|
| `Call Sam tomorrow 3pm remind me 30 min before` | offset −30 minutes |
| `Call Sam tomorrow 3pm remind me 1 hour before` | offset −60 |
| `Call Sam tomorrow 3pm remind me 2 days before` | offset −2880 |
| `Call Sam tomorrow 3pm remind me 10 minutes after` | offset +10 |
| `Call Sam remind me 30 min before` | stores an offset, but there is no due date to attach it to |

### A specific moment

| You type | Result |
|---|---|
| `Call Sam tomorrow 3pm remind me at 2:30pm` | a moment; resolves to 30 minutes before the due |
| `Call Sam remind me tomorrow at 9` | tomorrow 09:00 |
| `Call Sam remind me at 9` | today at 09:00 (or tomorrow if that time has passed) |
| `Call Sam remind me 20 Oct at 9` | 20 Oct at 09:00 |

Multiple reminders accumulate:

```text
Call Sam tomorrow 3pm remind me 1 hour before remind me 10 min before
```

makes two reminders.

---

## 5. Project, labels, priority, energy

### Project — `#`

| You type | Result |
|---|---|
| `Buy milk #work` | project Work |
| `Buy milk #wo` | Work, if only one project starts with “wo” |
| `Buy milk #parent/child` | nested project path |
| `Buy milk #nope` | stays in the title; no project |

Matching is case-insensitive and ignores diacritics/spaces/underscores. Exact names win; otherwise a **unique prefix** wins. Ambiguous prefixes stay as text.

Only the **first** project wins:

```text
Buy milk #work #personal
```

sets Work; `#personal` stays in the title.

### Labels — `@`

| You type | Result |
|---|---|
| `Buy milk @call` | label “call” |
| `Buy milk @call @errand` | both labels |
| `Buy milk @deep-work` | label “deep-work” |
| `Buy milk @call,` | trailing comma dropped |

Labels may not contain spaces. An unknown label is created when the task is saved.

### Priority — `p1` to `p4`

| You type | Result |
|---|---|
| `Buy milk p1` | P1 |
| `Buy milk p2` | P2 |
| `Buy milk P3` | P3, case-insensitive |
| `Buy milk p4` | P4 |

Only the **first** priority wins:

```text
Buy milk p1 p2
```

sets P1; `p2` stays in the title.

### Energy — `~deep`, `~medium`, `~low`

Only if the account has energy enabled:

| You type | Result |
|---|---|
| `Deep work ~deep` | energy deep |
| `Deep work ~d` | energy deep |
| `Deep work ~me` | energy medium |
| `Deep work ~l` | energy low |
| `Deep work ~6` | stays in the title |

If several energy tokens appear, the **last** one wins and all are removed.

---

## 6. Estimates and spent time

### Estimate

| You type | Result |
|---|---|
| `Draft +30` | 30 min |
| `Draft +30m` | 30 min |
| `Draft +45min` | 45 min |
| `Draft +2h` | 120 min |
| `Draft +1.5h` | 90 min |
| `Draft +1h30` | 90 min |
| `Draft +1h30m` | 90 min |
| `Draft 45min` | 45 min |
| `Draft 2h` | 120 min in English |

Without `+`, `30m` is deliberately left as text because it could mean 30 metres.

### Spent and estimate together

```text
Draft 30m/2h
```

sets **spent 30 minutes** and **estimate 2 hours**.

```text
Draft 1h/1h30
```

sets spent 60 minutes, estimate 90 minutes.

Both halves need units, so a date like `30/12` is not mistaken for spent time.

---

## 7. Evening, day parts, deadline, someday

### Evening

| You type | Result |
|---|---|
| `Tidy desk tonight` | due today + evening |
| `Tidy desk this evening` | due today + evening |
| `Tidy desk tomorrow evening` | due tomorrow + evening |

### Day parts

Only when the account uses day parts:

| You type | Result |
|---|---|
| `Buy milk this morning` | due today + morning part |
| `Buy milk this afternoon` | due today + afternoon part |
| `Buy milk morning` | stays in the title |

### Deadline

| You type | Result |
|---|---|
| `Pay rent deadline friday` | deadline Friday, no due |
| `Pay rent by friday` | deadline Friday, no due |
| `Pay rent by friday 5pm` | **due** Friday 17:00, not a deadline |
| `Pay rent due friday` | due Friday |
| `Pay rent on friday` | due Friday |
| `Pay rent deadline friday 5pm` | deadline Friday; `5pm` stays in the title |

A deadline has no time. Adding a time after `by` changes the phrase into a due date.

### Someday

Only applies when there is no date/time/recurrence/deadline:

```text
Read paper someday
```

sets `start: someday`.

---

## 8. Quoted text

Anything inside a balanced pair of `"…"` is never parsed:

```text
Buy "milk tomorrow p1"
```

Title: **Buy milk tomorrow p1** — no due date, no P1.

The quotes themselves are removed; their contents are protected.

---

## 9. Ambiguity rules

The parser deliberately follows a few simple rules:

1. **Longest phrase wins.**
   ```text
   gym every 2 weeks on Saturday
   ```
   is one recurrence, not a date plus a time plus text.

2. **A date wins a tie against a time.**

3. **Only the first date, first time and first recurrence count.**
   Later ones stay in the title.

4. **All labels and all reminders accumulate.**
   Multiple `@labels` and multiple reminders are allowed.

5. **First project and first priority win.**
   Extra `#project` / `p` tokens stay in the title.

6. **Last energy token wins.**

7. **A bare month is weak.**
   `March` means 1 March, but `from September` stays prose.

8. **A bare number is not a time.**
   `9` stays text; `at 9` is a time.

9. **A word that cannot be expressed is not half-parsed.**
   `every 3 hours` and `every 2 Mondays` stay whole in the title.

10. **Quoted words are literal.**

---

## 10. What is *not* a supported expression

To save you guessing:

| You type | Why |
|---|---|
| `Buy milk from monday` | There is no standalone “start from” field; Monday becomes the due date, but “from” stays in the title |
| `Buy milk starting monday` | Same — “starting” stays in the title |
| `every 3 hours` | The recurrence grammar has no hourly rule |
| `every 2 Mondays` | It cannot be expressed in the stored rule grammar |
| `5th Friday` | Only 1st–4th or “last” ordinals are supported |
| `Buy milk p5` | Priorities are P1–P4 |
| `Buy milk ~6` | Energy values are deep/medium/low |
| `@call now` | Labels cannot contain spaces; `@call` is a label and `now` is a separate word |
| `Buy milk 9` | A bare number is not a time |
| `Buy milk 30m` | Ambiguous with metres; use `+30m` |
| `deadline friday 5pm` | A deadline has no time; the 5pm stays in the title |
| `#project` when two projects match the prefix | Ambiguous; stays in the title |

---

## 11. The “everything” example

```text
Write report tomorrow 3pm #work @call p1 +45m remind me 30 min before
```

Result:

```text
title:       Write report
due:         26 Nov 2026, 15:00
project:     Work
labels:      call
priority:    P1
estimate:    45 min
reminder:    30 min before
```

And a bare line:

```text
Buy milk
```

is just:

```text
title: Buy milk
```

No fields. The parser only sets what you explicitly wrote.

The implementation lives in `lib/src/quickadd/`: `dates.dart` for dates/times, `recurrence.dart` + `rule.dart` for repeats, `reminders.dart`, `attributes.dart` for `#`/`@`/`p`/`~`/durations, and `parse.dart` for the left-to-right matching rules.
