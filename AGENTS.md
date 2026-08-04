# AGENTS.md — working agreements for AI agents in this repo

## ⚠️ This repository is PUBLIC

`aiappsgbb/kratos-agent` is a public GitHub repository. Anything committed is
world-readable, permanently, including in git history after a later "fix".

**Never commit into this repo:**

- Deployment endpoints — Static Web App / Container Apps / Foundry / Search /
  Cosmos / Key Vault hostnames, or anything else from `azd env get-values`.
  Resolve these at runtime from the `azd` environment (`.azure/`, gitignored)
  or from env vars; fail fast when they're absent rather than falling back to
  a hardcoded default.
- Subscription IDs, tenant IDs, resource group names, object/principal IDs,
  client IDs, instrumentation keys or App Insights connection strings.
- Keys, tokens, connection strings, or `.env` files of any kind.
- Customer names or customer data, real personal data, or internal-only
  material. Use-case fixtures must stay synthetic.
- Playwright / test artifacts (screenshots, videos, traces, HAR). These can
  capture live application data. They are gitignored — keep it that way.

Infra templates under `infra/` are the exception: they legitimately define
resources, but keep them parameterised — no baked-in environment values.

Before committing, sanity-check the diff:

```bash
git diff --cached | grep -nEi \
  'azurestaticapps\.net|azurecontainerapps\.io|azure-api\.net|cognitiveservices\.azure\.com|search\.windows\.net|vault\.azure\.net|documents\.azure\.com|InstrumentationKey|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
```

Treat any hit as blocking until justified. If something sensitive does land on
`main`, rotate/decommission the resource first — history rewrites on a public
repo are disruptive and the data is already exposed.

## Layout

| Path | What it is |
|------|-----------|
| `src/backend` | Python agent service (FastAPI), deployed as Container App `agent-service` |
| `src/frontend` | Next.js UI, deployed to Azure Static Web Apps |
| `src/hosted-agent` | Foundry hosted-agent variant |
| `src/obo-mcp-server` | On-behalf-of MCP server (optional, `DEPLOY_OBO` flag) |
| `use-cases/` | Persona definitions, skills and synthetic assets |
| `infra/` | Bicep templates |
| `.copilot/skills/` | Repo-local agent skills, incl. `e2e-smoke` |

## Personas: curated vs. non-curated

`/api/use-cases` returns every persona, but the frontend selector only shows
those with `curated: true`. Non-curated personas exist in the API and are
deliberately hidden in the UI, and may have no eval scenarios generated.

Don't hardcode persona lists in tests or tooling — discover them from
`/api/use-cases` and filter on `curated`. A test demanding a non-curated
persona in the UI is a broken test, not a broken app.

## Validation

Run the smallest thing that covers the change.

```bash
# backend
cd src/backend && uv run pytest && uv run ruff check .

# frontend
cd src/frontend && npm run lint && npm run build

# deployed environment, end to end (after any azd deploy)
cd .copilot/skills/e2e-smoke && ./run.sh          # 21 specs
SKIP_BROWSER=1 ./run.sh                           # API-only, no chromium
```

`e2e-smoke/run.sh` resolves its target from the selected `azd` environment,
so it always follows whichever env is active. See its `SKILL.md` for details.
First run installs npm deps and Chromium (cached afterwards).

## Deployment is manual, never automatic

`.github/workflows/ci-cd.yml` runs lint/test/build only. It does **not** deploy.
Deployment lives in `.github/workflows/deploy.yml` and is `workflow_dispatch`
only — pick an environment, optionally provision, optionally upload skills.

Do not re-attach deploy jobs to `push`. A green build does not mean a deploy
can succeed, because the target environment needs all of:

- environment secrets `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` /
  `AZURE_SUBSCRIPTION_ID` (OIDC federated credential), and
- already-provisioned infrastructure for that `azd` env.

As of the last audit only the `kratos-agent-2` env is provisioned; the
`staging` and `production` envs have no infra and no secrets.

Gotchas that have bitten before:

- `Azure/setup-azd@v1.0.0` installs from `azdrelease.azureedge.net`, which no
  longer resolves. Use `v2.x`.
- A fresh runner has no `.azure/` dir, so `azd deploy` needs `azd env
  select`/`new` **and** `azd env refresh` to hydrate outputs first.
- The skills blob storage account is `publicNetworkAccess: Disabled`, so
  `KRATOS_AUTO_UPLOAD_USE_CASES=1` cannot work from a GitHub-hosted runner.
  `hooks/postdeploy.sh` skips the upload when there is no TTY.
- Never use `|| true` on a test that is meant to gate a release.

## Container images build in ACR, not locally

All three container services set `remoteBuild: true` under `docker:` in
`azure.yaml`. Their images install from pypi and the npm registry at build
time, and some corporate networks filter `files.pythonhosted.org` and
`registry.npmjs.org`, which makes a local `docker build` impossible. Building
in ACR sidesteps that and means deploying needs no local Docker daemon.

Do not "simplify" this back to local builds.

## Optional services need a `condition:`

`obo-mcp-server` is only provisioned when `deployObo` is true, so `azure.yaml`
gives it `condition: ${DEPLOY_OBO=true}` — the same variable and the same
default that `infra/main.parameters.json` feeds to Bicep. Keep those two in
sync. Without the condition, `azd up` fails on any environment with OBO off,
because azd tries to deploy a resource that was deliberately never created.

`condition:` needs azd >= 1.28.

## CI builds every image

`ci-cd.yml` builds all three Dockerfiles. This is deliberate: it used to build
only the backend, which let a dependency bump reach `main` with an
unresolvable `requirements.txt` (`pydantic` pins `pydantic-core` to an exact
version; they were bumped separately). Nothing caught it until a real deploy
failed.

Packages that pin each other exactly — `pydantic`/`pydantic-core`,
`react`/`react-dom` — must be grouped in `.github/dependabot.yml` so they are
never bumped apart. Both pairs have already broken this repo once.

## Conventions

- Python: `ruff` for lint and format; `mypy` is configured.
- Don't hand-edit `azd`-generated values or anything under `.azure/`.
- Prefer `azd env get-values` over reading `.azure/` files directly.
