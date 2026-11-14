# CI/CD with Jenkins and SonarQube

Every change goes through a pull request. Jenkins tests it and SonarQube analyses it; if a test or the quality gate fails, the PR can't be merged. Every push to `main` is built, tested, analysed, deployed, smoke-tested end-to-end and reported by email. If the deploy's health check fails, or the deployed site fails its e2e test, the previous release is restored automatically.

Live: app at `https://shop.ayoubnachti.dev`, Jenkins at `https://jenkins.ayoubnachti.dev`, SonarQube at `https://sonar.ayoubnachti.dev`.

## Architecture

```
GitHub ──webhook (push, PR)──► Jenkins controller (0 executors, configured by casc.yaml)
   ▲                               │ SSH
   │ commit status          ┌──────┴─────────────────┐
   │ (pr-head check)  agent-backend             agent-frontend
   │                  JDK 21, Docker CLI,       Node 22
   │                  host Docker socket
   │                        │        │                 │
   └────────────────────────┘        ▼                 ▼
                                 SonarQube ◄── analysis + quality gate ──┘
                                 (+ PostgreSQL)
                                     │
                       docker compose ──► app stack on the same host
                                          (Eureka, gateway, 3 services, MongoDB, frontend)
```

- **Jenkins and SonarQube are one compose project** (`jenkins/`), separate from the app's `compose.yml`, so a deploy or rollback can never restart them. Both are CI infrastructure; agents reach SonarQube by name (`http://sonarqube:9000`) on the same Docker network.
- **Configuration as code:** `jenkins/casc.yaml` creates the admin user, security, both agents, credentials, the email settings and the SonarQube server connection. No setup wizard.
- **Secrets** are never in git. They live in `jenkins/.env` (git-ignored) and become Jenkins credentials at startup.
- **Multi-arch images only**, so the same files run on the arm64 server and on x86 laptops.
- **Nexus is the artifact hub** (`https://nexus.ayoubnachti.dev`, own compose project `nexus/`): every Maven build in the pipeline resolves its dependencies through it (`-s settings.xml`, user `ci-deployer` from the `nexus-ci` credential), and every release of `main` is published to it — JARs in `maven-releases`, images in `registry.ayoubnachti.dev`. Details: `docs/adr/001-nexus.md`.

## Pipeline (`Jenkinsfile`)

The job is a **Multibranch Pipeline** with the GitHub Branch Source: it builds `main` and every pull request (`PR-*`). Other branches are only built once they have a PR.

| Stage | Agent | What it does |
|---|---|---|
| **Prepare** | — | Tells SonarQube whether this is a PR (`sonar.pullrequest.*`) or a branch analysis |
| **Backend tests** / **Frontend tests** | backend / frontend, **in parallel** | Backend: `./mvnw -s settings.xml clean test` (dependencies through Nexus) with JaCoCo coverage for the 7 Spring services (with a throwaway MongoDB). Frontend: `npm ci` + `ng test --coverage` (Vitest). JUnit results are published. |
| **Backend analysis** / **Frontend analysis** | same agent and workspace as the tests | SonarQube analysis per service (8 projects). `sonar.qualitygate.wait=true`: the scanner fails the stage if the **quality gate** fails. |
| **Build images** | backend | `./mvnw -s settings.xml clean package -Drevision=1.0.<build#>` for the 7 services (dependencies through Nexus), then `docker compose build`: the backend images copy those JARs. Images tagged with the build number — **`main` only** |
| **Deploy** | backend | `docker compose up -d --wait`: replaces the live containers, succeeds only once every one reports healthy — **`main` only** |
| **E2E tests** | frontend | Playwright drives a real browser against the site `Deploy` just put live (`https://shop.ayoubnachti.dev`): register, log in, search, add to cart, check out on delivery, see the order. Runs right after `Deploy`, same build, **`main` only**. |
| **Publish** | backend | Only after `Deploy` and `E2E tests` passed: uploads the exact JARs to Nexus `maven-releases` as `1.0.<build#>` and pushes the 8 images to `registry.ayoubnachti.dev/ecommerce/<svc>:1.0.<build#>` (user `ci-deployer`, credential `nexus-ci`). A failure here fails `Deliver` and rolls back. **`main` only**. |
| *post (on Deliver)* | backend | Only once **both** `Deploy`'s health check **and** `E2E tests` passed: tag the release `last-good`. If either failed: redeploy `last-good` instead. Email on success and on failure. |

Any failing stage stops the pipeline. Builds of the same branch or PR run one at a time.

**Nightly scan:** `main` is also built every night (`H 3 * * *`): tests and analysis run, so SonarQube's dashboards stay current even without pushes; build, deploy and e2e are skipped (there is nothing new to deploy or test).

**Test reports:** backend (Surefire) and frontend (Vitest `junit` reporter) results are published with the `junit` step, even when tests fail. Each build keeps them under *Test Result*; the last 20 builds are kept.

**Rollback:** `Deploy` and `E2E tests` are both children of the same `Deliver` stage, and `Deliver`'s own `post` block only sees one combined result — so a failure in *either* one is treated the same way: the images are **not** tagged `last-good`, and the pipeline redeploys whatever the previous `last-good` was, marks the build failed, and the email says "(rolled back)". This means a broken release is live for however long `Deploy` + `E2E tests` take to run (roughly a minute) before it's caught and replaced — there is no separate, untested copy of the app to switch to instead, so this short window of exposure is a deliberate trade-off for not running two instances of the stack at once. Only images are rolled back; MongoDB data is untouched. Older images are deleted after each healthy deploy.

**Frontend tests use Vitest**, Angular's default runner (Karma is deprecated). The subject's Jasmine/Karma is a suggestion; Vitest runs in Node with jsdom, so the agent needs no browser.

**Distributed builds:** backend and frontend tests and analysis run at the same time on two separate agents, selected by label (`backend`, `frontend`).

## Code quality with SonarQube

### Setup

- **Image:** `mc1arke/sonarqube-with-community-branch-plugin:26.5.0.122743-community` (amd64 + arm64). SonarQube Community Build analyses one branch only; this image adds the **Community Branch Plugin**, which enables branch and **pull-request analysis**. Third-party, not supported by SonarSource, so the version is pinned: the plugin only works with its matching SonarQube version.
- **Database:** PostgreSQL 17 (`sonar-db`), not the embedded H2 (evaluation only, can't be upgraded).
- **Projects:** one per service — `safe-zone-api-gateway`, `-discovery-server`, `-user-service`, `-product-service`, `-media-service`, `-frontend`. Each backend service has its own `pom.xml` without a parent, so separate projects are the natural fit. Projects are created by their first analysis.
- **Coverage:** JaCoCo for the backend (invoked by full Maven coordinates, no pom changes), Vitest v8 coverage (`lcov`) for the frontend.
- **Jenkins connection:** SonarQube Scanner plugin, server `sonarqube` → `http://sonarqube:9000`, authenticated with a **Global Analysis Token** stored as the `sonar-token` credential. The token can run analyses and create projects, nothing else.

### Quality gate `SafeZone` (default for all projects)

Copied from *Sonar way*; conditions apply to **new code** (a PR's changes, or changes on `main` since the previous version):

| Condition | Catches |
|---|---|
| Issues > 0 | any new vulnerability, bug or code smell, at any severity |
| Security Hotspots Reviewed < 100% | security-sensitive code nobody has reviewed |
| Coverage < 80% | new code without enough tests |
| Duplicated Lines > 3% | copy-pasted new code |

"Clean as you code": existing issues don't block builds, but nothing new may be added — and **touching a line makes its existing issues new**. SonarQube ignores the coverage and duplication conditions when a change has fewer than 20 new lines.

**How the pipeline fails:** the scanner waits for SonarQube to compute the gate (`sonar.qualitygate.wait=true`, 5 min timeout) and exits non-zero if it fails, so the analysis stage, the build and the GitHub check turn red, and `main` doesn't deploy.

**PR analysis detail:** the scanner compares the PR with its target branch in the local clone, so PR builds fetch `origin/main` first (`fetchTargetBranch()` in the `Jenkinsfile`). Without it, SonarQube sees 0 new lines and the gate passes on nothing.

### Review and approval process

- **Branch protection on `main`:** changes only through a pull request; the Jenkins check `continuous-integration/jenkins/pr-head` must pass (tests + quality gate); the branch must be up to date with `main` (the PR head is what gets tested); conversations must be resolved; force pushes and deletion are blocked; **nobody can bypass these rules, admins included**.
- **PR template** (`.github/pull_request_template.md`): the review checklist — green check, every SonarQube issue on the PR fixed or justified, hotspots reviewed, tests for new code, no secrets.
- **Every issue is either fixed or justified in SonarQube:** *False positive* or *Accepted*, always with a comment explaining why.
- **Approvals:** 1 required: each of the two team members reviews the other's PRs (GitHub never lets authors approve their own PR).

### Issues handled

From the first analysis of `main` (48 issues, 4 projects with unreviewed hotspots):

| Finding | Action |
|---|---|
| Hard-coded seed passwords in `user-service` `DataSeeder` (2 Blocker, java:S6437) | **Fixed:** both demo seeders removed; users register through the app |
| `csrf.disable()` in 4 services (hotspots) | **Reviewed Safe:** stateless API, JWT sent in the `Authorization: Bearer` header from `localStorage`, no session or auth cookie, so CSRF doesn't apply |
| Duplicated claim name, `int` overflow pattern, method too complex (`media-service`) | **Fixed** |
| Empty test class, test without assertion | **Fixed:** real tests added for `media-service`; a dead test deleted |
| Accessibility issues in the frontend (`alt` texts, label, keyboard handler) | **Fixed** |
| `autocomplete` on password inputs with a dynamic `[type]` | **False positive:** the analyzer can't evaluate the binding; the token is correct |
| `role="dialog"` instead of `<dialog>` | **Accepted:** Bootstrap's documented ARIA pattern; migrating means restyling the component (follow-up) |

Remaining Medium/Low maintainability issues are tracked debt; the gate prevents new ones.

### Access control

- Admin password changed before SonarQube was exposed; **Force user authentication** on; default project visibility **private**. Anonymous requests get `401`:
  `curl -s -o /dev/null -w '%{http_code}\n' https://sonar.ayoubnachti.dev/api/components/search?qualifiers=TRK`
- Jenkins uses a Global Analysis Token, not the admin account.

## End-to-end (e2e) tests

Playwright drives a real Chromium browser through the actual user journey: register → log in → search for a product → add it to the cart → check out with pay on delivery → see the order land in "My Orders". A second test adds an item to the cart, refreshes the page, and checks it's still there with the right quantity.

- **Where:** `frontend/e2e/*.spec.ts`, config in `frontend/playwright.config.ts`. Run locally with `cd frontend && npm run e2e` against whatever `E2E_BASE_URL` points at (default `http://localhost:4200`).
- **Self-contained:** each test registers its own seller, client and product with a unique, timestamped name, so repeated runs never collide with each other or with demo data — nothing to seed first.
- **In CI:** `E2E tests` is a child stage of `Deliver`, right after `Deploy`, and points at the real site `Deploy` just put live (`https://shop.ayoubnachti.dev`). It only runs on a real push to `main` (not the nightly run, not a PR — a PR has nothing deployed to test against).
- **One instance, tested in place — not a separate copy:** `Deploy` replaces the live containers with the new ones; `E2E tests` then runs against that same, already-live site. This catches the class of bug that passes unit tests and the health check but still breaks the real flow (a button wired to the wrong endpoint, a form field that silently stopped submitting) — without needing a second, isolated copy of the stack (which this project's single staging host, with fixed ports in `compose.yml`, doesn't have room for).
- **Gates the rollback:** `Deploy` and `E2E tests` share one outcome at the `Deliver` level (see **Rollback** above) — if e2e fails, the release is **not** kept; the pipeline redeploys `last-good` automatically, same as a failed health check. The trade-off: the new, possibly-broken version is briefly live (the time it takes e2e to run, roughly a minute) before that happens.
- **Reports:** the JUnit result (`frontend/test-results/e2e-junit.xml`) is published the same way as the other stages; the full Playwright HTML report is archived as a build artifact for when a test fails and a screenshot/trace is needed.

## Run it locally

Requirements: Docker with Compose. SonarQube's Elasticsearch needs `vm.max_map_count >= 524288` on the Docker host:

```bash
sysctl vm.max_map_count                                   # Linux: check
sudo sysctl -w vm.max_map_count=524288                    # Linux: set (until reboot)
docker run --rm --privileged alpine sysctl -w vm.max_map_count=524288   # Docker Desktop (Windows/macOS): set in its VM
```

```bash
# 1. App settings (used by the deploy)
cp .env.example .env
#    set JWT_SECRET (openssl rand -base64 32) and SSL_KEYSTORE_PASSWORD

# 2. Jenkins + SonarQube settings
cp jenkins/.env.example jenkins/.env
ssh-keygen -t ed25519 -N "" -C jenkins-agent -f ~/.ssh/jenkins_agent
#    in jenkins/.env set:
#      JENKINS_ADMIN_PASSWORD
#      AGENT_SSH_KEY_B64=$(base64 -w0 ~/.ssh/jenkins_agent)
#      AGENT_SSH_PUBKEY=$(cat ~/.ssh/jenkins_agent.pub)
#      APP_ENV_B64=$(base64 -w0 .env)
#      GIT_USERNAME / GIT_TOKEN   (fine-grained token for the repo: Contents R, Metadata R,
#                                  Pull requests R, Commit statuses R/W)
#      SMTP_USERNAME / SMTP_APP_PASSWORD / NOTIFY_EMAIL  (Gmail app password)
#      SONAR_DB_PASSWORD=$(openssl rand -hex 24)
#      SONAR_TOKEN=placeholder    (replaced in step 4)
#      NEXUS_CI_USER=ci-deployer / NEXUS_CI_PASSWORD   (Nexus CI user, becomes the nexus-ci credential)

# 3. Start SonarQube first
docker compose -f jenkins/docker-compose.yml up -d sonar-db sonarqube
docker compose -f jenkins/docker-compose.yml logs -f sonarqube    # wait for "SonarQube is operational"
```

4. Open `http://localhost:9000`, log in as `admin` / `admin` and set a new password. Accept the third-party plugin notice. Then:
   - *Administration → Configuration → General Settings → Security*: **Force user authentication** on.
   - *Administration → Projects → Management*: default visibility **Private**.
   - *Quality Gates → Sonar way → Copy* → `SafeZone` → **Set as Default**.
   - *My Account → Security*: generate a **Global Analysis Token** and put it in `jenkins/.env` as `SONAR_TOKEN`.

```bash
# 5. Start Jenkins
docker compose -f jenkins/docker-compose.yml up -d --build
```

Open `http://localhost:8080` and log in as `admin`. Both agents appear under *Manage Jenkins → Nodes*; *Manage Jenkins → System* shows the `sonarqube` server.

**Create the job** (once): *New Item* → `safe-zone` → **Multibranch Pipeline**
- Branch Sources: **GitHub** → credentials `git-token` → repository URL
- Behaviours: keep the defaults (branches excluding PR branches; PRs from origin; fork PRs trusted only from users with write access) and add **Filter by name (with wildcards)** → include `main PR-*`
- Build Configuration: by Jenkinsfile, script path `Jenkinsfile`
- Scan Multibranch Pipeline Triggers: periodically, 1 day

Saving scans the repository and builds `main`. Without a public URL there is no webhook, so use **Scan Multibranch Pipeline Now** after pushing.

**On Gitea:** use the **Git** branch source with a Gitea token instead of the GitHub source. `main` builds, tests, analyses and deploys the same way (the `Jenkinsfile` only uses `checkout scm`); PR discovery and the PR status check are GitHub features.

## Server setup

- `jenkins/docker-compose.server.yml` removes the published ports and joins Jenkins and SonarQube to Caddy's `web` network (`https://jenkins.ayoubnachti.dev`, `https://sonar.ayoubnachti.dev`).
- GitHub webhook → `https://jenkins.ayoubnachti.dev/github-webhook/` (push and pull request events).
- The app is served by Caddy at `https://shop.ayoubnachti.dev`. The browser calls `/api/...` on the same domain; the frontend's nginx forwards it to the gateway inside Docker.
- Caddy serves a custom "temporarily down" page when a container is unreachable.
- Updating Jenkins or SonarQube is manual: `git pull`, then `docker compose -f jenkins/docker-compose.yml -f jenkins/docker-compose.server.yml up -d --build`.

## Demo

**The quality gate blocks a PR**
1. On a new branch, add a hard-coded credential and an unused field to a backend class, push, open a PR.
2. The PR build's *Backend analysis* fails with `QUALITY GATE STATUS: FAILED`; the GitHub check is red and **Merge** is disabled.
3. In SonarQube, the project's *Pull Requests* tab shows the new issue and the unreviewed hotspot.
4. Remove the lines and push: the PR rebuilds, the gate passes, the check turns green, merge.

**A failing test stops the pipeline**
1. Break an assertion in any test, push to a PR branch.
2. The tests stage turns red, analysis and deploy are skipped, and a "FAILED" email arrives.

**Automatic rollback** (needs a merge to `main`, so through a PR)
1. In `backend/user-service/src/main/resources/application.properties` set `server.port=8091`. Tests still pass, but the healthcheck on 8081 fails after deploy.
2. *Deploy* fails, the console shows `rolling back to last-good`, and the email says "(rolled back)".
3. `docker ps` shows every service on `:last-good`, all healthy.
4. Revert through another PR.

**An e2e regression triggers a rollback**
1. On `main`, rename the "Add to cart" button's visible text in `add-to-cart-button.html`, or change the checkout "Place order" button's click handler, and merge through a PR.
2. Tests, the quality gate, the build and `Deploy`'s own health check all pass — none of them exercise the actual browser flow, so the regression reaches a real deploy.
3. `E2E tests` runs next, against that same now-live site, and fails on the step that used that exact button text/selector; the archived Playwright report shows a screenshot and trace of the failure.
4. Because `E2E tests` is a child of `Deliver`, that failure counts as `Deliver` failing: the console shows `rolling back to last-good`, the email says "(rolled back)", and `docker ps` shows every service back on `:last-good`. The broken version was live only for the minute or so `Deploy` + `E2E tests` took to run.
5. Revert through another PR; the next build's e2e run goes green and gets tagged `last-good` again.

**Notifications:** every build sends "SUCCESS: ..." (with "deployed" only when a deploy happened) or "FAILED: ...", with links to the changes, test results and console. A failed quality gate fails the build, so it is reported as "FAILED".

## Security notes

- Jenkins is public: sign-up disabled, admin password generated, controller has 0 executors.
- The Docker socket is mounted **only** on `agent-backend`, never on the controller. It gives root-equivalent access to the host, an accepted tradeoff on a single-user server.
- Test values in the `Jenkinsfile` (JWT secret, keystore password) are test-only. Real secrets come from the `ecommerce-env` credential.