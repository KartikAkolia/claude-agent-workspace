# Gmail organizing prompt

A reusable prompt for a fresh Claude chat with the Gmail MCP connector enabled, to help Kartik organize his Gmail inbox. Paste the prompt below as-is; it's self-contained.

## Context (as of 2026-08-29)

A quick read-only survey (`list_labels` + `search_threads`) before writing this prompt found:

- **Inbox**: ~111 threads by label count / Gmail's search estimate said 201 — worth reconciling, but either way not a small pile. 0 unread in inbox.
- **Custom labels**: only two — `English_Tutoring` (7 threads) and `Joanna` (48 threads, nearly half the inbox on one label).
- **Leftover cruft**: `Conversation History` and `[Imap]/Drafts` — empty legacy labels from an old IMAP client, not in active use.
- **Trash**: 53 messages, 21 unread — things got trashed without being read.
- **Spam**: 1 message.

This means "organize" here isn't inbox-zero triage of a firehose — it's a moderately sized inbox with almost no taxonomy beyond one heavy per-person label. The prompt below is written for that shape, not a generic Work/Personal/Finance template.

Open decisions Kartik can revisit before running this:

1. **Execution mode** — the prompt defaults to: labels applied freely, but archive/trash/delete always proposed first for confirmation. Change step 4/5 if a different balance is wanted.
2. **Taxonomy** — the prompt defaults to data-driven categories inferred from actual senders/subjects, keeping `Joanna` and `English_Tutoring` as-is. Swap in a fixed category list if preferred.

## The prompt

```text
You have access to my Gmail via the Gmail MCP tools. Help me organize my inbox. Work in this order and don't skip the survey step:

1. SURVEY (read-only): Call list_labels, then search_threads across in:inbox to
   get a sense of volume, senders, and subjects. Note anything odd (e.g.
   unread items sitting in Trash, empty/unused legacy labels, a single label
   that dominates the inbox).

2. PROPOSE A TAXONOMY: Based on actual sender/subject patterns (not a generic
   template), propose a small set of new labels — aim for 5-8, not 20. Keep my
   existing labels (English_Tutoring, Joanna) as-is unless you spot a clear
   overlap. Call out any senders that clearly deserve a dedicated label the
   way "Joanna" does (i.e. one contact/thread with disproportionate volume).
   Show me the proposed taxonomy and wait for my confirmation before creating
   any labels.

3. CLEAN UP DEAD LABELS: Point out labels with 0 messages that look like
   leftovers (e.g. old IMAP client labels) and ask before deleting them.

4. LABEL IN BATCHES: Once I approve the taxonomy, create the labels and apply
   them in batches of ~20 threads. After each batch, give me a one-line
   summary (label -> count) before continuing to the next batch.

5. FLAG, DON'T ARCHIVE OR DELETE: For anything you'd normally archive or
   trash (old newsletters, resolved threads, promotions), don't do it — list
   candidates with a one-line reason and let me confirm the batch. Never
   permanently delete anything without explicit confirmation in that message.

6. UNSUBSCRIBE CANDIDATES: Separately list senders that look like
   newsletters/marketing based on volume and unsubscribe headers/snippets, so
   I can decide which to unsubscribe from — don't take that action yourself.

7. ANOMALIES: Specifically check Trash for unread messages and Spam for
   anything that looks miscategorized, and flag both before touching them.

Stop and wait for my input at every step marked "wait for confirmation" above
— don't chain multiple destructive or bulk actions without a checkpoint.
```
