# Portal Architecture Observatory

This directory contains Portal's repository-native architecture model and the static application published through GitHub Pages.

## Authority model

- `model/model.json` is deterministic evidence compiled from Swift source.
- `semantic/components.json` contains constrained, agent-synthesized component summaries with source evidence and model provenance.
- `specifications/` contains human-reviewed intended architecture.
- `site/` is the static GitHub Pages application over all three layers.

Generated observations do not override specifications or `docs/architecture-rules.md`.

## Local development

```bash
make architecture
make architecture-check
make architecture-serve
```

The preview is served at <http://127.0.0.1:4173/>. Generated model and site-data files are checked in so pull requests show the exact architecture change that will be published.

## Continuous maintenance

`.github/workflows/architecture-maintenance.yml` runs after source changes on `main`, weekly, or by manual dispatch. It always refreshes deterministic evidence. When the model credential is configured, it gives each affected component to a separate bounded summarization call, validates the structured response, and opens or updates `automation/architecture-portal` as a pull request.

The maintenance agent may modify only:

- `architecture/semantic/components.json`
- generated `architecture/model/model.json`
- generated `architecture/site/data.js`

It cannot modify specifications, rules, workflows, or application source, and the workflow does not auto-merge.

### Repository configuration

Configure these in **Settings → Secrets and variables → Actions**:

| Kind | Name | Purpose |
|---|---|---|
| Secret | `ARCHITECTURE_OPENAI_API_KEY` | Credential for an OpenAI-compatible low-thinking model |
| Variable | `ARCHITECTURE_OPENAI_BASE_URL` | Optional API base, such as `https://openrouter.ai/api/v1` |
| Variable | `ARCHITECTURE_MODEL` | Optional model identifier; defaults to `gpt-4o-mini` |

Without the secret, deterministic graph maintenance still works and the workflow explicitly skips semantic summarization.

## Publishing

`.github/workflows/architecture-pages.yml` validates the checked-in model, tests the compiler, checks browser JavaScript, and deploys `architecture/site/` after a merge to `main`.

GitHub Pages must be configured once with **Source: GitHub Actions** in repository settings. The expected public URL is <https://ethenotethan.github.io/portal/>.

## Adding a component

1. Add a component and ordered path patterns to `architecture/config.json`.
2. Add explicit architectural relationships with source evidence when the relationship carries architectural meaning.
3. Run `make architecture`.
4. Run `make architecture-check`.
5. Review the graph and source inventory locally.

Patterns are first-match-wins. Feature-specific patterns must precede fallback components such as `local-services`, `domain-models`, and `shared-ui`.
