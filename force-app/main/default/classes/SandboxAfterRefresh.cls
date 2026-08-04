/**
 * The class to select under Setup > Sandboxes as the Apex class to run after a sandbox is created
 * or refreshed.
 *
 * The name is unchanged from the first version of this package, so an org that already names it in
 * its sandbox configuration keeps working.
 *
 * The global modifier is not a choice: Salesforce will only accept a SandboxPostCopy implementation
 * that is declared global.
 */
@SuppressWarnings('PMD.AvoidGlobalModifier')
global with sharing class SandboxAfterRefresh implements SandboxPostCopy {
    /**
     * Runs once, in the new or refreshed sandbox, as soon as the copy completes.
     *
     * @param context the sandbox Salesforce has just finished copying
     */
    global void runApexClass(SandboxContext context) {
        System.debug(
            LoggingLevel.INFO,
            'SandboxAfterRefresh: organization ' +
                context.organizationId() +
                ', sandbox ' +
                context.sandboxName() +
                ' (' +
                context.sandboxId() +
                ').'
        );
        SandboxEmailScrubber.scrubAll();
    }
}
