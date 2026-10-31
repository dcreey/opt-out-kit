# Reminders

Local notifications that bring a person back to opting out. Code: `Packages/OptOutKitCore/.../Reminders.swift` (the plan and the wording, tested in
`RemindersTests`) and `App/Sources/Reminders.swift` (schedules them with iOS). No server, no push; nothing leaves the phone.

## The schedule

All dates count from the last day a request was sent (`ActivitySummary.lastDay`), or from the first launch when none has been sent yet. Each reminder arrives
at 18:00 local time.

| Reminder | Days after the last request | Needs |
| --- | --- | --- |
| Keep your streak going | 1 | a streak of at least one day |
| 3 days since your last opt-out | 3 | |
| It has been a week | 7 | |
| A month since you opted out | 30, then every 30 days (six more are lined up) | |

## No repeats

- Every reminder is a one-time notification with its own fixed date and id (`reminder-threeDays`, `reminder-month-2`, ...). There is no repeating trigger, so
  the 3-day reminder fires once, then the week one, then the month ones.
- The whole set is replaced whenever the app comes to the front, goes to the background, or finishes an automatic run. Any new request moves every date
  forward from that day, which starts the cycle again. Opening the app without sending a request leaves the dates alone.
- A date already past is dropped, never sent late.
- Nothing is scheduled until the person has allowed notifications (asked once, with their first opt-out).

## Wording

Short enough for a lock screen: the next kind of broker to go after (the best-ranked kind with sites left, the same one the daily list starts with), the
worst that can happen if it stays out there (`Reminders.worstCase`), and what to do. No names or site names, like the other notifications.
