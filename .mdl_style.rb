all

# This repo writes prose as long unwrapped lines by convention (AGENTS.md:
# "Markdown throughout. Prose over bullet lists...") — line-length is noise here.
exclude_rule 'MD013'

# Bolded labels above tables (e.g. "**build**") are used as compact grouping
# labels, not mistaken headers.
exclude_rule 'MD036'

# CLAUDE.md/GEMINI.md files across this repo are deliberately a single
# "@AGENTS.md" include line, not a headed document.
exclude_rule 'MD041'

# This repo numbers ordered lists sequentially (1. 2. 3.), not the "all 1."
# style mdl defaults to.
rule 'MD029', :style => :ordered

# Docs repeat the same subheading set per section on purpose (e.g. ROADMAP.md's
# "### Objective" / "### Outcomes" under every phase) — only flag true
# same-level duplicates.
rule 'MD024', :allow_different_nesting => true

# Don't flag tabs inside fenced code blocks quoting real script content.
rule 'MD010', :ignore_code_blocks => true

# Question-form headings (e.g. "## Is X actually Y?") are legitimate; only
# flag the punctuation marks that are never intentional in a heading.
rule 'MD026', :punctuation => '.,;:!'
