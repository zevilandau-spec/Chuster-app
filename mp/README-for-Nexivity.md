# Box-print counts → Chuster app (factory PC pusher)

**Goal:** get the box counts your logger already records on CHUS-04 into the Chuster app, so the app's
new **Box printer** screen shows live counts (and today's production per product) from anywhere — no
counting by hand.

**How it fits your existing setup:** your logger keeps doing exactly what it does now (reads the printer,
writes `prints-YYYY-MM.csv`). This adds one small read-only companion, `push.ps1`, that reads that same
CSV once a minute and POSTs today's counts to the app. It does **not** touch the printer, the logger, or
the CSV. Think of it like the office PC's QuickBooks sync, but for box counts.

Data flow:

```
Markoprint ──(your logger, unchanged)──► prints-YYYY-MM.csv
                                              │
                                 push.ps1 (every minute, read-only)
                                              │  HTTPS POST (counts only)
                                              ▼
                          https://chuster.netlify.app/printlog/in
                                              │  (encrypts server-side with the app key)
                                              ▼
                                   Chuster app · Box printer screen
```

## What gets sent
Only: today's date, each **label name** with **how many boxes** were printed today, and the
currently-loaded label + its counter. No PII, no printer control, nothing else. It's an outbound HTTPS
POST to the app's own address (`chuster.netlify.app`) — the same host the app already uses.

## Install (about 5 minutes)
1. Copy **`push.ps1`** and **`config.json`** into **`C:\ProgramData\MarkoprintLog\`** (next to the logger).
   - If your CSVs live elsewhere, set `csvFolder` in `config.json` to that folder.
2. In `config.json`, set **`"secret"`** to the value **Zevi** will give you. (Leave `url` as is.)
3. Open **PowerShell as Administrator** and run:
   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\MarkoprintLog\push.ps1" -Once
   ```
   A healthy run prints `OK  sent N label(s), M boxes today ...`. It logs to `push-log.txt`.
4. Install the every-minute task (SYSTEM, starts with the PC):
   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\MarkoprintLog\push.ps1" -Install
   ```

## CrowdStrike
It runs from the **same `MarkoprintLog` folder** as the logger, so the existing IOA exclusion
(PowerShell + command line contains `\ProgramData\MarkoprintLog\`) already covers it. As with the
logger, start it by **full path** (as above), not `.\push.ps1` from an open window, or it'll be blocked.

## Check it's working
- `push-log.txt` shows `OK  sent ...` lines once a minute.
- Scheduled task: `Get-ScheduledTask "Chuster Box-Print Pusher" | Get-ScheduledTaskInfo` (LastTaskResult 0 = ok).
- In the app, the Box printer screen's pill turns green **Recording** and the counts match the logger's report.

## Notes / limits
- Counts are **today only**, refreshed each minute (near-instant is fine for inventory; this isn't a control link).
- If the PC is off/asleep, nothing is sent until it's back — same weak spot as the logger (the planned
  dedicated mini-PC in your write-up would remove it).
- Questions on the app side: Zevi's app developer. Questions on the PC/logger side: you.
