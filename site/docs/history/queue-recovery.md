# Queue & Recovery

Manage recordings waiting to process and work that needs attention in **Queue & Recovery** in the menu bar window.

The queue section in the menu bar panel only appears when something is queued, paused or failed. You can also right-click the menu bar icon for **Stop Processing** or **Process Queue**.

## Errors and warnings

Problems no longer replace each other. Errors and warnings stack at the top of the menu bar panel (the newest first), and the ones that belong to a recording also show when you open that recording in the viewer. Each has a button to fix it where possible: **Show Queue & Recovery**, **Integrations…**, **Open Recording**, **Retry Recovery** or **Show Files**.

When processing or reprocessing fails, you also get a notification; click it to open the recording. A recording that finished but had a step go wrong shows **Finished with issues** and offers the matching fix, such as **Re-run AI Analysis…** or **Integrations…**.

## Process recordings in order

dBrief processes one job at a time. You can keep recording while a previous meeting is being processed. Recordings finished during that work enter the automatic queue; recordings you defer wait for **Process queue**.

Expand a queued recording to **Process now**, **Move to first**, **Move up**, **Move down**, or **Remove** it from the queue. Removing an item keeps its audio.

**Pause queue** lets the current job finish and prevents the next automatic job from starting. The pause and ordering survive a restart. Use **Resume automatic queue** to allow automatic jobs to continue, or **Process queue** to process deferred recordings too. **Stop** on the current job stops it; its saved progress stays available for recovery.

## Resume interrupted processing

A stopped, failed, or interrupted job stays available for **Resume**. dBrief keeps completed stages so you do not need to repeat the whole pipeline. If speaker confirmation is required, you will still be asked to review the speakers.

When a resumed job finishes, it sends its integrations like a normal run. Stopped or failed jobs do not keep retrying on their own.

## Recover an interrupted recording

If dBrief or your Mac stops during capture, the next launch looks for saved capture tracks, finalizes recoverable audio, and adds it to History. A banner reports the result. If recovery cannot finish, the raw tracks are kept; reconnect unavailable storage and use **Settings → About → Diagnostics → Recovery files → Show in Finder** to locate them.

For support, **Settings → About → Diagnostics → Export diagnostics…** creates a report of app and recovery events without audio, transcript content, meeting titles, names, paths, or credentials.

## Retry an integration

Unfinished deliveries appear here with an **Integrations…** action. You can also use the **Integrations** chip on a recording in [Recording History](recording-history.md), or right-click a recording and choose **Integrations…**. Pick one destination, or **All remaining** to retry every unfinished one together, and click **Send**. dBrief reuses the content already generated, without retranscribing or rerunning AI. A destination with confirmed delivery is not sent again, and retries only add what's missing: Todoist, TickTick and Notion never get duplicate tasks or pages.

If the previous outcome is uncertain, or the destination settings have changed, dBrief asks you to review before retrying. Check the destination first to avoid creating a duplicate.

## Reprocessing attempts

Unfinished [reprocessing](reprocessing.md) appears here with **Resume** and **Discard attempt**. Discarding an attempt preserves the saved recording results. Deleting the recording also removes its queue and recovery entries; previously exported notes and external deliveries remain separate.
