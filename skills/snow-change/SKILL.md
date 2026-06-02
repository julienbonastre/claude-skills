---
name: snow-change
description: Create, update, or transition a ServiceNow Normal Change via the Table API. Use when the user asks to raise/update/move a SNOW change for an impacting card.
user-invocable: true
argument-hint: <create|update|transition|close|get|list> [CHG-number|sys_id] [--from PROJ-XXXX] [--state <n>] [--field value ...]
---

# ServiceNow Change Management

Manage **Normal Changes** via the ServiceNow **Table API**
(`/api/now/table/change_request`). Instance host, accounts, and any
org-specific field defaults are read from config (`.snow-env` + keychain), not
hard-coded here — so this skill is portable across ServiceNow instances.

> Note: some field IDs, choice values, and the Change Scripted-REST
> availability below were probed on one specific instance. Treat them as a
> strong starting point and re-probe (`snow.sh get <CHG>`) against your own
> instance before relying on them. On the reference instance the Change
> Scripted REST (`sn_chg_rest`) is **not installed** — use the Table API.

**Scope:** Normal changes only. Standard (SCP) and Emergency are out of scope —
stop and ask if requested. The skill's job is primarily **create** and
**update** — lifecycle **transitions** (peer review → approval → implement →
close) are normally driven by the operator through the standard CAB/business
process, so `transition` is available but secondary; don't drive a change
through its gates unless explicitly asked.

The brain of this skill is the **plan → ITSM translation**: take the agreed
phases, risks, and rollback from a card/PR and render them into the right
ServiceNow attributes. The plumbing is the `snow.sh` helper.

## Auth & helper

Auth is **HTTP Basic** (per-env service account). All calls go through
`~/.claude/skills/snow-change/snow.sh`. Non-secret config lives in `.snow-env`
(base URLs + usernames per env); passwords are in the macOS Keychain (service
names per env) and reach curl via `-K -` so they never appear in `argv`/`ps`.
Point `.snow-env` at your own instance + accounts — nothing instance-specific
is baked into this doc.

**Environments — default `dev`, promote DEV → TEST → PROD.** Select with
`--env dev|test|prod` (or `SNOW_ENV`). The per-env account usernames live in
`.snow-env`; note that some orgs drop the `_prod` suffix on the prod account,
so don't assume a symmetric naming scheme — read it from config.

```
snow.sh --env <env> whoami            Verify auth + identity
snow.sh --env <env> get <CHG|sys_id>  Full record (all fields, display+value)
snow.sh --env <env> list [n]          Recent normal changes
snow.sh --env <env> mine [n]          Normal changes opened by current API user
snow.sh --env <env> group <fragment>  Lookup assignment_group sys_id
snow.sh --env <env> ci <fragment>     Lookup cmdb_ci sys_id
snow.sh --env <env> user <fragment>   Lookup sys_user sys_id
snow.sh --env <env> create '<json>'
snow.sh --env <env> update <id> '<json>'
snow.sh --env <env> transition <id> <state-value>
snow.sh --env <env> raw <METHOD> <path> [json]
```

**Prereqs:** `curl` and `jq` (the helper fails fast with an install hint if
either is missing).

**Setup:** copy `.snow-env.example` → `.snow-env`, fill in your instance URLs,
account usernames, and Keychain prefix, then store each env's password in the
Keychain (`security add-generic-password -U -s "<prefix>-<env>" -a "<user>"
-w`). `.snow-env` is git-ignored — never commit it.

**PROD write guard:** create/update/transition/close against `--env prod` refuse
unless `SNOW_PROD_WRITE_OK=1` is exported. Only export it after explicit user
go-ahead in the same turn. Reads are always free.

Table-API field shape (with `sysparm_display_value=all`):
`{"field": {"display_value": "...", "value": "..."}}`. On **read**, prefer
`.value` for IDs/enums and `.display_value` for human text. On **write**, send
plain `{"field": "value-or-id"}`.

## Credentials & discovery pattern

Each env authenticates with its own service account (see Auth above). If a
non-prod env's creds are unavailable (e.g. rotated/expired and not yet
re-issued), fall back to this pattern rather than guessing field shapes:

- Do **field-mapping discovery as reads** against whichever env authenticates.
- Create **one iterable test change** and refine fields by repeatedly
  `update`-ing the same record rather than spawning new CHG numbers.
- Back-revert/close it when finished.

## Field conventions (probed from real changes)

### State enum (Normal lifecycle, confirmed values)

| value | display | typical gate |
|------:|---------|--------------|
| `0`   | Draft | initial create |
| `2`   | Under Review | author review |
| `50`  | Peer Review | peer reviewer signoff |
| `19`  | Prepared | ready for CAB/approval |
| `30`  | Under Approval | awaiting approvers |
| `40`  | Approved | ready to implement |
| `5`   | Implementation in Progress | window started |
| `11`  | Awaiting BVT | post-implementation validation |
| `7`   | Closed | done |

Numbers are **string-encoded** on the API (`"state": "40"`, not 40).

### Heavy `u_*` customisation — do NOT use stock fields

This instance uses custom fields for almost all content. Map to these:

| Content | Field |
|---|---|
| Implementation plan / steps | `u_implementation_plan` |
| Backout plan | `u_backout_plan` |
| Post-implementation test plan | `u_post_implementation_test_plan` |
| Pre-implementation testing performed | `u_pre_implementation_testing` |
| Comms plan | `u_comms_plan` |
| Risk & impact commentary | `u_risk_and_impact_comments` |
| Classification | `u_classification` (`Minor` is the common value) |
| Additional treatment | `u_additional_treatment` — default "Change will be applied during business downtime" |
| Additional treatment 2 | `u_additional_treatment_2` — default "Change is repeatable and has been performed recently and successfully in the past" |
| Additional treatment 3 | `u_additional_treatment_3` — default "Implementation steps will be applied to a high availability design" |

The three `u_additional_treatment*` fields are choice fields whose **stored
value is the full sentence text** (no number prefix). Send the literal sentence
on write. These defaults suit scripted IaC change work — **surface them to the
user during the risk/eval step and confirm before straying.**

### Risk scoring — populate the scorers, NOT `risk`/`impact` directly

`risk` and `impact` are calculated from these scorer fields. Set the scorers; the
calculated values follow. The values below are a low-risk IaC baseline (a
scripted/automation change with a tested backout, affecting non-prod or
well-tested config):

| Field | Value | Display meaning |
|---|---|---|
| `u_impact_level` | `6` | "1. Likelihood OR level of impact to stakeholders extremely low" |
| `u_applications_impacted` | `0.30` | "1. Extremely low likelihood of unexpected impact on applications" |
| `u_deployment_technique` | `0` | "1. Deployed via scripts/automation, no manual intervention" |
| `u_backout_ability` | `5` | "4. Backout plan has been tested and the change can be backed out easily" |
| `u_pre_implementation_test_coverage` | `0` | "3. Completely tested or only affects non-production" |
| `u_impact_type` | `This change has extremely low likelihood of unexpected impact on applications` | "3. …" — choice field, **stored value is the sentence text, not a number**; default option 3 |

Use these defaults for scripted IaC work; revise upward if the work genuinely
warrants a higher rating. **`u_impact_type` defaults to option 3** and is **not
auto-set on create** — populate it explicitly (the form shows `-- None --`
until you do).

### Approvers / reviewers / groups

| Field | What goes here |
|---|---|
| `assignment_group` | Owning team sys_id — resolve with `snow.sh group <fragment>` |
| `u_change_implementation_groups` | Usually same sys_id as `assignment_group` |
| `u_piv_groups_technical` | Technical PIV (Post Implementation Validation) group sys_id |
| `u_change_approvers` | Comma-sep sys_ids of approver users |
| `u_peer_reviewers` | Comma-sep sys_ids of peer reviewer users |
| `u_change_review_groups` | Comma-sep sys_ids of review groups (e.g. an approval group + a compliance-review group) |
| `assigned_to` | sys_id of the implementer |
| `opened_by` | Auto-set to the API caller |

Use `snow.sh group <fragment>` / `user <fragment>` / `ci <fragment>` to look up
sys_ids on demand.

### CI fields

- `cmdb_ci` — single primary CI sys_id. Resolve by name with
  `snow.sh ci <fragment>` (e.g. a cloud-platform or application CI).
- `u_ci_list` — comma-sep sys_ids for additional CIs affected by the change.

### Dates & timezone

The API `value` field is **UTC** (`YYYY-MM-DD HH:MM:SS`); the `display_value` is
the **instance-local** TZ (`DD/MM/YYYY HH:MM:SS`). When the user gives a window
in local time, convert to UTC before writing `value`. Determine the instance TZ
from a `get` (compare a record's `value` vs `display_value`) rather than
assuming — it varies by instance.

### Title and description style

- **Short description**: `<TICKET-KEY> | <action> | <where>` —
  e.g. `PROJ-1234 | Implement Org Policy Constraints | Prod Folder`.
  Outage-class changes prepend `[Outage]`.
- **Description** — generous whitespace, **double** `\r\n` between sections.
  Structure:
  1. Short description repeated on line 1.
  2. Blank line, then a "The purpose of this change is …" paragraph.
  3. Blank line, then a risk/intent paragraph if warranted.
  4. **`Expected Impact / In-scope targets:`** heading, then a `-` bullet list
     of the in-scope envs/targets (org / folder / stage / bindings). Always
     state data-plane vs control-plane and "no customer-facing impact" if true.
  5. **`References:`** block at the very bottom — a `-` link line for each
     applicable: repo URL, the GitHub **PR(s)**, the design/wiki page, and
     every related **issue-tracker ticket**. Link each; never plain-text a
     ticket.

### Content style (implementation/backout/test/comms plans)

- Numbered steps separated by `\r\n` (CRLF — that's how SNOW stores rich text
  from the form).
- Reference the repo, PR link, and issue-tracker ticket inline.
- Backout: short and concrete ("If workflow run fails, changes reverted to
  previous active state.").
- Comms: list channels / teams / business notification recipients.

## Procedure

**Outcome of `create` = a Draft change + its URL, handed back to the operator.**
The skill builds the record up to Draft and stops; the operator opens the link
as their **human-in-the-loop gate** — fine-tunes wording, then moves it to Peer
Review themselves. Don't transition past Draft (see Scope).

### create
1. Resolve source context (`--from <TICKET-KEY>`, current PR, or conversation),
   then pick a **seed mode**:
   - **Clone from a reference change** — when a historical change for the same
     CI(s) / similar process exists, `get` it and anchor field shape on it.
     Best default for recurring change types.
   - **Fresh slate** — no close precedent. Resolve the CI(s) yourself:
     ask the operator for the application/CI, `snow.sh ci <fragment>` to find
     the sys_id(s), and confirm which go in `cmdb_ci` (primary) vs `u_ci_list`
     (additional), and whether each is genuinely "updated by" this change.
2. Map plan/design/risk → the field tables above (clone a prior similar change
   as the anchor where one exists).
3. Look up any unknown sys_ids (`group`/`user`/`ci`).
4. **Risk/eval interview — surface the defaults and confirm before create.**
   These are operator judgement calls, not silent auto-fills. Walk the user
   through and let them stray from defaults:
   - the five risk **scorers** (`u_impact_level`, `u_applications_impacted`,
     `u_deployment_technique`, `u_backout_ability`,
     `u_pre_implementation_test_coverage`),
   - `u_impact_type` (default option 3),
   - the three `u_additional_treatment*` fields (defaults above).
   Then note: `risk`/`impact` are **calculated** — read them back after create,
   don't promise a rating from the scorers.
6. **Show the user a full preview of the JSON body before writing.**
7. On confirmation:
   - For prod: have the user export `SNOW_PROD_WRITE_OK=1` for that call.
   - `snow.sh --env <env> create '<json>'`.
8. Report the new `number` + sys_id + URL
   (`<base>/nav_to.do?uri=change_request.do?sys_id=<sys_id>`).

### update
1. `snow.sh get <id>` first to see current values.
2. Build a minimal patch; preview it.
3. `snow.sh update <id> '<json>'` (prod-write-guarded).

### transition
1. `snow.sh get <id>` and confirm current state.
2. Confirm target state value is a legal next step (state-enum table).
3. **Warn loudly** if it crosses an approval/CAB gate (Under Approval → Approved,
   or anything → Implementation in Progress). Require explicit user go-ahead.
4. `snow.sh transition <id> <state-value>`.

### close
Populate the **Closure Information** fields after a change has been implemented.
Only act on an **explicit** "close it" instruction from the operator — that
instruction is the guardrail (closure is an administrative wrap-up, not a
privileged create/approve).

1. `snow.sh get <id>` and read back the implementation outcome (apply results,
   any incidents).
2. **Close child change tasks first, scoped to the operator's remit** (a change
   cannot complete while its CTASKs are open):
   - `snow.sh tasks <id>` — list the CTASKs with their `state` + `assignment_group`.
   - `snow.sh my-groups <operator-user-or-email>` — the operator's active
     assignment-group memberships. **Resolve the OPERATOR (the human who said
     "close it"), NOT the API service account** — the SA's own memberships are
     irrelevant and usually empty.
   - For each OPEN task: close it **only if its `assignment_group` is one of the
     operator's groups**. `snow.sh close-task <ctask-sysid> '<json>'` with e.g.
     `{"state":"3","close_code":"successful","close_notes":"…"}` (state 3 =
     Closed Complete; `change_task` close_code choices differ from the parent —
     probe via `sys_choice` on `change_task`).
   - **Skip + report** any task whose group the operator is NOT in — that team
     owns its own closure. Never close out-of-remit tasks. Cancelled/already-
     closed tasks: leave alone.
3. Map the outcome → the parent closure fields (table below). Use the real
   result — `close_code` should reflect whether it caused incidents / rolled back.
4. **Preview the JSON**, then `snow.sh close <id> '<json>'` (prod-write-guarded).
5. **`close` writes the FIELDS only — it does NOT advance the state to Closed.**
   On instances where the change lifecycle is workflow-driven (observed on the
   reference instance), the final transition (Implementation → Awaiting BVT →
   Review → Closed) is a workflow action behind the form's "Complete
   Implementation" / "Close" button and is **not** settable via the Table API
   `state` field — a direct `state=7` (or even the legal next step) PATCH is
   silently ignored. So: populate fields here, then have the operator click the
   UI button (the mandatory fields will already be filled). Re-probe your own
   instance — if a direct state set works there, follow `close` with
   `transition`.

#### Closure-Information fields (verify against your instance)

| Form label | Field | Values (reference instance) |
|---|---|---|
| Close code | `close_code` | choice — e.g. `successful`, `successful_with_learnings`, a P4-incident option, a P1/P2/P3-incident option, `unsuccessful_rollback`. **Probe with `sys_choice`** (below) — labels/values are instance-specific. |
| Implemented according to plan? | `u_implemented_to_plan` | `yes` / `no` / `Partial` |
| Unexpected incidents caused? | `u_caused_incidents` | `yes` / `no` |
| Delivered expected benefit? | `u_expected_benefit_delivered` | `yes` / `no` / `partial` |
| Implemented to procedure? | `u_implemented_to_procedure` | `yes` / `no` |
| Close notes | `close_notes` | free text — outcome summary |
| Implementation TVT completed | `u_implementation_tvt_completed` | datetime (UTC on the wire) |
| Actual start / end | `work_start` / `work_end` | datetime (UTC on the wire) |

Probe the exact choice values for any choice field:
```
snow.sh raw GET "/api/now/table/sys_choice?sysparm_query=name=change_request^element=close_code^inactive=false^language=en&sysparm_fields=label,value,sequence"
```
The `u_*` field names and choice values above were probed on one instance —
**re-probe before relying on them**; other orgs' closure forms differ.

### get / list / mine
Read-only. Use freely.

## Guardrails

- **Default to `--env dev`.** While dev/test are 401'ing, **prefer prod reads
  + a single iterable prod test change** — never silently switch to test.
- **Promote DEV → TEST → PROD** once non-prod creds are restored.
- **PROD writes are guarded.** Only export `SNOW_PROD_WRITE_OK=1` after
  explicit user go-ahead in the same turn.
- **Preview before every write.** No silent create/update/transition/close.
- **Close only on an explicit instruction.** `close` writes closure fields but
  never advances the lifecycle state (that's a UI/workflow action). The explicit
  "close it" from the operator is the guardrail.
- **Normal changes only.** Standard/Emergency → stop and ask.
- **Never cross a CAB/approval gate without explicit user confirmation.**
- **Dates: local input, UTC on the wire.** Confirm the window with the user.

## Issue-tracker linkage — a REQUIRED part of creating a change

The change and its source ticket stay in lockstep. This is **part of the job of
creating a change**, not optional polish — do it inline. (Steps below assume a
Jira source via the Atlassian tooling; adapt the field/comment mechanics to
your tracker.)

1. **Set the tracker's "ServiceNow Link" URL field** on the source ticket,
   **once, on create**. Value = the change URL
   (`<instance>/change_request.do?sys_id=<sys_id>`). The custom-field id is
   tracker/instance-specific — discover it once and record it in your project
   config, don't assume.
2. **Add ONE lean comment** on the source ticket on create — ~2 lines — using
   rich content (e.g. Jira ADF) so it carries two live nodes:
   - the **CHG number as a hyperlink** to the change URL; do **not** restate
     the URL as plain text.
   - the **peer reviewer as a real `@mention`** node — pings them through the
     tracker's notifications, a second surface beyond the SNOW email. Resolve
     the reviewer's tracker account id (e.g. `lookupJiraAccountId`) — it is
     **not** the SNOW reviewer sys_id (separate systems).

   The comment carries only: change **title**, **type** (Normal), **window**,
   and the **@peer-reviewer**. Rendered shape:

   > ServiceNow Normal change [CHGxxxxxxx](<url>) created — *PROJ-NNNN |
   > <short change title>*.
   > Window: DD/MM/YYYY HH:MM–HH:MM <TZ> · Peer reviewer: @<Reviewer>.

   Leave **out** risk/impact, assignment group, CIs, requested/assigned-to, and
   any plan detail. On later **updates** a comment is **optional** — only add
   one if the change is materially significant to ticket watchers; routine
   field tweaks need none.

Shared-state writes visible to others: the building agent normally has the
ticket in context and does this inline. Only when working a change **out of
band** should you pause to confirm the target ticket and that no other agent
owns it.

## Gotchas (verify against your instance)

- **Risk is NOT a straight "all-low scorers ⇒ Low".** Feeding the low-baseline
  scorers above can still calculate to **Moderate**. Don't promise a rating
  from the scorers alone — let the instance calculate, then `get` it back.
- **`u_ci_list` read-back may show only the first CI** — confirm whether the
  additional sys_ids actually persisted or it's just display truncation.
- The POST response renders some fields blank/raw (e.g. assignment_group, and
  dates as UTC not local); always `get` the record back to verify.

## Examples

```
/snow-change list 5
/snow-change get CHGxxxxxxx
/snow-change --env prod mine
/snow-change create --from PROJ-1234
/snow-change update CHGxxxxxxx --u_implementation_plan "…"
/snow-change transition CHGxxxxxxx 2
/snow-change close CHGxxxxxxx '{"close_code":"successful","u_implemented_to_plan":"yes","u_caused_incidents":"no","close_notes":"…"}'
```
