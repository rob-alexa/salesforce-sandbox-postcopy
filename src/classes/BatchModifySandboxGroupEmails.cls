public class BatchModifySandboxGroupEmails implements Database.Batchable<sObject>{
    Public Database.QueryLocator start(Database.BatchableContext BC){
        //exclude all groups without email and emails that are already modified
        String query = 'select Id,Email from Group where Email != null AND (NOT Email LIKE \'%.invalid\')';
        //return results to process only if the current instance is a sandbox or a test is running
        Boolean sandbox;
        for(Organization o:[Select isSandbox from Organization limit 1]){
            sandbox = o.isSandbox;
        }
        if(sandbox == TRUE){
        	return Database.getQueryLocator(query);
        } else if (Test.isRunningTest()){
        	return Database.getQueryLocator(query + ' AND DeveloperName = \'Testing_Queue\' limit 1');	    
        } else {
            return Database.getQueryLocator(query + ' limit 0');
        }
    }

    Public void execute(Database.BatchableContext BC, List<sObject> scope){
        List<Group> listGroup = (List<Group>)scope;
        List<Group> ListToUpdate = new List<Group>();
        if(scope!=null){
            for(Group g: listGroup){
                g.Email = g.Email + '.invalid';
                ListToUpdate.add(g);                    
            }
        }
        if(ListToUpdate.size()>0){
            //Update all Groups that can be updated
            database.update(ListToUpdate,false);
        }
    }

    Public void finish(Database.BatchableContext BC){
    	system.debug('***** BatchModifySandboxGroupEmails is complete.');    
    }
}
