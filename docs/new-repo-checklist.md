# New repository checklist (relaton org)

Every repository created under the relaton org must carry the standard team
grants **at birth**. Repo creation does NOT add them automatically, and
missing grants leave team members without access (this happened through
2026: newer repos — relaton-api-js, relaton-ts, several relaton-data-\*
repos — were invisible to the `developers` team until the 2026-11-26
alignment).

## 1. Standard team grants (required for every repo)

| Team | Permission |
|---|---|
| `staff` | admin |
| `developers` | write |
| `editors` | write |
| `ci` | write |

```sh
gh api -X PUT "orgs/relaton/teams/staff/repos/relaton/<repo>" -f permission=admin
gh api -X PUT "orgs/relaton/teams/developers/repos/relaton/<repo>" -f permission=push
gh api -X PUT "orgs/relaton/teams/editors/repos/relaton/<repo>" -f permission=push
gh api -X PUT "orgs/relaton/teams/ci/repos/relaton/<repo>" -f permission=push
```

## 2. Mirror teams (when applicable)

- `iho` → relaton-data-iho (write)
- `bipm` → relaton-data-bipm, rawdata-bipm-metrologia (write)
- `operators-api` → api-plane service repos (write): api.relaton.org,
  infrastructure-lambda-api, relaton-api-js, relaton-mcp, relaton-events,
  relaton-dumps
- `operators` → legacy ops repos (unchanged)

## 3. Verify

```sh
gh api repos/relaton/<repo>/teams -q '.[] | .slug + " " + .permission'
```

Caution when auditing: `GET /orgs/relaton/teams/<team>/repos` is **paginated**
(100 per page). Always paginate — a single page silently hides truncation and
makes fully-granted repos look broken.

## 4. Direct collaborators

Do not add direct collaborator grants that duplicate team access (e.g. a CI
bot that is already in the `ci` team). Direct grants that EXCEED team access
(e.g. admin for a developers-team member) are deliberate access decisions —
keep them, they are not duplication.
