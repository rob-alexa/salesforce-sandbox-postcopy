/**
 * Tests for the sandbox email scrubber.
 *
 * These pass in a production org as well as in a sandbox. The production guard is exercised
 * through SandboxEmailScrubber.sandboxOverride rather than by querying Organization, which is what
 * removed the old "Test.isRunningTest() plus limit 0" workaround from the query itself.
 *
 * Two platform limits shape how these are written. A test method runs at most one execute() of a
 * queued batch, so a bulk case stays at one chunk. A batch chained from finish() does not run in a
 * test context, so each object is covered on its own rather than through the chain.
 */
@IsTest
private class SandboxEmailScrubberTest {
    private static final String LIVE_EMAIL = 'somebody@example.com';
    private static final String SCRUBBED_EMAIL = 'somebody@example.com.invalid';

    @IsTest
    static void scrubsAContactEmail() {
        SandboxEmailScrubber.sandboxOverride = true;
        Account account = new Account(Name = 'Scrubber Test Account');
        insert account;
        insert new Contact(
            FirstName = 'John',
            LastName = 'Smith',
            Email = LIVE_EMAIL,
            AccountId = account.Id
        );

        Test.startTest();
        SandboxEmailScrubber.scrub('Contact');
        Test.stopTest();

        Assert.areEqual(SCRUBBED_EMAIL, [SELECT Email FROM Contact LIMIT 1].Email);
    }

    @IsTest
    static void scrubsTwoHundredLeadsInOneChunk() {
        SandboxEmailScrubber.sandboxOverride = true;
        List<Lead> leads = new List<Lead>();
        for (Integer i = 0; i < 200; i++) {
            leads.add(
                new Lead(LastName = 'Bulk ' + i, Company = 'Bulk Co', Email = 'bulk' + i + '@example.com')
            );
        }
        insert leads;

        Test.startTest();
        SandboxEmailScrubber.scrub('Lead');
        Test.stopTest();

        Assert.areEqual(
            200,
            [SELECT COUNT() FROM Lead WHERE Email LIKE '%.invalid'],
            'every lead in the chunk should have been scrubbed'
        );
        Assert.areEqual(
            0,
            [SELECT COUNT() FROM Lead WHERE Email != null AND (NOT Email LIKE '%.invalid')],
            'no lead should still hold a live address'
        );
    }

    /**
     * Group holds queue addresses and is a setup object, so a test that queried it could pick up
     * groups the org already has rather than only its own. This drives execute() against a scope
     * the test controls, which keeps the assertion about this queue and nothing else.
     */
    @IsTest
    static void scrubsAQueueEmail() {
        SandboxEmailScrubber.sandboxOverride = true;
        Group queue = new Group(
            Name = 'Scrubber Test Queue',
            DeveloperName = 'Scrubber_Test_Queue',
            Email = LIVE_EMAIL,
            Type = 'Queue'
        );
        insert queue;

        SandboxEmailScrubber.Target target = SandboxEmailScrubber.describeTarget('Group');
        Assert.isNotNull(target, 'Group should describe to a scrubbable target');

        // Query the record back rather than reusing the one just inserted. The batch's own query
        // locator selects Id and the email fields only, and Group.Type is not updateable, so an
        // in-memory record still carrying Type would fail on save with
        // CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY for a reason the real batch can never hit.
        List<SObject> scope = [SELECT Id, Email FROM Group WHERE Id = :queue.Id];

        Test.startTest();
        new SandboxEmailScrubberBatch(new List<SandboxEmailScrubber.Target>{ target }, 0)
            .execute(null, scope);
        Test.stopTest();

        Assert.areEqual(SCRUBBED_EMAIL, [SELECT Email FROM Group WHERE Id = :queue.Id].Email);
    }

    @IsTest
    static void leavesAnAlreadyScrubbedAddressAlone() {
        SandboxEmailScrubber.sandboxOverride = true;
        insert new Lead(LastName = 'Done', Company = 'Done Co', Email = SCRUBBED_EMAIL);

        Test.startTest();
        SandboxEmailScrubber.scrub('Lead');
        Test.stopTest();

        Assert.areEqual(
            SCRUBBED_EMAIL,
            [SELECT Email FROM Lead LIMIT 1].Email,
            'a second run should not append the suffix twice'
        );
    }

    @IsTest
    static void refusesToRunOutsideASandbox() {
        SandboxEmailScrubber.sandboxOverride = false;
        insert new Lead(LastName = 'Untouched', Company = 'Untouched Co', Email = LIVE_EMAIL);

        Test.startTest();
        try {
            SandboxEmailScrubber.scrubAll();
            Assert.fail('scrubAll should have thrown NotASandboxException');
        } catch (SandboxEmailScrubber.NotASandboxException expected) {
            Assert.isTrue(
                expected.getMessage().contains('not a sandbox'),
                'the message should say why it refused: ' + expected.getMessage()
            );
        }
        Test.stopTest();

        Assert.areEqual(
            LIVE_EMAIL,
            [SELECT Email FROM Lead LIMIT 1].Email,
            'a refused run must leave the data alone'
        );
    }

    @IsTest
    static void restorePutsTheRealAddressBack() {
        SandboxEmailScrubber.sandboxOverride = true;
        Lead lead = new Lead(LastName = 'Restore', Company = 'Restore Co', Email = SCRUBBED_EMAIL);
        insert lead;

        Test.startTest();
        List<Database.SaveResult> results = SandboxEmailScrubber.restore(
            'Lead',
            new Set<Id>{ lead.Id }
        );
        Test.stopTest();

        Assert.areEqual(1, results.size(), 'one record should have been restored');
        Assert.isTrue(results[0].isSuccess(), 'the restore should have saved');
        Assert.areEqual(LIVE_EMAIL, [SELECT Email FROM Lead WHERE Id = :lead.Id].Email);
    }

    @IsTest
    static void restoreIgnoresAnAddressThatWasNeverScrubbed() {
        SandboxEmailScrubber.sandboxOverride = true;
        Lead lead = new Lead(LastName = 'Live', Company = 'Live Co', Email = LIVE_EMAIL);
        insert lead;

        Test.startTest();
        List<Database.SaveResult> results = SandboxEmailScrubber.restore(
            'Lead',
            new Set<Id>{ lead.Id }
        );
        Test.stopTest();

        Assert.areEqual(0, results.size(), 'there was nothing to restore');
        Assert.areEqual(LIVE_EMAIL, [SELECT Email FROM Lead WHERE Id = :lead.Id].Email);
    }

    @IsTest
    static void trimsTheAddressWhenTheSuffixWouldOverflowTheField() {
        // Contact.Email holds 80 characters. This address is 76, so the suffix would need 84.
        String longAddress = 'a'.repeat(64) + '@example.com';
        Assert.areEqual(76, longAddress.length(), 'the fixture should be 76 characters');

        String scrubbed = SandboxEmailScrubber.scrubbed(longAddress, 80);

        Assert.areEqual(80, scrubbed.length(), 'the result should fill the field exactly');
        Assert.isTrue(scrubbed.endsWith('.invalid'), scrubbed);
        Assert.areEqual(
            'a'.repeat(64) + '@example.invalid',
            scrubbed,
            'trimming the tail should leave a valid address'
        );
    }

    @IsTest
    static void scrubbedReturnsNullWhenThereIsNothingToDo() {
        Assert.isNull(SandboxEmailScrubber.scrubbed(null, 80), 'null needs no change');
        Assert.isNull(SandboxEmailScrubber.scrubbed('', 80), 'blank needs no change');
        Assert.isNull(SandboxEmailScrubber.scrubbed(SCRUBBED_EMAIL, 80), 'already scrubbed');
        Assert.areEqual(
            SCRUBBED_EMAIL,
            SandboxEmailScrubber.scrubbed(LIVE_EMAIL, null),
            'an unknown field length should still scrub'
        );
    }

    /**
     * The query locator in the loop is the assertion: it throws when the generated SOQL is not
     * valid. The loop runs once per allowlisted object, so it cannot approach a governor limit.
     */
    @SuppressWarnings('PMD.OperationWithLimitsInLoop')
    @IsTest
    static void everyAllowlistedObjectProducesValidSoql() {
        List<SandboxEmailScrubber.Target> targets = SandboxEmailScrubber.buildTargets();
        Assert.isFalse(targets.isEmpty(), 'the allowlist should produce at least one target');

        Set<String> objectApiNames = new Set<String>();
        for (SandboxEmailScrubber.Target target : targets) {
            objectApiNames.add(target.objectApiName);
            // Throws if the generated SOQL is not valid, which is the point of the assertion.
            Database.getQueryLocator(SandboxEmailScrubber.buildQuery(target));
        }
        Assert.isTrue(objectApiNames.contains('Contact'), 'Contact should be a target');
    }

    @IsTest
    static void leadQueryExcludesConvertedLeads() {
        String soql = SandboxEmailScrubber.buildQuery(SandboxEmailScrubber.describeTarget('Lead'));
        Assert.isTrue(soql.contains('IsConverted = false'), soql);
        Assert.isTrue(soql.contains('NOT Email LIKE \'%.invalid\''), soql);
    }

    /**
     * Case.ContactEmail is not updateable, so the describe should leave it out while still picking
     * up Case.SuppliedEmail. This covers the field selection without inserting a Case, which keeps
     * the test away from whatever validation an installing org has on that object.
     */
    @IsTest
    static void picksUpOnlyUpdateableEmailFields() {
        SandboxEmailScrubber.Target target = SandboxEmailScrubber.describeTarget('Case');
        if (target == null) {
            return; // an org without Cases has nothing to assert here
        }
        Assert.isTrue(target.fieldApiNames.contains('SuppliedEmail'), 'SuppliedEmail is updateable');
        Assert.isFalse(target.fieldApiNames.contains('ContactEmail'), 'ContactEmail is read only');
    }

    @IsTest
    static void skipsAnObjectThisOrgDoesNotHave() {
        SandboxEmailScrubber.allowlist = new List<String>{ 'NotAnObject__c', 'Contact' };

        List<SandboxEmailScrubber.Target> targets = SandboxEmailScrubber.buildTargets();

        Assert.areEqual(1, targets.size(), 'the missing object should have been skipped');
        Assert.areEqual('Contact', targets[0].objectApiName);
    }

    @IsTest
    static void scrubOfAnUnknownObjectDoesNothing() {
        SandboxEmailScrubber.sandboxOverride = true;

        Test.startTest();
        Id jobId = SandboxEmailScrubber.scrub('NotAnObject__c');
        Test.stopTest();

        Assert.isNull(jobId, 'no batch should have been queued');
    }

    /**
     * The post copy entry point. Contact is the first object in the allowlist, so it is the link
     * that runs: a batch chained from finish() does not execute in a test context.
     */
    @IsTest
    static void postCopyScriptStartsTheScrub() {
        SandboxEmailScrubber.sandboxOverride = true;
        Account account = new Account(Name = 'Post Copy Account');
        insert account;
        insert new Contact(LastName = 'Smith', Email = LIVE_EMAIL, AccountId = account.Id);
        Organization thisOrg = [SELECT Id FROM Organization LIMIT 1];

        Test.startTest();
        Test.testSandboxPostCopyScript(
            new SandboxAfterRefresh(),
            thisOrg.Id,
            thisOrg.Id,
            'ScrubberTestSandbox'
        );
        Test.stopTest();

        Assert.areEqual(SCRUBBED_EMAIL, [SELECT Email FROM Contact LIMIT 1].Email);
    }

    @IsTest
    static void isSandboxReadsTheOrgWhenNothingOverridesIt() {
        SandboxEmailScrubber.sandboxOverride = null;

        Boolean reported = SandboxEmailScrubber.isSandbox();

        Assert.areEqual(
            [SELECT IsSandbox FROM Organization LIMIT 1].IsSandbox,
            reported,
            'the guard should report what the org says'
        );
    }
}
