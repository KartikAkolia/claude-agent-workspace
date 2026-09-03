# Using the Productivity Dashboard

## One-time setup

Your `TASKS.md` and `CLAUDE.md` are saved to `Github\productivity\` in your Downloads folder. The dashboard you already downloaded is sitting in `Downloads\` directly (from clicking the file card), one level up. Move `dashboard.html` into that same `Github\productivity\` folder so everything lives together:

```text
C:\Users\Kartik\Downloads\Github\productivity\
    dashboard.html
    TASKS.md
    CLAUDE.md
```

It doesn't have to be that exact folder, the dashboard works from anywhere, but keeping the three files together means you always know where to look.

## Opening it

Double-click `dashboard.html`. It runs entirely in your browser, nothing gets uploaded anywhere. On the Tasks tab you'll see "Select your TASKS.md file", click **Select TASKS.md** and browse to the file in `Github\productivity\`.

This selection doesn't stick between browser sessions. Browsers don't let a local HTML file remember a file handle after you close the tab, for security reasons, so you'll click **Select TASKS.md** again each time you reopen the dashboard. It takes two clicks; that's the tradeoff for a dashboard that needs no server and no login.

## Working with tasks

**Board view** shows four columns: Active, Waiting On, Someday, Done. Drag a card between columns to change its status, or drag within a column to reorder. Click the **+** at the bottom of a column to add a task there. Click a card to expand and edit its text.

**List view** (the toggle next to Board) shows the same tasks as a flat, editable list grouped by section, faster for quickly scanning or bulk-editing than dragging cards around.

Every edit autosaves back to `TASKS.md` on disk about half a second after you stop typing or dragging, you'll see a brief "Saved" confirmation in the corner. Because it's a real file, not something trapped in the browser, I can also read and edit `TASKS.md` directly from a Claude Code or Cowork session and you'll see those changes reflected next time you reopen the dashboard (or via **watch**, if it's already open, the board polls for external edits).

## Memory tab

Click **Memory** at the top, then **Select Folder** and choose `Github\productivity\` (the folder containing `CLAUDE.md`). This is where your working memory lives, the people, projects, terms, and preferences I use to understand shorthand in your requests. Right now it holds one preference: your research standards (only cite authoritative sources, verify before using, document provenance, flag uncertainty), captured from your earlier `/productivity:start` request so I apply it automatically to future research without you restating it each time.

## Keeping it current

Run `/productivity:update` any time you want me to sync new tasks in from wherever you track them, or do a light pass over recent activity for things to add. `/productivity:update --comprehensive` does a deeper scan across connected tools (email, chat, docs, calendar) if you've connected any by then.

## Dark mode

There's now a small sun/moon toggle in the top-right corner, next to Select File. Click it to switch between light and dark, your choice is remembered in the browser (not in `TASKS.md`), so it'll still be dark the next time you open the dashboard in that browser, before you even select a file.

## Applying this to the task you gave me

The research task you handed me under `/productivity:start`, "find Windows packages for titus-ai with Claude Code," is already in `TASKS.md`'s **Done** column, with a note pointing to the delivered research file. Opening the dashboard now, you'd see it there rather than in Active. The general pattern for next time: give me a task in plain language, I'll add it to Active, work it, and move it to Done with a pointer to whatever I produced, same as this one.
