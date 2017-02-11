public class BatchModifySandboxLeadEmails implements Database.Batchable<sObject>{
    Public Database.QueryLocator start(Database.BatchableContext BC){
        //exclude all leads without email and emails that are already modified
        String query = 'select Id,Email from Lead where Email != null AND IsConverted = false AND (NOT Email LIKE \'%@example.com\')';
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
        List<Lead> listLead = (List<Lead>)scope;
        List<Lead> ListToUpdate = new List<Lead>();
        if(scope!=null){
            for(Lead l: listLead){
                l.Email = l.Email.replace('@', '=') + '@example.com';
                ListToUpdate.add(l);
            }
        }
        if(ListToUpdate.size()>0){
            //Update all Leads that can be updated
            database.update(ListToUpdate,false);
        }
    }

    Public void finish(Database.BatchableContext BC){
    	system.debug('***** BatchModifySandboxLeadEmails is complete.');	    
    }
}