/**
 * Appends ".invalid" to the email addresses held on an allowlist of objects, so that a newly
 * created or refreshed sandbox cannot send mail to real prospects, customers, or staff.
 *
 * Salesforce does this to User.Email during a refresh, but to no other object, so leads,
 * contacts, cases, and queues arrive in a sandbox still holding live addresses.
 *
 * Entry points:
 *   scrubAll()                          queue a scrub of every allowlisted object
 *   scrub(objectApiName)                queue a scrub of one object
 *   restore(objectApiName, recordIds)   put the real addresses back on named records
 *
 * To cover another object, add its API name to the allowlist. Every updateable Email field on
 * that object is read from the describe, custom fields included, so there is no field list to
 * maintain by hand.
 *
 * Declared without sharing because a scrub has to reach every record in the org, not only the
 * records the running user happens to be able to see.
 */
public without sharing class SandboxEmailScrubber {
    /** Appended to each address. Matches what Salesforce itself does to User.Email. */
    public static final String SUFFIX = '.invalid';

    /** Records per batch chunk. */
    public static final Integer BATCH_SIZE = 200;

    /**
     * Objects to scrub, processed in this order.
     *
     * Group holds queue addresses and is a setup object, so its DML has to happen in a
     * transaction of its own. Giving every object its own batch job is what keeps that from
     * throwing MIXED_DML_OPERATION.
     */
    @TestVisible
    private static List<String> allowlist = new List<String>{
        'Contact',
        'Lead',
        'Case',
        'Group'
    };

    /** Extra WHERE fragments by object. A converted lead cannot be updated. */
    private static final Map<String, String> EXTRA_FILTERS = new Map<String, String>{
        'Lead' => 'IsConverted = false'
    };

    /**
     * Overrides the Organization.IsSandbox check. Tests set this so the guard can be exercised in
     * any org, which is what lets this package deploy to production without the older
     * Test.isRunningTest() and "limit 0" workaround inside the query.
     */
    @TestVisible
    private static Boolean sandboxOverride = null;

    /** Thrown when a scrub is attempted anywhere other than a sandbox. */
    public class NotASandboxException extends Exception {
    }

    /** One object's worth of work: which object, which email fields, and any extra WHERE. */
    public class Target {
        /** API name of the object, as the describe reports it. */
        public String objectApiName;

        /** API names of the updateable email fields on that object, sorted. */
        public List<String> fieldApiNames = new List<String>();

        /** Field length by field API name, so the suffix can be made to fit. */
        public Map<String, Integer> maxLengths = new Map<String, Integer>();

        /** Extra WHERE fragment for this object, or null. */
        public String extraFilter;
    }

    /**
     * Whether this org is a sandbox.
     *
     * Reading Organization is deliberately not gated on the running user's object permissions: the
     * guard has to be able to answer in every context, and it discloses nothing.
     *
     * @return true in a sandbox, or whatever a test has forced through sandboxOverride
     */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    public static Boolean isSandbox() {
        if (sandboxOverride != null) {
            return sandboxOverride;
        }
        return [SELECT IsSandbox FROM Organization LIMIT 1].IsSandbox;
    }

    /**
     * Queues a scrub of every allowlisted object, each object chained after the one before it.
     *
     * @return the batch job Id of the first link, or null when there is nothing to scrub
     */
    public static Id scrubAll() {
        assertSandbox();
        List<Target> targets = buildTargets();
        if (targets.isEmpty()) {
            System.debug(
                LoggingLevel.WARN,
                'SandboxEmailScrubber: no scrubbable email fields found, nothing queued.'
            );
            return null;
        }
        return Database.executeBatch(new SandboxEmailScrubberBatch(targets, 0), BATCH_SIZE);
    }

    /**
     * Queues a scrub of a single object.
     *
     * @param objectApiName API name of the object to scrub
     * @return the batch job Id, or null when the object has no scrubbable email field
     */
    public static Id scrub(String objectApiName) {
        assertSandbox();
        Target target = describeTarget(objectApiName);
        if (target == null) {
            System.debug(
                LoggingLevel.WARN,
                'SandboxEmailScrubber: nothing to scrub on ' + objectApiName + '.'
            );
            return null;
        }
        return Database.executeBatch(
            new SandboxEmailScrubberBatch(new List<Target>{ target }, 0),
            BATCH_SIZE
        );
    }

    /**
     * Strips the suffix from named records, putting the real addresses back so that a tester can
     * receive mail at their own address again. An address that had to be trimmed to make room for
     * the suffix cannot be recovered this way, because the trimmed characters are gone.
     *
     * The query text is built from describe output rather than from the caller's string: the object
     * and field names come back from Schema.describeSObjects, and the record Ids are bound.
     *
     * @param objectApiName API name of the object holding the records
     * @param recordIds the records to restore
     * @return one save result per record updated, empty when nothing needed restoring
     */
    @SuppressWarnings('PMD.ApexSOQLInjection')
    public static List<Database.SaveResult> restore(String objectApiName, Set<Id> recordIds) {
        assertSandbox();
        Target target = describeTarget(objectApiName);
        if (target == null || recordIds == null || recordIds.isEmpty()) {
            return new List<Database.SaveResult>();
        }

        String soql =
            'SELECT Id, ' +
            String.join(target.fieldApiNames, ', ') +
            ' FROM ' +
            target.objectApiName +
            ' WHERE Id IN :recordIds';
        List<SObject> found = Database.queryWithBinds(
            soql,
            new Map<String, Object>{ 'recordIds' => recordIds },
            AccessLevel.SYSTEM_MODE
        );

        List<SObject> toUpdate = new List<SObject>();
        for (SObject record : found) {
            if (stripSuffix(record, target)) {
                toUpdate.add(record);
            }
        }
        return toUpdate.isEmpty()
            ? new List<Database.SaveResult>()
            : Database.update(toUpdate, false, AccessLevel.SYSTEM_MODE);
    }

    /**
     * Works out the scrubbed form of one address.
     *
     * When the suffix would overflow the field, the address is trimmed from the right to make room.
     * Because the trim cuts the tail, an address such as "someone@example.com" becomes
     * "someone@example.invalid" and stays a valid address. Only a local part long enough to fill the
     * field on its own can trim down to something the platform rejects, and that row is reported as
     * a failure rather than stopping the batch.
     *
     * @param value the current address
     * @param maxLength the field's length, or null when it is not known
     * @return the scrubbed address, or null when the value needs no change
     */
    public static String scrubbed(String value, Integer maxLength) {
        if (String.isBlank(value) || value.endsWith(SUFFIX)) {
            return null;
        }
        String candidate = value + SUFFIX;
        if (maxLength != null && maxLength > SUFFIX.length() && candidate.length() > maxLength) {
            candidate = value.left(maxLength - SUFFIX.length()) + SUFFIX;
        }
        return candidate;
    }

    /**
     * Builds the SOQL for one target, selecting only records that still hold an unscrubbed address.
     * Every object and field name comes from the describe rather than from any caller, so there is
     * no untrusted input in the query text.
     *
     * @param target the object and fields to query
     * @return the SOQL string
     */
    public static String buildQuery(Target target) {
        List<String> unscrubbed = new List<String>();
        for (String fieldApiName : target.fieldApiNames) {
            unscrubbed.add(
                '(' + fieldApiName + ' != null AND (NOT ' + fieldApiName + ' LIKE \'%' + SUFFIX + '\'))'
            );
        }
        String soql =
            'SELECT Id, ' +
            String.join(target.fieldApiNames, ', ') +
            ' FROM ' +
            target.objectApiName +
            ' WHERE (' +
            String.join(unscrubbed, ' OR ') +
            ')';
        if (String.isNotBlank(target.extraFilter)) {
            soql += ' AND (' + target.extraFilter + ')';
        }
        return soql;
    }

    /**
     * Removes the suffix from every email field on one record, in memory.
     *
     * @param record the record to change
     * @param target the fields to look at
     * @return true when at least one field changed
     */
    private static Boolean stripSuffix(SObject record, Target target) {
        Boolean changed = false;
        for (String fieldApiName : target.fieldApiNames) {
            String value = (String) record.get(fieldApiName);
            if (String.isNotBlank(value) && value.endsWith(SUFFIX)) {
                record.put(fieldApiName, value.removeEnd(SUFFIX));
                changed = true;
            }
        }
        return changed;
    }

    /** Throws unless this org is a sandbox. */
    private static void assertSandbox() {
        if (!isSandbox()) {
            throw new NotASandboxException(
                'SandboxEmailScrubber refuses to run outside a sandbox. This org is not a sandbox.'
            );
        }
    }

    /**
     * Turns the allowlist into targets, skipping anything this org does not have.
     *
     * @return one target per allowlisted object that has at least one scrubbable email field
     */
    @TestVisible
    private static List<Target> buildTargets() {
        List<Target> targets = new List<Target>();
        for (String objectApiName : allowlist) {
            Target target = describeTarget(objectApiName);
            if (target != null) {
                targets.add(target);
            }
        }
        return targets;
    }

    /**
     * Reads one object's updateable email fields off the describe.
     *
     * @param objectApiName API name of the object
     * @return the target, or null when the object is absent, not writable, or has no such field
     */
    @TestVisible
    private static Target describeTarget(String objectApiName) {
        Schema.DescribeSObjectResult objectDescribe = describeObject(objectApiName);
        if (objectDescribe == null) {
            return null;
        }
        if (!objectDescribe.isUpdateable() || !objectDescribe.isQueryable()) {
            System.debug(
                LoggingLevel.WARN,
                'SandboxEmailScrubber: ' +
                    objectApiName +
                    ' is not both queryable and updateable, skipped.'
            );
            return null;
        }

        Target target = new Target();
        target.objectApiName = objectDescribe.getName();
        target.extraFilter = EXTRA_FILTERS.get(target.objectApiName);
        for (Schema.SObjectField field : objectDescribe.fields.getMap().values()) {
            Schema.DescribeFieldResult fieldDescribe = field.getDescribe();
            if (isScrubbable(fieldDescribe)) {
                target.fieldApiNames.add(fieldDescribe.getName());
                target.maxLengths.put(fieldDescribe.getName(), fieldDescribe.getLength());
            }
        }
        if (target.fieldApiNames.isEmpty()) {
            return null;
        }
        // Sorted so that the generated query text is the same on every run.
        target.fieldApiNames.sort();
        return target;
    }

    /**
     * Describes one object without pulling in its child relationships.
     *
     * @param objectApiName API name of the object
     * @return the describe, or null when this org does not have the object
     */
    private static Schema.DescribeSObjectResult describeObject(String objectApiName) {
        try {
            List<Schema.DescribeSObjectResult> described = Schema.describeSObjects(
                new List<String>{ objectApiName },
                SObjectDescribeOptions.DEFERRED
            );
            return described.isEmpty() ? null : described[0];
        } catch (Exception cannotDescribe) {
            System.debug(
                LoggingLevel.WARN,
                'SandboxEmailScrubber: cannot describe ' +
                    objectApiName +
                    ', skipped. ' +
                    cannotDescribe.getMessage()
            );
            return null;
        }
    }

    /**
     * Whether a field is an email field this can write to.
     *
     * @param fieldDescribe the field to judge
     * @return true when the field is a writable Email field
     */
    private static Boolean isScrubbable(Schema.DescribeFieldResult fieldDescribe) {
        return fieldDescribe.getType() == Schema.DisplayType.EMAIL &&
            fieldDescribe.isUpdateable() &&
            !fieldDescribe.isCalculated() &&
            !fieldDescribe.isAutoNumber();
    }
}
