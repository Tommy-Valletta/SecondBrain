# Move your notes into SecondBrain

Start with a few notes from one project. Keep your original collection and bring more across after the first trial succeeds.

[From Obsidian](#from-obsidian) · [From Notion](#from-notion) · [Process your first note](#process-your-first-note)

## Prepare your copy

1. On the [SecondBrain repository](https://github.com/Tommy-Valletta/SecondBrain), select **Use this template**, create a new repository, and choose **Private**.
2. Clone your new repository to your computer. This folder is your SecondBrain library.
3. Complete the [setup guide](../BOOTSTRAP.md) before processing notes. The engine needs a configured agent and model; the included scripts target Claude Code/Pi and a macOS-oriented shell environment. Other environments need adaptation.

Then follow the route for your current app.

## From Obsidian

Obsidian stores notes as Markdown files in a local folder called a vault. See [Obsidian's vault guide](https://help.obsidian.md/manage-vaults).

1. **Find your vault folder** in Finder or File Explorer. Make a backup before starting.
2. **Choose three to five notes** about one project. Include a linked note or image if you use those features.
3. **Copy them into `raw/imports/obsidian/`** inside your SecondBrain folder. Create that folder if needed. Keep related subfolders and attachment files together so relative paths have a chance to remain valid.
4. **Open the copied notes and check their links and images.** Obsidian-specific features, plugins, and vault-wide links may need adjustment. The Markdown notes are the starting point; plugin behavior does not transfer with them.

You can optionally open the SecondBrain folder in Obsidian using **Manage Vaults → Open folder as vault**, following the [official instructions](https://help.obsidian.md/manage-vaults). This lets you inspect the imported notes and generated summaries in the same editor.

Continue to [Process your first note](#process-your-first-note).

## From Notion

Use Notion's [Markdown & CSV export](https://www.notion.com/help/export-your-content) for a small set of pages first.

1. **Open a page** you want to bring across. In its **•••** menu, choose **Export**.
2. **Choose Markdown & CSV.** Turn on **Include subpages** if you want the pages underneath it too, then export.
3. **Unzip the download.** Keep the Markdown files and their related folders and assets together.
4. **Copy the export into `raw/imports/notion/`** inside your SecondBrain folder. Create that folder if needed, then open a few Markdown files to check the content and links.

Notion databases export as CSV, with Markdown files for subpages. Keep the CSV as a reference; convert the information you need into Markdown notes before ingestion. Database views, formulas, relations, and permissions are not recreated by this guide.

Continue below. These copies are a one-time import; later edits in Obsidian or Notion do not automatically sync into SecondBrain.

## Process your first note

Run these commands through your configured Claude Code or Pi session, starting in the SecondBrain repository folder. Replace the example path below with one of your copied `.md` files.

In a standalone terminal, the script defaults to Pi. To select Claude Code there, prefix the ingestion commands with `CLAUDE_CODE_ENTRYPOINT=cli` (for example, `CLAUDE_CODE_ENTRYPOINT=cli bash .claude/scripts/ingest-source.sh --dry-run "raw/imports/obsidian/Example.md"`).

1. **Preview one import.** This shows the planned source and summary paths without calling a model or writing a summary:

   ```sh
   bash .claude/scripts/ingest-source.sh --dry-run "raw/imports/obsidian/Example.md"
   ```

2. **Generate its summary** after checking the preview:

   ```sh
   bash .claude/scripts/ingest-source.sh "raw/imports/obsidian/Example.md"
   ```

   This calls your configured model. Read the new file under `wiki/summaries/` and check its source reference and factual accuracy.

3. **Refresh navigation** after reviewing the summary:

   ```sh
   python3 .claude/scripts/compile-wiki.py backlinks indexes
   ```

4. **Try a real question.** Ask your configured agent to use the imported notes and reviewed summary, answer a question about the project, and cite the source. Add a project page using [the setup guide's seeding steps](../BOOTSTRAP.md#5-seed-useful-context) if you want exact-tag project pointers.

For a Notion import, substitute the path under `raw/imports/notion/` in the commands above.

## Before bringing across more

- Confirm a copied note opens, a summary points to it, and an answer uses the right evidence.
- Check images and links; copying files does not rewrite every app-specific reference.
- Watch for duplicate filenames. Summary names use the source title or filename, so different notes can collide; give imported copies distinct titles or filenames before processing them, and recheck affected links.
- Keep your original library and export as backups. Grow the import in manageable batches.

[Back to SecondBrain](../README.md) · [Setup](../BOOTSTRAP.md) · [Technical details](../README.technical.md)
