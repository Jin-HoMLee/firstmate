---
name: application-dossier-production
description: >-
  Agent-only procedure for creating or materially refreshing a job-application dossier in a project with a canonical dossier contract, covering scoping a new package, updating one after a route or requirement change, final-reviewing it, and reconciling an upload record.
  Load whenever the captain asks to prepare, scope, update, finalize, review, or make submit-ready an application package, including its CV, letter or note, evidence map, form answers, artifact manifest, or upload reconciliation.
  An ordinary status-only edit to an already coherent package needs no load.
  Owns dossier content-production sequencing and cross-record coherence only; it does not submit applications, operate forms beyond the task's authority, deploy dashboards, make captain decisions, or own delivery.
user-invocable: false
metadata:
  internal: true
---

# Application dossier production

This skill is a thin internal procedure for producing a coherent application dossier from current sources.
It does not create a generator, browser macro, form filler, dashboard deployer, submission workflow, new schema, or bundled automation.

## Load the owners first

Read the applications project's `AGENTS.md`, `TEMPLATE.md`, lifecycle/schema documentation, `_template` seed, a current route-equivalent dossier, and the paired CV fact sources.
Treat the current task authority as the owner of permitted operations.
Treat the applications repository's dossier template and manifest as the owners of artifact and manifest format.
Treat the applications schema as the owner of lifecycle enums, route fields, and readiness semantics.
Treat the CV repository's current public `content/**` as the owner of candidate facts and its authorized private overlay only for identity fields explicitly in scope.
Treat the live employer source and form as the owners of role and route facts.
Use recent dossiers and AGeNEO as examples of shape and history, never as sources to copy through a newer contradiction.

Keep Firstmate's application, browser, dashboard, captain-decision, validation, and landing owners authoritative by reference.
Load or follow those owners when their boundaries apply rather than reproducing their procedures here.

If a required source is inaccessible or unauthorized, record that fact and produce a bounded partial dossier when useful.
Call a value genuinely absent only after checking every authoritative source that the task permits.
Classify unresolved inputs as present and source-backed, present but needing current-value confirmation, captain judgment or self-identification, inaccessible or unauthorized, or genuinely absent.
Never put restricted values in public artifacts, job freezes, reports, logs, status notes, or real-value tests.

## Produce the dossier

1. Resolve the employer, role, requisition, canonical posting, apply route, location, work model, stated compensation and deadline, responsibilities, requirements, preferences, and explicit omissions.
2. When browser access is separately authorized, scout the live form read-only before creating extra documents and record the exact capture boundary if later pages require filling or advancing.
3. Choose one route branch: CV-only or no-letter form, portal with required or optional letter, employer email, email-primary with a retained non-parallel fallback, authenticated multi-step portal, or unknown or partially captured route.
4. Freeze the route branch before drafting so generic expected-file lists cannot require a letter or upload that the route does not accept.
5. Map each material requirement to the project's approved decision labels, preserving both transferable evidence and the boundary of what must not be claimed.
6. Keep peer-reviewed, unpublished, open-source, industry, clinical-adjacent, and in-progress evidence streams distinct.
7. Create or refresh only the route-appropriate records owned by `TEMPLATE.md`, such as `application.yaml`, `job.md`, `requirements-map.md`, `cv-tailoring.md`, `draft.md`, `offline-application-answers.md`, `application-fields.md`, and a checklist or handoff.
8. Keep application lifecycle, material readiness, eligibility, and submission authorization separate, and keep `status: draft` until the actual lifecycle owner records a later event.
9. Route universal CV wording to the CV owner through the package's tailoring record instead of editing universal facts from the applications package.
10. Generate HTML only through the existing project contract and never edit generated HTML directly.

For a no-letter route, follow `TEMPLATE.md` and the schema: use the canonical `cover_letter: "none"` value, omit submission-letter artifacts, and mark any retained review-only letter as non-submission.
For a form that cannot be fully captured without filling, preserve the boundary and do not invent later fields or values.
Do not treat dossier preparation as permission to log in, fill, upload, contact, submit, or deploy.

## Freeze and reconcile artifacts

Use the existing CV and application export contracts to produce package-local artifacts and update the authoritative attachment manifest.
Verify each artifact's existence, exact full SHA-256, MIME or file type, size, page count where applicable, source SHA, variant, and submission-attachment flag.
The manifest's full SHA-256 is authoritative over any filename prefix.
Every canonical application artifact in this workflow must carry `_sha256-<first8>` in its filename, derived from that full manifest hash.

Reconcile one artifact chain end to end: the committed artifact, its full manifest SHA-256, the reconciled primary project clone, the `_sha256-<first8>` filename, the actual upload source, and the post-upload record must agree.
A disposable worker copy is never a durable local link and never an upload source.
If an upload already occurred under separate explicit authority, record its source and receipt during post-upload reconciliation without submitting again.

## Semantic coherence audit

Before calling the dossier complete, compare every canonical record, not only files changed in the current round.

- Employer, role, requisition, posting URL, and apply URL agree everywhere.
- Application and manifest lifecycle notes, timestamps, and submission state agree.
- Canonical status values and unique ISO `added` and `updated` timestamps are used.
- Form depth and field counts agree across the job record, status note, field notes, mirror, checklist, and manifest.
- Required, optional, and no-letter behavior agrees across the form mirror, application record, manifest, checklist, and intended attachments.
- No checklist points at a superseded requisition or calls an existing artifact unfinished.
- Primary and fallback routes are explicit and non-parallel where required.
- No placeholder, mock, or fake value is presented as a final answer.
- Every claimed missing identity value was checked against each authorized source, while inaccessible sources remain labelled inaccessible.
- Restricted values occur only in the authorized private artifact or exact private form field that needs them.
- Letter, email, CV evidence, and honesty boundaries agree.
- Lifecycle, materials readiness, eligibility, and authorization remain separate.
- A submitted package preserves receipts and an explicit no-resubmit boundary.
- The committed artifact, manifest hash, primary clone, filename prefix, upload source, and post-upload record form one coherent chain.

## Validate and hand off

Run the applications repository's own build, tests, artifact checks, and local dossier readback.
A green dashboard or test suite is necessary but not sufficient for semantic coherence.
Do not deploy unless separately requested and authorized.
Return unresolved captain-owned choices as separate questions through the existing captain-decision owner.

Handoff with the package path and mode, canonical posting and apply route, route class, intended attachments, records changed, artifact provenance, validation results, materials-readiness verdict, eligibility risks, unresolved captain inputs, and an explicit statement that no submission, contact, upload, or deploy occurred unless this was reconciliation of an already-authorized event.
