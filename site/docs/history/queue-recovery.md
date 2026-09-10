# Queue & Recovery

Manage recordings waiting to process and work that needs attention in **Queue & Recovery** in the menu bar window.

## Process recordings in order

dBrief processes one job at a time. You can keep recording while a previous meeting is being processed. Recordings finished during that work enter the automatic queue; recordings you defer wait for **Process Queue**.

For each queued recording, you can run it individually, move it up or down, move it to the front, or remove it from the queue. Removing an item keeps its audio.

**Pause Queue** lets the current job finish and prevents the next automatic job from starting. The pause and ordering survive a restart. Use **Resume Automatic Queue** to allow automatic jobs to continue, or **Process Queue** to process deferred recordings too.

## Resume interrupted processing

A stopped, failed, or interrupted job stays available for **Resume**. dBrief keeps completed stages so you do not need to repeat the whole pipeline. If speaker confirmation is required, you will still be asked to review the speakers.

Recovery finishes the Markdown note without automatically sending integrations. Review delivery separately before continuing. Stopped or failed jobs do not keep retrying on their own.

## Recover an interrupted recording

If dBrief or your Mac stops during capture, the next launch looks for saved capture tracks, finalizes recoverable audio, and adds it to History. A banner reports the result. If recovery cannot finish, the raw tracks are kept; reconnect unavailable storage and use **Settings → About → Show recovery files** to locate them.

For support, **Settings → About → Export diagnostics…** creates a report of app and recovery events without audio, transcript content, meeting titles, names, paths, or credentials.

## Retry an integration

Unfinished deliveries appear with an **Integrations** action. Retry a destination using the content already generated, without retranscribing or rerunning AI. A destination with confirmed delivery is not sent again.

If the previous outcome is uncertain, or the destination settings have changed, dBrief asks you to review before retrying. Check the destination first to avoid creating a duplicate.

## Reprocessing attempts

Unfinished [reprocessing](reprocessing.md) appears here with **Resume** and **Discard attempt**. Discarding an attempt preserves the saved recording results. Deleting the recording also removes its queue and recovery entries; previously exported notes and external deliveries remain separate.
