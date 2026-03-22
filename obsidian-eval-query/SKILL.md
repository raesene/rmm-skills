---
name: obsidian-eval-query
description: >-
  How to query an Obsidian vault programmatically using `obsidian eval` to search, filter, and analyze notes.
  Use this skill whenever you need to search notes by tag, folder, frontmatter, content, or metadata —
  including finding notes missing frontmatter, listing tags, counting notes, or building any vault-wide query.
  Also use when the user asks to find, list, filter, audit, or report on notes in their Obsidian vault.
  This skill documents a critical syntax restriction in the Obsidian CLI eval command that will cause
  failures if not followed.
---

# Obsidian Eval Query

Use `obsidian eval code='<expression>'` to run JavaScript against a live Obsidian vault. The code runs
in Obsidian's app context with access to the full `app` object (vault, metadataCache, plugins, etc.).

## Critical Syntax Restriction: No `!` negation operator

The Obsidian CLI strips the `!` character from the code before the JavaScript engine sees it. Any
use of `!` — including `!value`, `!==`, and negation in filter callbacks — will silently corrupt
your expression or cause `Invalid or unexpected token` errors.

```bash
# BROKEN — the ! is silently removed, so this becomes => f.path.startsWith(...)
obsidian eval code='files.filter(f => !f.path.startsWith("Templates/"))'

# WORKS — use === false instead of !
obsidian eval code='files.filter(f => f.path.startsWith("Templates/") === false)'

# WORKS — use === undefined instead of !obj
obsidian eval code='files.filter(f => app.metadataCache.getFileCache(f).frontmatter === undefined)'
```

**Workarounds for common `!` patterns:**
- `!value` → `value === undefined` or `value === null` or `value === false`
- `!==` → restructure to use `===` with the positive case, or use `=== false`
- `!a || !b` → split into chained `.filter()` calls using `=== undefined`

All other standard JavaScript works normally in `obsidian eval`, including:
- Curly braces `{}` (block-body arrow functions, object literals, if/else, loops)
- `||` logical OR, `&&` logical AND
- `?.` optional chaining, `??` nullish coalescing
- `===`, ternary `? :`, template literals
- `.filter()`, `.map()`, `.reduce()`, `.slice()`, `.length`
- `JSON.stringify()`, `Object.create(null)`
- Arrow functions (both expression and block bodies)
- `return` is NOT allowed at the top level (eval expects an expression), but works inside
  block-body callbacks like `.filter(f => { ... return x; })`

## Quoting rules

- Use **single quotes** for the outer `code='...'` wrapper (bash level)
- Use **double quotes** for strings inside the JS: `"Containers/"`
- The two quote types nest cleanly

```bash
obsidian eval code='app.vault.getFiles().filter(f => f.path.startsWith("Containers/")).length'
```

## Common API patterns

### Core objects

- `app.vault.getFiles()` — array of all TFile objects (`.path`, `.extension`, `.name`, `.basename`)
- `app.metadataCache.getFileCache(file)` — cached parse of a file with properties:
  - `.frontmatter` — YAML frontmatter as an object, or `undefined` if none
  - `.tags` — array of inline `#tag` objects (from the note body, NOT from YAML frontmatter),
    each with `.tag` (e.g. `"#OpenTelemetry"`) and `.position`
  - `.frontmatterLinks`, `.links`, `.headings`, `.sections`

### Important: Tags live in two places

Obsidian stores tags in two different locations in the metadata cache:

1. **YAML frontmatter tags** — in `.frontmatter.tags` (an array of strings, no `#` prefix)
2. **Inline body tags** — in `.tags` (array of objects with `.tag` property, includes `#` prefix)

Many vaults use inline tags exclusively. To search for a tag reliably, check both:

```bash
# Check inline body tags (the .tags array)
obsidian eval code='app.vault.getFiles().filter(f => f.extension === "md").filter(f => app.metadataCache.getFileCache(f).tags).filter(f => JSON.stringify(app.metadataCache.getFileCache(f).tags).indexOf("OpenTelemetry") >= 0).map(f => f.path)'

# Check YAML frontmatter tags
obsidian eval code='app.vault.getFiles().filter(f => f.extension === "md").filter(f => app.metadataCache.getFileCache(f).frontmatter?.tags).filter(f => JSON.stringify(app.metadataCache.getFileCache(f).frontmatter.tags).indexOf("KubernetesSecurity") >= 0).map(f => f.path).slice(0, 10)'
```

### Recipe: Count files in a folder

```bash
obsidian eval code='app.vault.getFiles().filter(f => f.path.startsWith("Containers/") && f.extension === "md").length'
```

### Recipe: List files missing frontmatter in a folder

```bash
obsidian eval code='app.vault.getFiles().filter(f => f.path.startsWith("Containers/") && f.extension === "md").filter(f => app.metadataCache.getFileCache(f).frontmatter === undefined).map(f => f.path)'
```

### Recipe: List files missing a specific frontmatter field

Find notes that have frontmatter but are missing a particular field (e.g. `Created`):

```bash
obsidian eval code='app.vault.getFiles().filter(f => f.path.startsWith("Containers/Blogs/") && f.extension === "md").filter(f => app.metadataCache.getFileCache(f).frontmatter).filter(f => app.metadataCache.getFileCache(f).frontmatter.Created === undefined).map(f => f.path)'
```

### Recipe: Count files grouped by subfolder

```bash
obsidian eval code='JSON.stringify(app.vault.getFiles().filter(f => f.extension === "md").filter(f => f.path.startsWith("Containers/")).reduce((acc, f) => { const key = f.path.split("/").slice(0, 2).join("/"); acc[key] = (acc[key] || 0) + 1; return acc; }, {}), null, 2)'
```

### Recipe: Count notes per top-level folder

```bash
obsidian eval code='JSON.stringify(app.vault.getFiles().filter(f => f.extension === "md").reduce((acc, f) => { const folder = f.path.split("/").length > 1 ? f.path.split("/")[0] : "(root)"; acc[folder] = (acc[folder] || 0) + 1; return acc; }, {}), null, 2)'
```

### Recipe: Get all tags and counts

Use the built-in CLI command for this — it's simpler:

```bash
obsidian tags sort=count counts
```

### Recipe: Search note content

For text search, prefer the built-in search command:

```bash
obsidian search query="search term" limit=10
```

### Recipe: List files with frontmatter that have a specific field

```bash
obsidian eval code='app.vault.getFiles().filter(f => f.extension === "md").filter(f => app.metadataCache.getFileCache(f).frontmatter).filter(f => app.metadataCache.getFileCache(f).frontmatter.tags).map(f => f.path).length'
```

## Handling large output

When results are large (hundreds of paths), strategies include:

- Use `.length` first to get a count
- Use `.slice(0, N)` to preview a subset
- Use `JSON.stringify(..., null, 2)` for readable object output
- Use `.reduce()` to aggregate into counts by folder or tag

## Combining with other CLI commands

`obsidian eval` is best for vault-wide metadata queries. For other operations, use dedicated commands:

- `obsidian read file="Note Name"` — read a single note's content
- `obsidian search query="term"` — full-text search
- `obsidian tags` — list all tags
- `obsidian property:set` — modify frontmatter properties
- `obsidian create` / `obsidian append` — create or modify notes
