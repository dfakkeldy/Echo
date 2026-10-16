# Change-aware release delivery

The scheduled resolver still wakes up on Ubuntu. A second Ubuntu job compares
immutable Git build inputs before allocating the macOS delivery runner. A match
skips that runner, its compile/test work, signing, archive, upload and processing
wait. Normal push/PR CI and its existing required check still run independently.
A skipped delivery does not claim a fresh test pass or Apple approval.

The comparison uses file paths, Git modes and blob or submodule IDs, rather than
commit IDs. It includes app and extension resources, project settings and schemes,
package manifests and locks, build scripts, Ruby dependencies and Fastlane build
configuration. The workflow's build commands, step environment, Ruby/Xcode setup,
runner and relevant build variables also participate. `.github/release-inputs.json`
records repository-specific exclusions and the exact controller-file overlays
already used by this workflow. New native roots count by default. Keep bundled
root documentation in `bundled_root_documents`; Echo's third-party notice is a
build resource even though its name ends in `.md`.

Root prose, `docs/`, agent instructions, native-unrelated `web/` and the release
controller itself do not change the input hash. Scheduling, concurrency and guard
bookkeeping changes therefore do not create another binary. Changing the actual
archive recipe, effective Fastlane code or dependencies does. Shared project or
package inputs conservatively invalidate all affected platform plans.

Each platform and channel has a separate baseline. A receipt is emitted only
after its real delivery operation returns successfully, including configured
processing/distribution waits. Compile-only, missing-secret and dry-run paths
emit none. The next comparison accepts a receipt only from this workflow's
successful completed attempt on an established channel/controller ref. Failed,
cancelled and in-progress attempts cannot advance the baseline. A completed
successful earlier attempt remains valid when the same run is retried; its exact
attempt outcome is checked independently. A successful
partial Echo run can acknowledge iOS independently while Mac remains retryable.
This records completion of the configured delivery operation, not external beta
approval, App Review approval, installation or Dan's acceptance.

The guard uses the latest successful receipt, rather than any historical matching
hash, so a deliberate code revert still delivers the reverted app. It checks newer
successful run/job history too: removing a newer receipt cannot make an older
one look current. Expired or missing authoritative receipts cause a normal gated
build to establish a fresh baseline. Artifacts request 90 days of retention,
subject to repository retention limits. A first run after rollout, or after
receipt loss/expiry, can therefore build once even if its inputs were delivered
before this mechanism existed. API or comparison errors stop delivery.

All channels share workflow concurrency `release-trains` with cancellation
disabled and `queue: max`, covering comparison through delivery/receipt publication. This also
protects app-wide build-number allocation. Up to 100 pending runs can wait; an
inactive DST companion cannot replace a queued manual request. The build checks out the exact source
SHA compared by Ubuntu, so a moving branch cannot change the planned payload.

For an intentional rebuild, run the existing workflow with `force=true` and the
usual channel. Force changes only the comparison decision. It still executes
all existing compile, test, metadata, signing and release gates. Use it when a
non-repository input such as an installed SDK, signing resource or remote service
configuration has deliberately changed. This mechanism does not read or hash
secret values. Existing non-shipping dry runs remain non-shipping.

The promotion ladder remains `feature/* -> nightly -> weekly -> main`, with
exact-head technical/independent review gates and Dan's internal acceptance
policy. Public App Store release remains manual. This change grants no new
promotion, signing-resource creation, submission or publication authority.
Do not bypass existing licensing or release holds.

The scheduler executes the controller on the default branch. Landing a PR only
on `nightly` does not update the live scheduled controller. Promote through the
normal ladder with the required review/acceptance before calling this behavior
live. Echo's source Fastfile also needs the selective-platform recorder on the
channel being built; an older lane emits no receipts and cannot seed a baseline.

Run the guard regression suite without Xcode or Apple access:

```sh
python3 -m unittest discover -s .github/scripts/tests -p test_release_delivery.py -v
```
