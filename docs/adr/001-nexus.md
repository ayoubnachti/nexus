# ADR 001 — Nexus: where it runs, repositories, versions and publishing

- **Status:** Accepted
- **Date:** 2026-11-12
- **Deciders:** Ayoub, Youssef — changing any decision below needs both

## Context

Nexus Repository Community Edition becomes the artifact hub for the Buy-02 services: it stores the
backend JARs and the Docker images, and proxies Maven Central so builds resolve dependencies only
through it. Everything runs on the existing OCI ARM server behind Caddy, next to Jenkins and SonarQube.

## Decisions

### 1. Nexus runs from its own compose project

`nexus/compose.yml`, separate from `jenkins/docker-compose.yml`, so it starts on its own (no Jenkins
`.env` needed) and a Jenkins rebuild never restarts it.

- Official `sonatype/nexus3` image, pinned to an exact version tag.
- Data in a named volume mounted at `/nexus-data`.
- `mem_limit: 4g` and
  `INSTALL4J_ADD_VM_PARAMS="-Xms2g -Xmx2g -XX:MaxDirectMemorySize=1g -Djava.util.prefs.userRoot=/nexus-data/javaprefs"`.
  Setting this variable replaces the image default, so the `userRoot` part must stay.
- The image runs as the `nexus` user, not root; we show it with `docker exec nexus id`.
- **Local:** UI on `127.0.0.1:8090` (8081 is already Jenkins), Docker connector on `127.0.0.1:8082`.
- **Server:** an override file joins Caddy's `web` network and publishes no ports.

### 2. URLs, over HTTPS through Caddy

| What | URL | Behind it |
| --- | --- | --- |
| UI + Maven | `https://nexus.ayoubnachti.dev` | `nexus:8081` |
| Docker registry | `https://registry.ayoubnachti.dev` | `nexus:8082` (Docker connector) |

DNS is already covered by the `*.ayoubnachti.dev` record. HTTPS avoids configuring Docker with an
insecure registry.

### 3. Repositories

| Name | Type | Holds |
| --- | --- | --- |
| `maven-releases` | Maven hosted, release policy, no redeploy | JARs published by CI |
| `maven-snapshots` | Maven hosted, snapshot policy | Manual and local test deploys |
| `maven-central` | Maven proxy of Maven Central | Cached external dependencies |
| `maven-public` | Maven group of the three above | The only URL builds resolve from |
| `docker-hosted` | Docker hosted, HTTP connector 8082 | Images pushed by CI |

The Docker Bearer Token Realm is enabled so `docker login` works. Anonymous access is off.

### 4. Version scheme

- Each pom: `<version>${revision}</version>`, default `revision` = `0.0.0-SNAPSHOT`, plus the
  flatten-maven-plugin so deployed poms carry the real version.
- CI on `main`: `-Drevision=1.0.<BUILD_NUMBER>` (Jenkins job `Nexus`).
- Images: `registry.ayoubnachti.dev/ecommerce/<svc>:1.0.<BUILD_NUMBER>`.

A version maps to exactly one Jenkins build, and so to one commit. Rollback means deploying an older number.

### 5. Maven configuration

`settings.xml` is committed at the repo root: mirror `*` → `maven-public`, and `<servers>` entries for the
two hosted repos with `${env.NEXUS_USER}` / `${env.NEXUS_PASSWORD}`. No secret is in git, and developers
and CI use the same file. Every `mvnw` call in the Jenkinsfile passes `-s settings.xml`.

### 6. Publishing in CI

A new `Publish` stage is the last child of `Deliver`, after `E2E tests`:
`mvnw deploy -DskipTests` for the 7 services, then `docker login`, tag and push the 8 images, `docker logout`.

Being inside `Deliver` means: `main` only, never the nightly build, and only for releases that passed
deploy and E2E. If publishing fails, the release counts as failed and `Deliver` rolls back to `last-good`.

### 7. CI identity

Nexus user `ci-deployer`: deploy rights on its repositories only, no admin. Jenkins credential `nexus-ci`
(username/password), defined in `casc.yaml` with its values in `jenkins/.env`. Used for both Maven and Docker.

### 8. Scope

- Maven and Docker only; no npm proxy.
- No Docker Hub proxy: our own images are stored in `docker-hosted`; third-party and base images
  (`mongo:7`, the Dockerfiles' `FROM` images, Nexus itself) are still pulled from Docker Hub.
- Spring Boot packages the services as **JARs**; `maven-releases` accepts any Maven packaging, so no WAR is built.

## Rules that follow from these decisions

- Never delete or recreate the `Nexus` Jenkins job: build numbers would restart and clash with
  releases already in Nexus (releases are immutable).
- Manual deploys go to `maven-snapshots` only.
- CI never uses the admin account; no passwords in the repo, the Jenkinsfile or screenshots.

## Consequences

- Nexus is one more JVM on the server (4 GiB cap); its data volume must be kept, or published versions are lost.
- Every `main` release adds 7 JARs and 8 images; disk use grows until cleanup policies are added (out of scope for now).
- Builds depend on Nexus being up; if it's down, dependency resolution and publishing fail.
