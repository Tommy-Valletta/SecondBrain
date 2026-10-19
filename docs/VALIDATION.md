# Validate your SecondBrain setup

[Overview](../README.md) · [Technical README](../README.technical.md) · [Setup](../BOOTSTRAP.md)

Use these checks to confirm the template and engine behave as expected in your environment. Start with temporary examples, then evaluate the complete integration with your chosen agent and model.

## Run the portable tests

From the repository root:

```sh
python3 -m unittest discover -s tests -v
python3 .claude/scripts/test-frontmatter.py
```

The suite creates temporary fictional data and exercises:

- Named index reads and index listing.
- Rejection of traversal, absolute paths, and directory targets.
- Symbolic-link boundaries, when the operating system permits creating links.
- Exact prompt-tag matching and its documented synonym, quoting, and short-tag behavior.
- Frontmatter updates that preserve quoted metadata in the body of a note.
- Session-end status transitions and promotion-failure bookkeeping with synthetic records.

The suite does not need model credentials, MCP registration, or installed agent hooks. Inspect skipped cases: a skipped test is not a passing result.

## Check the engine in your environment

1. Configure the agent and model using the [setup guide](../BOOTSTRAP.md).
2. Create a fictional source and a project page with a specific `tech_surface` tag.
3. Confirm a disposable session produces a capture record with the correct source link.
4. Process one captured session and one deliberately added source. Read their summaries for accuracy.
5. Run `python3 .claude/scripts/compile-wiki.py backlinks indexes` twice. Check that content stays stable, allowing for generated timestamps and logs.
6. Confirm an exact-tag prompt surfaces the intended project pointer. Test alternative wording as well.
7. Enable scheduling after a manual cycle succeeds, then inspect the job status and completed-run log.

## Measure retrieval quality

Choose recurring questions about your own notes and decisions. Compare fresh sessions using normal prompting, explicitly requested retrieval, and directly provided reference context.

Score each response separately for:

| Dimension | What to look for |
| --- | --- |
| Retrieval | Finds the relevant page and supporting source |
| Application | Applies the decision and its conditions correctly |
| Freshness | Recognizes newer or superseding information |
| Evidence | Gives traceable source references |
| Uncertainty | Identifies missing evidence without inventing an answer |

Include synonymous wording, changed decisions, and conflicting sources. More notes and successful processing jobs are useful operational signals; answer quality needs its own evaluation.

## Recorded baseline checks

These results were recorded on 2026-10-19:

| Check | Result |
| --- | --- |
| Portable unit suite | 10 tests: 7 passed, 3 skipped because the Windows account could not create symbolic links |
| Frontmatter regression suite | 4 tests passed using synthetic records, including session-end status transitions and promotion-failure handling |
| Model configuration | Default/explicit model selection and configurable environment omission checked with local CLI stubs |
| Python syntax | 10 files parsed successfully |
| Bash syntax | 24 scripts passed `bash -n` |
| Mechanical compilation | Repeated runs on a temporary vault with a fictional summary produced stable content, allowing for generated timestamps and logs |

These checks cover individual engine behaviors. Use the integration steps above to verify capture, model ingestion, scheduling, and retrieval with your chosen configuration.
