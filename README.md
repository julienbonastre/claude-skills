# claude-skills

Shareable [Claude Code](https://claude.com/claude-code) skills.

Each skill lives under `skills/<name>/` and is self-contained (a `SKILL.md`
plus any helper scripts/config). To use one, copy its folder into your
`~/.claude/skills/` directory.

## Skills

| Skill | What it does |
|-------|--------------|
| [`snow-change`](skills/snow-change/) | Create, update, or transition a ServiceNow Normal Change via the Table API. |

## Installing a skill

```bash
cp -r skills/<name> ~/.claude/skills/<name>
```

Then follow that skill's `SKILL.md` for any per-skill setup (e.g. config files,
credentials). Skills are instance/org-agnostic — fill in your own values via the
documented config files; never commit secrets.
