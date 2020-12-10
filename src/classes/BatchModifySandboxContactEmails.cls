public class BatchModifySandboxContactEmails implements Database.Batchable<sObject>{
    Public Database.QueryLocator start(Database.BatchableContext BC){
        //exclude all contacts without email and emails that are already modified
        String query = 'select Id,Email from Contact where Email != null AND (NOT Email LIKE \'%.invalid\')';
        //return results to process only if the current instance is a sandbox or a test is running
        Boolean sandbox;
        for(Organization o:[Select isSandbox from Organization limit 1]){
            sandbox = o.isSandbox;
        }
        if(sandbox == TRUE){
        	return Database.getQueryLocator(query);
        } else if (Test.isRunningTest()){
        	return Database.getQueryLocator(query + ' limit 1');	    
        } else {
            return Database.getQueryLocator(query + ' limit 0');
        }
    }

    Public void execute(Database.BatchableContext BC, List<sObject> scope){
        List<Contact> listContact = (List<Contact>)scope;
        List<Contact> ListToUpdate = new List<Contact>();
        if(scope!=null){
            for(Contact c:listContact){
                c.Email = c.Email.replace + '.invalid';
                ListToUpdate.add(c);                    
            }
        }
        if(ListToUpdate.size()>0){
            //Update all Contacts that can be updated
            database.update(ListToUpdate,false);
        }
    }

    Public void finish(Database.BatchableContext BC){
    	system.debug('***** BatchModifySandboxContactEmails is complete.');    
    }
}
