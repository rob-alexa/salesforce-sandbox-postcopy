@isTest
class SandboxAfterRefreshTest {
    
	@isTest
	static void testSandboxAfterRefresh()	{
        
        Account testAccount = new Account(name = 'Test Account',website = 'http://www.example.com');
        insert testAccount;
        Contact testContact = new Contact(firstname = 'John',lastname = 'Smith',email = 'john@smith.com', accountId = testAccount.Id);
        insert testContact;
		Lead testLead = new Lead(firstname = 'Jane',lastname = 'Doe',email = 'jane@doe.com', company = 'Test Company',status = 'Open',LeadSource = 'Prospecting');
        insert testLead;
        Group testingQueue = new Group(name = 'Testing Queue',DeveloperName = 'Testing_Queue', email = 'testing@queue.com',Type = 'Queue');
        insert testingQueue;
        
        List<Organization> org = ([select id from Organization limit 1]);
		        
        Test.startTest();
			Test.testSandboxPostCopyScript(new SandboxAfterRefresh(), org[0].Id, org[0].Id, 'TestSandbox');
		Test.stopTest();
        
        Contact c = [Select email from Contact limit 1];
        Lead l = [Select email from Lead limit 1];
        Group q = [Select email from Group where DeveloperName = 'Testing_Queue' limit 1];
        
        System.assert(c.Email.endsWith('.invalid'));
        System.assert(l.Email.endsWith('.invalid'));
        System.assert(q.Email.endsWith('.invalid'));
	}
}
