global class SandboxAfterRefresh implements SandboxPostCopy {
	global void runApexClass(SandboxContext context) {
     
  		System.debug(context.organizationId());
  		System.debug(context.sandboxId());
  		System.debug(context.sandboxName());

  		Database.executeBatch(new BatchModifySandboxContactEmails());
  		Database.executeBatch(new BatchModifySandboxLeadEmails());
  		Database.executeBatch(new BatchModifySandboxGroupEmails());
     
	}
}