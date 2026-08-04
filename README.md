# salesforce-sandbox-postcopy

_Appends `.invalid` to the email addresses a sandbox inherits, so that testing cannot reach real prospects, customers, or staff._

Salesforce appends `.invalid` to every user's email address when it creates or refreshes a sandbox, but it does that for the `User` object only. Leads, contacts, cases, and queues arrive holding live addresses, so a flow, an alert, or a careless mass email in a sandbox can reach a real person.

This package closes that gap. It implements the [`SandboxPostCopy`](https://developer.salesforce.com/docs/atlas.en-us.apexcode.meta/apexcode/apex_interface_System_SandboxPostCopy.htm) interface, which Salesforce runs once in the new sandbox as soon as the copy finishes, and uses [`Database.Batchable`](https://developer.salesforce.com/docs/atlas.en-us.apexcode.meta/apexcode/apex_interface_database_batchable.htm) so that it works at any record volume.

## What is in it

| Class | Role |
| --- | --- |
| `SandboxAfterRefresh` | The class you select in Setup. Salesforce calls it once, in the new sandbox. |
| `SandboxEmailScrubber` | The allowlist, the sandbox guard, the query building, and `restore`. |
| `SandboxEmailScrubberBatch` | Scrubs one object, then chains to the next. |
| `SandboxEmailScrubberTest` | 16 tests. Passes in a production org as well as in a sandbox. |

Objects covered out of the box: **Contact**, **Lead**, **Case**, and **Group** (queue addresses). Every updateable Email field on those objects is picked up from the describe, so custom email fields are covered without naming them.

## Install

[![Deploy to Salesforce](https://raw.githubusercontent.com/afawcett/githubsfdeploy/master/deploy.png)](https://githubsfdeploy.herokuapp.com)

Or with the Salesforce CLI:

```bash
sf project deploy start --source-dir force-app --target-org <your-org>
```

Deploy it to **production**, not to a sandbox. A post copy script has to exist in the org the sandbox is copied from, because the sandbox is a copy of production and runs the copy of the class it inherits.

## Wire it up

Setup > Sandboxes, then either **New Sandbox** or **Refresh** on an existing one, and set **Apex Class** to `SandboxAfterRefresh`.

Two things worth knowing before you go looking for it:

- The setting takes effect at the **next** create or refresh. Attaching it changes nothing about the sandbox you already have.
- Depending on the org and the sandbox type, the Apex Class field is only offered in the create and refresh wizard, not on the sandbox detail page. If you cannot find it on the detail page, that is why.

To scrub a sandbox that has already been refreshed, run this in that sandbox from Developer Console > Debug > Open Execute Anonymous Window:

```apex
SandboxEmailScrubber.scrubAll();
```

## Cover another object

Add its API name to the allowlist in `SandboxEmailScrubber`:

```apex
private static List<String> allowlist = new List<String>{
    'Contact',
    'Lead',
    'Case',
    'Group',
    'Account'
};
```

There is no field list to maintain. Every updateable, non formula Email field on the object is found from the describe, so a custom `Alternate_Email__c` is covered the moment the object is on the list. An object the org does not have is skipped with a warning rather than failing the run, which keeps the package deployable to an org that has, say, no Cases.

If an object needs a narrower scope, add a WHERE fragment to `EXTRA_FILTERS` in the same class. `Lead` uses one already, because a converted lead cannot be updated.

## Put a real address back

A tester who needs to receive mail at their own address can have it restored on named records:

```apex
SandboxEmailScrubber.restore('Contact', new Set<Id>{ '003xx0000000001AAA' });
```

## Safety

- **It refuses to run outside a sandbox.** `Organization.IsSandbox` is checked before any work is queued, and a scrub attempted in production throws `NotASandboxException` instead of touching data.
- **It is safe to run twice.** An address already ending in `.invalid` is left alone rather than picking up a second suffix.
- **One rejected record does not stop the scrub.** Updates are partial success, so a record blocked by a validation rule is counted and named in the debug log while the rest of the sandbox is still made safe. Read the log for the per object totals.
- **A very long address is trimmed to make room.** Standard Email fields hold 80 characters, so an address of 73 or more cannot take the suffix as well. The tail is trimmed, which turns `someone@example.com` into `someone@example.invalid` and keeps it a valid address. Those trimmed characters are gone, so `restore` cannot recover that address.

Scrubbing addresses is one layer. The stronger control is org level: in the sandbox, set Setup > Email > Deliverability > **Access level** to **System email only**, which stops the org sending to anyone at all. Use both. A refresh resets deliverability, and this script does not set it.

## Continuous integration

Two jobs run on every pull request, in [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

**Code Analyzer** runs the `Recommended` rules over the Apex and fails on a Critical or High finding. It needs no org and no secrets, so it runs on pull requests from forks too. Findings are uploaded as a build artifact and, where code scanning is on, as SARIF.

**Apex compile and tests** authenticates to an org and runs a check only deploy with the test class. Nothing is saved to the org. This is the job that matters, because **Code Analyzer cannot catch a compile error**: PMD parses Apex without type checking it, so a broken expression passes straight through. Apex is only type checked server side, which is why an org is needed to know the code builds at all.

To switch that job on, add a repository secret named `SF_AUTH_URL` holding an SFDX auth URL (`sf org display --verbose --target-org <alias>`, then copy the **Sfdx Auth Url** value). Point it at a **free Developer Edition org kept for this repository**, never at an org holding real data: a repository secret is available to any workflow on the default branch. Without the secret the job reports that it was skipped and the build stays green.

## History

Steve O'Neal ([bc-stephenoneal](https://github.com/bc-stephenoneal)) published the original combination of `SandboxPostCopy` and `Database.Batchable` that this started from in 2017. Eoin O'Neill contributed the deployment manifest.

Rewritten 8/3/2026. What changed:

- **Fixed a compile error that had been in the repository since 12/9/2020.** A change from masking addresses to appending `.invalid` left `c.Email.replace + '.invalid'` behind in the contact class. `replace` is a method, so the class did not build, which means the package could not be deployed at all for over five years.
- **Fixed `.invalidm` in the lead class**, the typo reported in [issue #2](https://github.com/rob-alexa/salesforce-sandbox-postcopy/issues/2) by [ctcforce](https://github.com/ctcforce) on 12/28/2022. It also made the test assert against a value that could never match.
- **Fixed the test.** It inserted contacts, leads, and a queue in a single transaction, which mixes setup and non setup DML.
- **Replaced three near identical batch classes with one**, driven by an allowlist and the describe rather than by copy and paste. The entry point keeps the name `SandboxAfterRefresh`, so an org that already names it in a sandbox configuration is unaffected.
- **Dropped the production workaround.** The old classes appended `limit 0` or `limit 1` to their query text based on `Test.isRunningTest()` so that the tests would pass in production. The guard is now a single injectable check, and the query text is the same everywhere.
- **Added `restore`, idempotency, field length trimming, and partial success reporting.**
- **Moved to Salesforce DX source format** and API version **67.0**, from the `src` metadata layout at API 38.0.
- **Added the CI described above**, along with 16 tests including a 200 record bulk case.

Verified 8/3/2026 by a check only deploy against a sandbox: 4 components, 16 tests, 0 failures, 96% coverage.
