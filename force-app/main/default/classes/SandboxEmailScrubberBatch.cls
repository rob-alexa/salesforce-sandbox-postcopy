/**
 * Scrubs one object's email fields, then chains to the next object in the list.
 *
 * One object per batch job, on purpose:
 * - Group is a setup object, so its DML has to happen in a transaction of its own or the write
 *   throws MIXED_DML_OPERATION alongside any non-setup object in the same list.
 * - Chaining keeps the org inside the limit on concurrent batch jobs however many objects the
 *   allowlist grows to, which starting every object at once would not.
 *
 * A batch chained from finish() does not execute in a test context, so a test covers one object
 * at a time by way of SandboxEmailScrubber.scrub(objectApiName).
 *
 * Declared without sharing for the same reason as SandboxEmailScrubber: the scrub has to reach
 * every record in the org.
 */
public without sharing class SandboxEmailScrubberBatch implements Database.Batchable<SObject>, Database.Stateful {
    private final List<SandboxEmailScrubber.Target> targets;
    private final Integer index;
    private Integer updated = 0;
    private Integer failed = 0;

    /**
     * Builds a job for one object out of the list.
     *
     * @param targets every object still to process, in order
     * @param index which of them this job handles
     */
    public SandboxEmailScrubberBatch(List<SandboxEmailScrubber.Target> targets, Integer index) {
        this.targets = targets;
        this.index = index;
    }

    /**
     * Selects the records that still hold an unscrubbed address.
     *
     * @param context batch context, unused
     * @return the query locator for this job's object
     */
    public Database.QueryLocator start(Database.BatchableContext context) {
        return Database.getQueryLocator(SandboxEmailScrubber.buildQuery(currentTarget()));
    }

    /**
     * Appends the suffix to every email field on the records in this chunk.
     *
     * Partial success is deliberate: a row the org rejects, for a validation rule or a required
     * field it has never satisfied, is counted and reported rather than stopping the scrub and
     * leaving the rest of the sandbox holding live addresses.
     *
     * @param context batch context, unused
     * @param scope the records in this chunk
     */
    public void execute(Database.BatchableContext context, List<SObject> scope) {
        SandboxEmailScrubber.Target target = currentTarget();
        List<SObject> toUpdate = new List<SObject>();

        for (SObject record : scope) {
            Boolean changed = false;
            for (String fieldApiName : target.fieldApiNames) {
                String scrubbed = SandboxEmailScrubber.scrubbed(
                    (String) record.get(fieldApiName),
                    target.maxLengths.get(fieldApiName)
                );
                if (scrubbed != null) {
                    record.put(fieldApiName, scrubbed);
                    changed = true;
                }
            }
            if (changed) {
                toUpdate.add(record);
            }
        }

        if (toUpdate.isEmpty()) {
            return;
        }
        // Deliberately not AccessLevel.SYSTEM_MODE. It would be redundant, since this class is
        // declared without sharing and a batch already runs in system context, and it suppresses
        // the field accessibility check. That check earns its keep: it caught a test handing this
        // method a scope record still carrying Group.Type, which is not updateable and which the
        // query locator never selects.
        for (Database.SaveResult result : Database.update(toUpdate, false)) {
            if (result.isSuccess()) {
                updated++;
            } else {
                failed++;
                System.debug(
                    LoggingLevel.ERROR,
                    'SandboxEmailScrubber: ' +
                        target.objectApiName +
                        ' ' +
                        result.getId() +
                        ' not scrubbed: ' +
                        result.getErrors()[0].getMessage()
                );
            }
        }
    }

    /**
     * Reports this object's totals, then starts the next object.
     *
     * @param context batch context, unused
     */
    public void finish(Database.BatchableContext context) {
        System.debug(
            LoggingLevel.INFO,
            'SandboxEmailScrubber: ' +
                currentTarget().objectApiName +
                ' scrubbed ' +
                updated +
                ', failed ' +
                failed +
                '.'
        );
        Integer next = index + 1;
        if (next < targets.size()) {
            Database.executeBatch(
                new SandboxEmailScrubberBatch(targets, next),
                SandboxEmailScrubber.BATCH_SIZE
            );
        }
    }

    /**
     * @return the object this job is handling
     */
    private SandboxEmailScrubber.Target currentTarget() {
        return targets[index];
    }
}
